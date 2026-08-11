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
import 'capture_backend.dart';

final Logger _log = Logger('needle.audio');

/// Enumerates capture devices for the running host.
Future<List<AudioDevice>> listInputDevices() =>
    CaptureBackend.forHost().listDevices();

/// Captures PCM from a child process reading raw S16_LE.
class ProcessPcmSource implements PcmSource {
  ProcessPcmSource({
    required this.device,
    this.sampleRate = kSampleRate,
    CaptureBackend? backend,
  }) : backend = backend ?? CaptureBackend.forHost();

  /// Host-specific capture. Injectable so tests can drive a fake.
  final CaptureBackend backend;

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
  List<String> get command => backend.captureCommand(device, sampleRate);

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
        remedy: backend.installHint,
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
