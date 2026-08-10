// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';

import '../constants.dart';
import '../dsp/audio_source.dart';
import '../dsp/mock_source.dart';
import '../dsp/process_pcm_source.dart';
import '../dsp/spectrum.dart';

/// Audio capture and spectrum inspection.
class AudioCommand extends Command<int> {
  AudioCommand() {
    argParser
      ..addOption('device', abbr: 'd', help: 'Capture device id from "needle devices".')
      ..addFlag('mock', negatable: false, help: 'Use synthetic audio instead of hardware.')
      ..addFlag('peak', negatable: false, help: 'Print the dominant frequency continuously.')
      ..addFlag('bins', negatable: false, help: 'Dump the magnitude array as CSV.')
      ..addOption('seconds', help: 'Stop after this many seconds.')
      ..addOption('fft-size', defaultsTo: '$kFftSize')
      ..addOption('hop', defaultsTo: '$kFftHop')
      ..addOption('max-hz', defaultsTo: '${kDisplayMaxHz.toInt()}')
      ..addOption('rate', defaultsTo: '$kSampleRate');
  }

  @override
  String get name => 'audio';

  @override
  String get description => 'Capture audio and inspect its spectrum.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (!args.flag('peak') && !args.flag('bins')) {
      usageException('Nothing to do: pass --peak or --bins.');
    }

    final rate = int.parse(args.option('rate')!);
    final analyzer = SpectrumAnalyzer(
      fftSize: int.parse(args.option('fft-size')!),
      hop: int.parse(args.option('hop')!),
      sampleRate: rate,
      displayMaxHz: double.parse(args.option('max-hz')!),
    );

    final PcmSource source;
    if (args.flag('mock')) {
      source = MockSource.ft8();
    } else {
      final device = args.option('device');
      if (device == null) {
        usageException(
          '--device is required (or use --mock). Run "needle devices" to find it.',
        );
      }
      source = ProcessPcmSource(device: device, sampleRate: rate);
    }

    try {
      await source.start();
    } on PcmSourceException catch (e) {
      stderr.writeln(e);
      return 69;
    }

    final seconds = int.tryParse(args.option('seconds') ?? '');
    final deadline = seconds == null
        ? null
        : DateTime.now().add(Duration(seconds: seconds));

    var stop = false;
    final sigint = ProcessSignal.sigint.watch().listen((_) => stop = true);
    final peakMode = args.flag('peak');
    var frames = 0;
    Object? failure;

    final sub = source.samples.listen(
      (chunk) {
        analyzer.feed(chunk, (frame) {
          frames++;
          if (peakMode) {
            _printPeak(analyzer, frame);
          } else {
            _printBins(frame);
          }
        });
      },
      onError: (Object e) {
        failure = e;
        stop = true;
      },
    );

    while (!stop && (deadline == null || DateTime.now().isBefore(deadline))) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    await sub.cancel();
    await sigint.cancel();
    analyzer.flush((_) {});
    await source.stop();

    if (failure != null) {
      stderr.writeln();
      stderr.writeln(failure);
      return 69;
    }

    if (frames == 0) {
      stderr.writeln();
      stderr.writeln('No audio captured. Check the device id with "needle devices".');
      return 1;
    }

    if (peakMode) stdout.writeln();
    return 0;
  }

  void _printPeak(SpectrumAnalyzer analyzer, Float64List frame) {
    final hz = analyzer.interpolatedPeakHz(frame);
    var peakBin = 0;
    for (var i = 1; i < frame.length; i++) {
      if (frame[i] > frame[peakBin]) peakBin = i;
    }
    final db = frame[peakBin];

    // Peak height above the frame's own median is a scale-independent read on
    // whether this is a real signal or just the noise floor wandering.
    final sorted = Float64List.fromList(frame)..sort();
    final median = sorted[sorted.length ~/ 2];
    final snr = db - median;

    final line = '${hz.toStringAsFixed(1).padLeft(8)} Hz  '
        '${db.toStringAsFixed(1).padLeft(7)} dBFS  '
        '${snr.toStringAsFixed(1).padLeft(5)} dB SNR  ${_bar(snr)}';
    if (stdout.hasTerminal) {
      stdout.write('\r\x1b[K$line');
    } else {
      stdout.writeln(line);
    }
  }

  void _printBins(Float64List frame) {
    stdout.writeln(frame.map((v) => v.toStringAsFixed(2)).join(','));
  }

  /// A bar scaled to signal-above-noise, so a whistle is obvious without
  /// reading numbers and a quiet band does not sit pegged at full scale.
  String _bar(double snrDb) {
    final normalized = (snrDb / 60.0).clamp(0.0, 1.0);
    return '#' * (normalized * 40).round();
  }
}
