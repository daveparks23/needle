// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';

import '../cat/commands.dart';
import '../cat/mock_transport.dart';
import '../cat/rig_controller.dart';
import '../cat/rig_state.dart';
import '../cat/serial_transport.dart';
import '../cat/transport.dart';
import '../constants.dart';
import '../dsp/audio_source.dart';
import '../dsp/mock_source.dart';
import '../dsp/noise_floor.dart';
import '../dsp/process_pcm_source.dart';
import '../dsp/spectrum.dart';
import '../dsp/spectrum_isolate.dart';
import 'waterfall_renderer.dart';

/// The payoff demo: a scrolling terminal waterfall with live CAT state.
///
/// This is the only place the CAT and DSP subsystems meet. The coupling is
/// one-directional and explicit: this command subscribes to
/// `Stream<RigState>` and gates its own rendering. Nothing in `dsp/` knows
/// that `cat/` exists.
class ScopeCommand extends Command<int> {
  ScopeCommand() {
    argParser
      ..addOption('port', abbr: 'p', help: 'CAT serial device.')
      ..addOption('device', abbr: 'd', help: 'Audio capture device id.')
      ..addFlag('mock', negatable: false, help: 'Run the whole demo with no hardware.')
      ..addOption('seconds', help: 'Stop after this many seconds.')
      ..addOption('fft-size', defaultsTo: '$kFftSize')
      ..addOption('hop', defaultsTo: '$kFftHop')
      ..addOption('max-hz', defaultsTo: '${kDisplayMaxHz.toInt()}')
      ..addOption('rate', defaultsTo: '$kSampleRate')
      ..addOption(
        'dynamic-range',
        defaultsTo: '${kDefaultDynamicRangeDb.toInt()}',
        help: 'dB between the noise floor and the brightest colour.',
      )
      ..addOption('fps', defaultsTo: '$kTargetFps');
  }

  @override
  String get name => 'scope';

  @override
  String get description => 'Scrolling waterfall with live CAT state.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final mock = args.flag('mock');
    final rate = int.parse(args.option('rate')!);
    final maxHz = double.parse(args.option('max-hz')!);
    final rangeDb = double.parse(args.option('dynamic-range')!);
    final fps = int.parse(args.option('fps')!);

    // ---- audio ----
    final PcmSource source;
    if (mock) {
      source = MockSource.ft8();
    } else {
      final device = args.option('device');
      if (device == null) {
        usageException('--device is required (or use --mock).');
      }
      source = ProcessPcmSource(device: device, sampleRate: rate);
    }

    // ---- CAT (optional: the waterfall is useful without a radio) ----
    RigController? controller;
    final port = args.option('port');
    if (mock || port != null) {
      final CatTransport transport = mock
          ? MockTransport(
              fixture: File('test/fixtures/cat_session_20m.txt').readAsStringSync(),
            )
          : SerialTransport(
              port!,
              baud: int.tryParse(globalResults?.option('baud') ?? '') ?? kDefaultBaud,
            );
      controller = RigController(transport);
    }

    final analyzer = SpectrumAnalyzer(
      fftSize: int.parse(args.option('fft-size')!),
      hop: int.parse(args.option('hop')!),
      sampleRate: rate,
      displayMaxHz: maxHz,
    );
    final worker = await SpectrumIsolate.spawn(
      fftSize: analyzer.fftSize,
      hop: analyzer.hop,
      sampleRate: rate,
      displayMaxHz: maxHz,
    );

    final floor = NoiseFloorTracker();
    final renderer = WaterfallRenderer(columns: _terminalColumns());

    try {
      await source.start();
    } on PcmSourceException catch (e) {
      stderr.writeln(e);
      await worker.dispose();
      return 69;
    }

    try {
      await controller?.start();
    } on CatTransportException catch (e) {
      stderr.writeln(e);
      stderr.writeln('Continuing without CAT.');
      controller = null;
    }

    // ---- wiring ----
    var state = const RigState.initial();
    final stateSub = controller?.states.listen((s) {
      final wasTransmitting = state.transmitting;
      state = s;
      // Spec 6.6: keying up paints a solid bar across the waterfall and
      // poisons the floor estimate for seconds afterwards. Freeze both.
      if (s.transmitting && !wasTransmitting) {
        floor.freeze();
      } else if (!s.transmitting && wasTransmitting) {
        floor.unfreeze();
      }
    });

    final pending = <Float64List>[];
    final frameSub = worker.frames.listen((frame) {
      if (state.transmitting) return; // TX blanking
      floor.add(frame);
      pending.add(frame);
      // Only ever hold the two rows a half-block line needs.
      if (pending.length > 2) pending.removeAt(0);
    });

    final audioSub = source.samples.listen(worker.feed);

    final seconds = int.tryParse(args.option('seconds') ?? '');
    final deadline =
        seconds == null ? null : DateTime.now().add(Duration(seconds: seconds));
    var stop = false;
    final sigint = ProcessSignal.sigint.watch().listen((_) => stop = true);

    stdout.writeln(_header(state, controller, floor, rangeDb));
    var painted = 0;

    while (!stop && (deadline == null || DateTime.now().isBefore(deadline))) {
      await Future<void>.delayed(Duration(milliseconds: (1000 / fps).round()));
      if (pending.length < 2) continue;

      final bottom = renderer.downsample(pending.removeLast());
      final top = renderer.downsample(pending.removeLast());
      final floorDb = floor.floorDb;

      if (stdout.hasTerminal) {
        // Repaint the status line in place above the scrolling waterfall.
        stdout.write('\x1b[s\x1b[1;1H\x1b[K');
        stdout.write(_header(state, controller, floor, rangeDb));
        stdout.write('\x1b[u');
      }
      stdout.writeln(renderer.renderRows(top, bottom, floorDb, rangeDb));
      painted++;
    }

    stdout.writeln(renderer.axis(maxHz));
    stdout.writeln(_header(state, controller, floor, rangeDb));

    await sigint.cancel();
    await audioSub.cancel();
    await frameSub.cancel();
    await stateSub?.cancel();
    await source.stop();
    await worker.dispose();
    await controller?.stop();

    if (painted == 0) {
      stderr.writeln('No frames rendered — check the audio device.');
      return 1;
    }
    return 0;
  }

  String _header(
    RigState s,
    RigController? c,
    NoiseFloorTracker floor,
    double rangeDb,
  ) {
    final freq = s.vfoAHz == null
        ? '---.------'
        : (s.vfoAHz! / 1e6).toStringAsFixed(6);
    final mode = s.mode == RigMode.unknown ? '---' : s.mode.name.toUpperCase();
    final meter = s.sMeterRaw == null ? '---' : '${s.sMeterRaw}';
    final width = s.filterWidthIndex == null ? '--' : '${s.filterWidthIndex}';
    final tx = s.transmitting ? '  [TX — blanked]' : '';
    final link = c == null ? 'no CAT' : s.phase.name;
    return '$freq MHz  $mode  S:$meter  SH:$width  '
        'floor ${floor.floorDb.toStringAsFixed(0)}dB  '
        'range ${rangeDb.toStringAsFixed(0)}dB  $link$tx';
  }

  int _terminalColumns() {
    try {
      if (stdout.hasTerminal) return stdout.terminalColumns.clamp(20, 400);
    } on StdoutException {
      // Not a terminal; fall through.
    }
    return 80;
  }
}
