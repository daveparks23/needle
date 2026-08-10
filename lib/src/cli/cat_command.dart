// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../cat/codec.dart';
import '../cat/commands.dart';
import '../cat/mock_transport.dart';
import '../cat/recording_transport.dart';
import '../cat/rig_controller.dart';
import '../cat/rig_state.dart';
import '../cat/serial_transport.dart';
import '../cat/transport.dart';
import '../constants.dart';

/// One-shot and streaming CAT access.
class CatCommand extends Command<int> {
  CatCommand() {
    argParser
      ..addOption('port', abbr: 'p', help: 'Serial device, e.g. /dev/cu.usbserial-XXXX0.')
      ..addFlag('mock', negatable: false, help: 'Replay the bundled fixture instead of using hardware.')
      ..addFlag('watch', abbr: 'w', negatable: false, help: 'Stream live rig state to stdout.')
      ..addFlag(
        'auto-info',
        negatable: false,
        help: 'Experimental: ask the radio to push changes (AI1) and poll less. '
            'Polling is the proven path and stays the default.',
      )
      ..addOption('send', abbr: 's', help: 'Send one command (include the trailing ";") and print the answer.')
      ..addOption('record', abbr: 'r', help: 'Poll the radio and write a transcript to this file.')
      ..addOption(
        'seconds',
        help: 'Stop recording after this many seconds instead of waiting for Ctrl-C.',
      )
      ..addOption(
        'timeout',
        defaultsTo: '${kCommandTimeout.inMilliseconds}',
        help: 'Milliseconds to wait for a response.',
      );
  }

  @override
  String get name => 'cat';

  @override
  String get description => 'Talk to the radio over CAT.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final send = args.option('send');
    final record = args.option('record');

    if (send == null && record == null && !args.flag('watch')) {
      usageException('Nothing to do: pass --send, --watch or --record.');
    }

    final CatTransport transport;
    try {
      transport = await _openTransport();
    } on CatTransportException catch (e) {
      stderr.writeln(e);
      return 69;
    }

