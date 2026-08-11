/// PCM capture by piping a capture process, rather than by FFI.
///
/// Spec 6.1 is right that this is the pragmatic choice for a CLI: zero FFI,
/// trivially debuggable, and it keeps `lib/` free of Flutter plugins like
/// `record` or `flutter_audio_capture`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../constants.dart';
import 'audio_source.dart';

final Logger _log = Logger('needle.audio');

/// An input the operator can capture from.
class AudioDevice {
  const AudioDevice({
    required this.id,
    required this.name,
    required this.likelyDigirig,
  });

  /// What to pass to `--device`.
  final String id;

  final String name;

  /// True when the name matches the USB codec a Digirig presents.
  final bool likelyDigirig;

  @override
  String toString() => '$id  $name';
}

/// Enumerates capture devices for the host platform.
Future<List<AudioDevice>> listInputDevices() async {
  if (Platform.isMacOS) return _listMacOsDevices();
  if (Platform.isLinux) return _listLinuxDevices();
  throw PcmSourceException(
    'audio device discovery is not implemented for ${Platform.operatingSystem}',
  );
}

/// The Digirig presents a generic C-Media codec, so there is no "Digirig" in
/// the name to match on. These are the strings it actually reports.
bool _looksLikeDigirig(String name) {
  final n = name.toLowerCase();
  return n.contains('usb audio') || n.contains('c-media') || n.contains('digirig');
}

Future<List<AudioDevice>> _listMacOsDevices() async {
  final ProcessResult result;
  try {
    result = await Process.run('ffmpeg', [
      '-hide_banner',
      '-f',
      'avfoundation',
      '-list_devices',
      'true',
      '-i',
      '',
    ]);
  } on ProcessException {
    throw const PcmSourceException(
      'ffmpeg is not installed',
      remedy: 'brew install ffmpeg',
    );
  }

  // ffmpeg writes the device list to stderr and then exits non-zero, because
  // the empty input it was given cannot be opened. That is expected.
  final devices = <AudioDevice>[];
  var inAudioSection = false;
  final entry = RegExp(r'\[(\d+)\]\s+(.+?)\s*$');

  for (final line in const LineSplitter().convert(result.stderr.toString())) {
    if (line.contains('AVFoundation video devices:')) {
      inAudioSection = false;
      continue;
    }
    if (line.contains('AVFoundation audio devices:')) {
      inAudioSection = true;
      continue;
    }
    if (!inAudioSection) continue;

    // Strip the "[AVFoundation indev @ 0x...]" prefix before matching, or its
    // pointer would be read as a device index.
    final stripped = line.replaceFirst(RegExp(r'^\[AVFoundation[^\]]*\]\s*'), '');
    final match = entry.firstMatch(stripped);
    if (match == null) continue;

    final name = match.group(2)!;
    devices.add(
      AudioDevice(
        id: match.group(1)!,
        name: name,
        likelyDigirig: _looksLikeDigirig(name),
      ),
    );
  }
  return devices;
}

Future<List<AudioDevice>> _listLinuxDevices() async {
  final ProcessResult result;
  try {
    result = await Process.run('arecord', ['-l']);
  } on ProcessException {
    throw const PcmSourceException(
      'arecord is not installed',
      remedy: 'sudo apt install alsa-utils',
    );
  }

  final devices = <AudioDevice>[];
  final entry = RegExp(r'^card (\d+): (\S+).*?device (\d+): (.+?)\s*\[');
  for (final line in const LineSplitter().convert(result.stdout.toString())) {
    final match = entry.firstMatch(line);
    if (match == null) continue;
    final name = '${match.group(2)} ${match.group(4)}';
    devices.add(
      AudioDevice(
        id: 'hw:${match.group(1)},${match.group(3)}',
        name: name,
        likelyDigirig: _looksLikeDigirig(name),
      ),
    );
  }
  return devices;
}

/// Captures PCM from a child process reading raw S16_LE.
class ProcessPcmSource implements PcmSource {
  ProcessPcmSource({
    required this.device,
    this.sampleRate = kSampleRate,
  });

