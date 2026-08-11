/// Everything platform-specific about capturing audio, in one place.
///
/// The rest of the DSP layer is platform-agnostic; adding a host means adding
/// a [CaptureBackend] here and nothing else.
///
/// **Verification status.** macOS is exercised against real hardware (a Digirig
/// on an FT-891). Linux and Windows are written from the ffmpeg/ALSA
/// documentation and have **never been run**. They are present so the seam is
/// real rather than hypothetical, and so an unsupported host fails with a
/// useful message instead of silently invoking the wrong tool — but treat them
/// as untested until someone reports otherwise.
library;

import 'dart:convert';
import 'dart:io';

import 'audio_source.dart';

/// A capture device the operator can select.
class AudioDevice {
  const AudioDevice({
    required this.id,
    required this.name,
    required this.likelyDigirig,
  });

  /// What to pass to `--device`.
  ///
  /// An avfoundation index on macOS, `hw:card,dev` on Linux, and a device
  /// *name* on Windows — dshow has no stable index.
  final String id;

  final String name;

  /// True when the name matches the USB codec a Digirig presents.
  final bool likelyDigirig;

  @override
  String toString() => '$id  $name';
}

/// The Digirig has no "Digirig" in its name — it presents as a generic C-Media
/// codec. These are the strings it actually reports.
bool looksLikeDigirig(String name) {
  final n = name.toLowerCase();
  return n.contains('usb audio') ||
      n.contains('c-media') ||
      n.contains('digirig');
}

/// Host-specific capture and enumeration.
abstract class CaptureBackend {
  const CaptureBackend();

  /// Returns the backend for the running host.
  ///
  /// Throws [PcmSourceException] rather than guessing on an unknown platform:
  /// silently running the wrong capture tool produces an error message that
  /// sends the operator in entirely the wrong direction.
  factory CaptureBackend.forHost() {
    if (Platform.isMacOS) return const MacOsCaptureBackend();
    if (Platform.isLinux) return const LinuxCaptureBackend();
    if (Platform.isWindows) return const WindowsCaptureBackend();
    throw PcmSourceException(
      'audio capture is not implemented for ${Platform.operatingSystem}',
      remedy: 'Supported hosts are macOS, Linux and Windows.',
    );
  }

  /// Argv for a process that writes raw mono S16_LE to stdout.
  List<String> captureCommand(String device, int sampleRate);

  /// Enumerates capture devices.
  Future<List<AudioDevice>> listDevices();

  /// What to tell the operator when the capture tool is missing.
  String get installHint;

  /// False for hosts this project has never actually run on.
  bool get verified => false;
}

/// ffmpeg + avfoundation. Verified against real hardware.
class MacOsCaptureBackend extends CaptureBackend {
  const MacOsCaptureBackend();

  @override
  bool get verified => true;

  @override
  String get installHint => 'brew install ffmpeg';

  @override
  List<String> captureCommand(String device, int sampleRate) => [
    'ffmpeg',
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'avfoundation',
    // A leading colon means "no video, audio device N".
    '-i',
    ':$device',
    '-ar',
    '$sampleRate',
    '-ac',
    '1',
    '-f',
    's16le',
    '-',
  ];

  @override
  Future<List<AudioDevice>> listDevices() async {
    final result = await _run('ffmpeg', [
      '-hide_banner',
      '-f',
      'avfoundation',
      '-list_devices',
      'true',
      '-i',
      '',
    ], installHint);

    // ffmpeg prints the list to stderr and exits non-zero, because the empty
    // input it was handed cannot be opened. That is expected.
    final devices = <AudioDevice>[];
    var inAudioSection = false;
    final entry = RegExp(r'\[(\d+)\]\s+(.+?)\s*$');

    for (final line in const LineSplitter().convert(result.stderr.toString())) {
      if (line.contains('AVFoundation video devices:')) {
        inAudioSection = false;
        continue;
      }
      if (line.contains('AVFoundation audio devices:')) {
        // Audio indices restart at 0 after the video list, so anything before
        // this marker would be numbered wrongly.
        inAudioSection = true;
        continue;
      }
      if (!inAudioSection) continue;

      // Strip the "[AVFoundation indev @ 0x...]" prefix, or its pointer gets
      // read as a device index.
      final stripped = line.replaceFirst(
        RegExp(r'^\[AVFoundation[^\]]*\]\s*'),
        '',
      );
      final match = entry.firstMatch(stripped);
      if (match == null) continue;

      final name = match.group(2)!;
      devices.add(
        AudioDevice(
          id: match.group(1)!,
          name: name,
          likelyDigirig: looksLikeDigirig(name),
        ),
      );
    }
    return devices;
  }
}

/// ALSA via arecord. **Untested.**
class LinuxCaptureBackend extends CaptureBackend {
  const LinuxCaptureBackend();

  @override
  String get installHint => 'sudo apt install alsa-utils';

  @override
  List<String> captureCommand(String device, int sampleRate) => [
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
  Future<List<AudioDevice>> listDevices() async {
    final result = await _run('arecord', ['-l'], installHint);
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
          likelyDigirig: looksLikeDigirig(name),
        ),
      );
    }
    return devices;
  }
}

/// ffmpeg + DirectShow. **Untested.**
///
/// dshow selects by device *name*, not index, so `--device` takes the quoted
/// name that `needle devices` prints.
class WindowsCaptureBackend extends CaptureBackend {
  const WindowsCaptureBackend();

  @override
  String get installHint => 'winget install ffmpeg  (or choco install ffmpeg)';

  @override
  List<String> captureCommand(String device, int sampleRate) => [
    'ffmpeg',
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'dshow',
    '-i',
    'audio=$device',
    '-ar',
    '$sampleRate',
    '-ac',
    '1',
    '-f',
    's16le',
    '-',
  ];

  @override
  Future<List<AudioDevice>> listDevices() async {
    final result = await _run('ffmpeg', [
      '-hide_banner',
      '-list_devices',
      'true',
      '-f',
      'dshow',
      '-i',
      'dummy',
    ], installHint);

    // Lines look like:  [dshow @ ...] "Microphone (USB Audio Device)" (audio)
    final devices = <AudioDevice>[];
    final entry = RegExp(r'"([^"]+)"\s*\(audio\)');
    for (final line in const LineSplitter().convert(result.stderr.toString())) {
      final match = entry.firstMatch(line);
      if (match == null) continue;
      final name = match.group(1)!;
      devices.add(
        AudioDevice(id: name, name: name, likelyDigirig: looksLikeDigirig(name)),
      );
    }
    return devices;
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> args,
  String hint,
) async {
  try {
    return await Process.run(executable, args);
  } on ProcessException {
    throw PcmSourceException('$executable is not installed', remedy: hint);
  }
}