    try {
      if (send != null) return await _sendOne(transport, send);
      if (args.flag('watch')) return await _watch(transport);
      return await _record(transport);
    } finally {
      await transport.close();
    }
  }

  Future<CatTransport> _openTransport() async {
    final args = argResults!;
    final baud = int.tryParse(globalResults?.option('baud') ?? '') ?? kDefaultBaud;

    CatTransport transport;
    if (args.flag('mock')) {
      transport = MockTransport(
        fixture: File('test/fixtures/cat_session_20m.txt').readAsStringSync(),
      );
    } else {
      final port = args.option('port');
      if (port == null) {
        usageException('--port is required (or use --mock). Run "needle ports" to find it.');
      }
      transport = SerialTransport(port, baud: baud);
    }

    final record = args.option('record');
    if (record != null) {
      transport = RecordingTransport(transport, File(record).openWrite());
    }

    await transport.open();
    return transport;
  }

  Future<int> _sendOne(CatTransport transport, String command) async {
    final timeout = Duration(
      milliseconds: int.tryParse(argResults!.option('timeout') ?? '') ??
          kCommandTimeout.inMilliseconds,
    );

    final answer = transport.lines.first;
    transport.send(command.endsWith(';') ? command : '$command;');

    final String line;
    try {
      line = await answer.timeout(timeout);
    } on TimeoutException {
      stderr.writeln('No response within ${timeout.inMilliseconds}ms.');
      stderr.writeln(
        'If the port is right, the radio\'s CAT RATE (menu 05-06) probably '
        'does not match. Run "needle ports --probe" to find the rate it is '
        'actually using.',
      );
      return 1;
    }

    final parsed = parseResponse(line);
    switch (parsed) {
      case CatData(:final prefix, :final payload):
        stdout.writeln('$prefix$payload;');
        return 0;
      case CatRejected():
        stderr.writeln('?; — the radio rejected that command.');
        return 1;
      case null:
        stderr.writeln('Unparseable response: "$line"');
        return 1;
    }
  }

  /// Streams live rig state, repainting one line in place.
  Future<int> _watch(CatTransport transport) async {
    final verbose = globalResults?.flag('verbose') ?? false;
    final seconds = int.tryParse(argResults!.option('seconds') ?? '');
    final deadline = seconds == null
        ? null
        : DateTime.now().add(Duration(seconds: seconds));

    final controller = RigController(transport);
    await controller.start();

    if (argResults!.flag('auto-info')) {
      // Spec 5.6: polling is the baseline and stays the default. AI is
      // opt-in and unproven on this model.
      await controller.request(setAutoInformation(enabled: true));
      stdout.writeln('Auto-information enabled (experimental).');
    }

    var stop = false;
    final sigint = ProcessSignal.sigint.watch().listen((_) => stop = true);
    final started = DateTime.now();
    final phases = <ConnectionPhase>{controller.current.phase};

    // In-place repainting only makes sense on a terminal. Redirected to a file
    // or a pipe, carriage returns do not overwrite anything, so the same line
    // would be appended hundreds of times. Under --verbose the log IS the
    // output and a status line would just corrupt it.
    final repaint = !verbose && stdout.hasTerminal;
    var lastPrinted = '';

    void paint(RigState s) {
      phases.add(s.phase);
      if (repaint) {
        stdout.write('\r\x1b[K${_format(s, controller)}');
        return;
      }
      if (verbose) return;
      // Non-terminal: emit only on a material change, so a redirected run
      // stays readable.
      final line = _formatStable(s);
      if (line != lastPrinted) {
        lastPrinted = line;
        stdout.writeln(line);
      }
    }

    final sub = controller.states.listen(paint);

    while (!stop && (deadline == null || DateTime.now().isBefore(deadline))) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (repaint) {
        stdout.write('\r\x1b[K${_format(controller.current, controller)}');
      }
    }

    await sub.cancel();
    await sigint.cancel();
    await controller.stop();

    final elapsed = DateTime.now().difference(started);
    stdout.writeln();
    stdout.writeln();
    stdout.writeln('Session: ${elapsed.inSeconds}s');
    stdout.writeln('  responses  ${controller.responses}');
    stdout.writeln('  desyncs    ${controller.desyncs}');
    stdout.writeln('  timeouts   ${controller.timeouts}');
    stdout.writeln('  rejections ${controller.rejections}');
    stdout.writeln('  resyncs    ${controller.resyncs}');
    stdout.writeln('  phases     ${phases.map((p) => p.name).join(' -> ')}');

    // Success criterion 3.2 is "zero desyncs and zero stuck states". Report a
    // verdict rather than leaving the operator to interpret the numbers.
    final clean = controller.desyncs == 0 && controller.responses > 0;
    stdout.writeln(
      clean
          ? '  VERDICT    clean — no desyncs'
          : '  VERDICT    FAILED — ${controller.desyncs} desync(s)',
    );
    return clean ? 0 : 1;
  }

  /// Timing-free rendering, so a redirected run only prints when something
  /// the operator cares about actually changed.
  String _formatStable(RigState s) {
    final freq = s.vfoAHz == null ? '---' : (s.vfoAHz! / 1e6).toStringAsFixed(6);
    final meter = s.sMeterRaw == null ? '---' : '${s.sMeterRaw}';
    return '$freq MHz  ${s.mode.name.toUpperCase()}  S:$meter  '
        '${s.phase.name}${s.transmitting ? ' [TX]' : ''}';
  }

  String _format(RigState s, RigController c) {
    final freq = s.vfoAHz == null
        ? '     ---.------'
        : (s.vfoAHz! / 1e6).toStringAsFixed(6).padLeft(13);
    final mode = s.mode == RigMode.unknown
        ? '---'
        : s.mode.name.toUpperCase().padRight(3);
    final meter = s.sMeterRaw == null ? '---' : '${s.sMeterRaw}'.padLeft(3);
    final rtt = c.lastRoundTrip == null
        ? '--'
        : '${c.lastRoundTrip!.inMilliseconds}';
    final stale = s.isStale(s.vfoUpdated, const Duration(seconds: 2)) ? ' *stale*' : '';
    final tx = s.transmitting ? ' [TX]' : '';
    return '$freq MHz  $mode  S:$meter  ${rtt}ms  ${s.phase.name}$tx$stale';
  }

  Future<int> _record(CatTransport transport) async {
    const poll = [
      kReadInfo,
      kReadSMeter,
      kReadMode,
      kReadTxState,
      kReadFilterWidth,
    ];

    final seconds = int.tryParse(argResults!.option('seconds') ?? '');
    final deadline = seconds == null
        ? null
        : DateTime.now().add(Duration(seconds: seconds));

    stdout.writeln(
      seconds == null
          ? 'Recording. Spin the VFO knob. Ctrl-C to stop.'
          : 'Recording for ${seconds}s. Spin the VFO knob.',
    );

    var stop = false;
    final sigint = ProcessSignal.sigint.watch().listen((_) => stop = true);
    var responses = 0;
    var rejections = 0;
    final sub = transport.lines.listen((line) {
      responses++;
      if (line == '?') rejections++;
    });

    var i = 0;
    while (!stop && (deadline == null || DateTime.now().isBefore(deadline))) {
      transport.send(poll[i++ % poll.length]);
      // A rejection costs a full CAT TOT of silence, so back off rather than
      // spending the next second shouting at a radio that is not listening.
      await Future<void>.delayed(
        rejections > 0 && responses > 0 ? kRejectionRecovery : kFastPollPeriod,
      );
      if (rejections > 0) rejections = 0;
    }

    await sub.cancel();
    await sigint.cancel();
    stdout.writeln('Captured $responses responses.');
    return 0;
  }
}