  /// Platform device selector: an avfoundation index on macOS, `hw:c,d` on
  /// Linux.
  final String device;

  @override
  final int sampleRate;

  final StreamController<Float64List> _controller =
      StreamController<Float64List>.broadcast();

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  StreamSubscription<ProcessSignal>? _sigintSub;

  /// True once shutdown has begun, from either [stop] or a Ctrl-C.
  ///
  /// Ctrl-C in a terminal delivers SIGINT to the whole foreground process
  /// group, so the capture child dies before our own teardown runs. Without
  /// this, an ordinary Ctrl-C is reported as "capture process exited with
  /// code 255" — a crash message for a clean exit.
  bool _stopping = false;

  /// Carries a straddling byte between chunks.
  ///
  /// A pipe splits wherever it likes, including between the two halves of a
  /// 16-bit sample. Dropping the odd byte would shift every subsequent sample
  /// by one and turn the audio into noise.
  int? _carry;

  final List<String> _stderrTail = [];

  @override
  Stream<Float64List> get samples => _controller.stream;

  /// The capture command for this platform.
  List<String> get command => Platform.isMacOS
      ? [
          'ffmpeg',
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'avfoundation',
          '-i',
          ':$device',
          '-ar',
          '$sampleRate',
          '-ac',
          '1',
          '-f',
          's16le',
          '-',
        ]
      : [
          'arecord',
          '-D',
          device,
          '-f',
          'S16_LE',
          '-r',
          '$sampleRate',
          '-c',
          '1',
          '-t',
          'raw',
        ];

  @override
  Future<void> start() async {
    if (_process != null) return;

    final argv = command;
    _log.fine('capture: ${argv.join(' ')}');

    final Process process;
    try {
      process = await Process.start(argv.first, argv.sublist(1));
    } on ProcessException catch (e) {
      throw PcmSourceException(
        'could not start ${argv.first}: ${e.message}',
        remedy: Platform.isMacOS
            ? 'brew install ffmpeg'
            : 'sudo apt install alsa-utils',
      );
    }
    _process = process;
    _stopping = false;

    // Watch SIGINT ourselves so a Ctrl-C that kills the child first is still
    // recognised as an intentional stop rather than a failure.
    _sigintSub = ProcessSignal.sigint.watch().listen((_) => _stopping = true);

    _stdoutSub = process.stdout.listen(_onBytes, onError: _controller.addError);

    _stderrSub = process.stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true).trim();
      if (text.isEmpty) return;
      _log.warning('capture stderr: $text');
      _stderrTail.add(text);
      if (_stderrTail.length > 5) _stderrTail.removeAt(0);
    });

    unawaited(
      process.exitCode.then((code) {
        if (_controller.isClosed || _stopping) return;
        if (code != 0) {
          _controller.addError(
            PcmSourceException(
              'capture process exited with code $code',
              remedy: _stderrTail.isEmpty
                  ? 'Run "needle devices" to check the device id.'
                  : _stderrTail.join('\n'),
            ),
          );
        }
      }),
    );
  }

  void _onBytes(List<int> data) {
    if (_controller.isClosed) return;

    // Re-attach the byte left over from last time, if any.
    final carry = _carry;
    final bytes = carry == null
        ? Uint8List.fromList(data)
        : (Uint8List(data.length + 1)
            ..[0] = carry
            ..setRange(1, data.length + 1, data));

    final usable = bytes.length - (bytes.length.isOdd ? 1 : 0);
    _carry = bytes.length.isOdd ? bytes[bytes.length - 1] : null;
    if (usable == 0) return;

    final view = ByteData.sublistView(bytes, 0, usable);
    final out = Float64List(usable ~/ 2);
    for (var i = 0; i < out.length; i++) {
      // Signed 16-bit little-endian, normalized to -1.0..1.0.
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    _controller.add(out);
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    await _sigintSub?.cancel();
    _sigintSub = null;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;

    _process?.kill();
    _process = null;
    _carry = null;

    if (!_controller.isClosed) await _controller.close();
  }
}
