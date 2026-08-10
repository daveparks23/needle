// Argument parsing and dispatch only — no logic (spec §9).
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<int>('needle', 'FT-891 CAT and spectrum tooling.')
        ..argParser.addFlag(
          'verbose',
          abbr: 'v',
          negatable: false,
          help: 'Log round-trip timings and raw serial traffic.',
        )
        ..argParser.addOption('log', help: 'Also write logs to this file.')
        ..argParser.addOption(
          'baud',
          defaultsTo: '38400',
          help: 'CAT rate. Requires radio menu 05-06 to match.',
        );

  // Subcommands are registered in later tasks.

  try {
    final results = runner.parse(args);
    _configureLogging(
      verbose: results.flag('verbose'),
      logFile: results.option('log'),
    );
    exitCode = await runner.runCommand(results) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}

void _configureLogging({required bool verbose, String? logFile}) {
  Logger.root.level = verbose ? Level.ALL : Level.INFO;
  final sink = logFile == null
      ? null
      : File(logFile).openWrite(mode: FileMode.append);

  Logger.root.onRecord.listen((record) {
    final line = '${record.time.toIso8601String()} '
        '${record.level.name.padRight(7)} ${record.loggerName}: '
        '${record.message}';
    if (record.level >= Level.WARNING) {
      stderr.writeln(line);
    } else if (verbose) {
      stderr.writeln(line);
    }
    sink?.writeln(line);
  });
}
