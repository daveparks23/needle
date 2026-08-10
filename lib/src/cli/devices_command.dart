// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:args/command_runner.dart';

import '../dsp/audio_source.dart';
import '../dsp/process_pcm_source.dart';

/// Lists audio capture devices and flags the likely Digirig.
class DevicesCommand extends Command<int> {
  @override
  String get name => 'devices';

  @override
  String get description => 'List audio input devices.';

  @override
  Future<int> run() async {
    final List<AudioDevice> devices;
    try {
      devices = await listInputDevices();
    } on PcmSourceException catch (e) {
      stderr.writeln(e);
      return 69;
    }

    if (devices.isEmpty) {
      stdout.writeln('No audio input devices found.');
      return 1;
    }

    for (final d in devices) {
      stdout.writeln('${d.likelyDigirig ? '  ✓' : '   '} ${d.id.padRight(6)} ${d.name}');
    }

    final candidates = devices.where((d) => d.likelyDigirig).toList();
    stdout.writeln();
    if (candidates.isEmpty) {
      stdout.writeln(
        'No Digirig-looking device found. It presents as a generic C-Media '
        'codec, usually named "USB Audio Device" — check the cable if nothing '
        'above matches.',
      );
      return 0;
    }

    stdout.writeln(
      'Likely Digirig: ${candidates.map((d) => d.id).join(', ')}',
    );
    stdout.writeln(
      'Try: needle audio --device ${candidates.first.id} --peak',
    );
    return 0;
  }
}
