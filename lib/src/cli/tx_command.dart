// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../cat/rig_controller.dart';
import '../cat/serial_transport.dart';
import '../cat/transmit_guard.dart';
import '../cat/transport.dart';
import '../constants.dart';

/// A single, explicitly guarded test transmission.
///
/// Spec 7: transmit must be unreachable except through a deliberate
/// subcommand *and* an explicit flag. There is no path from any other command
/// to a key-down.
class TxCommand extends Command<int> {
  TxCommand() {
    argParser
      ..addOption('port', abbr: 'p', help: 'CAT serial device.')
      ..addFlag(
        'allow-transmit',
        negatable: false,
        help: 'Required. Without this the command refuses to key the radio.',
      )
      ..addOption(
        'seconds',
        defaultsTo: '2',
        help: 'Key-down duration. Capped at ${kMaxKeyDown.inSeconds}s by a watchdog.',
      );
  }

  @override
  String get name => 'tx';

  @override
  String get description =>
      'Key the transmitter briefly for testing (requires --allow-transmit).';

  @override
  Future<int> run() async {
    final args = argResults!;
    final port = args.option('port');
    if (port == null) usageException('--port is required.');

    if (!args.flag('allow-transmit')) {
      stderr.writeln(const TransmitNotAllowed());
      stderr.writeln();
      stderr.writeln('Connect a dummy load before enabling this.');
      return 77;
    }

    final requested = Duration(seconds: int.parse(args.option('seconds')!));
    if (requested > kMaxKeyDown) {
      stderr.writeln(
        'Refusing ${requested.inSeconds}s: the hard limit is '
        '${kMaxKeyDown.inSeconds}s.',
      );
      return 64;
    }

    final transport = SerialTransport(
      port,
      baud: int.tryParse(globalResults?.option('baud') ?? '') ?? kDefaultBaud,
    );
    final controller = RigController(transport);
    final guard = TransmitGuard(controller, allowTransmit: true);

    // Register the escape hatches BEFORE anything can key the radio.
    StreamSubscription<ProcessSignal>? sigint;
    Future<void> panicUnkey(String why) async {
      stderr.writeln('\n$why — un-keying.');
      await guard.unkey();
      await controller.stop();
    }

    try {
      await controller.start();
    } on CatTransportException catch (e) {
      stderr.writeln(e);
      return 69;
    }

    sigint = ProcessSignal.sigint.watch().listen((_) async {
      await panicUnkey('Interrupted');
      exit(130);
    });

    stdout.writeln(
      'Transmitting for ${requested.inSeconds}s. '
      'Watchdog at ${kMaxKeyDown.inSeconds}s. Ctrl-C stops immediately.',
    );

    var code = 0;
    try {
      await guard.transmit(() async {
        for (var i = requested.inSeconds; i > 0; i--) {
          stdout.writeln('  TX $i...');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      });
      stdout.writeln('Done — receiver restored.');
    } on Object catch (e) {
      // transmit() un-keys in its own finally; this is belt and braces.
      await guard.unkey();
      stderr.writeln('Transmission failed: $e');
      code = 70;
    } finally {
      guard.dispose();
      await sigint.cancel();
      await controller.stop();
    }
    return code;
  }
}
