// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../cat/codec.dart';
import '../cat/commands.dart';
import '../cat/mock_transport.dart';
import '../cat/recording_transport.dart';
import '../cat/serial_transport.dart';
import '../cat/transport.dart';
import '../constants.dart';

/// One-shot and streaming CAT access.
class CatCommand extends Command<int> {
  CatCommand() {
    argParser
      ..addOption('port', abbr: 'p', help: 'Serial device, e.g. /dev/cu.usbserial-XXXX0.')
      ..addFlag('mock', negatable: false, help: 'Replay the bundled fixture instead of using hardware.')
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

    if (send == null && record == null) {
      usageException('Nothing to do: pass --send or --record.');
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
