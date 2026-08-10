// The CLI layer owns all console output.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:args/command_runner.dart';

import '../cat/serial_transport.dart';
import '../cat/transport.dart';
import '../constants.dart';

/// Lists serial ports and flags the one that is probably the radio.
class PortsCommand extends Command<int> {
  PortsCommand() {
    argParser.addFlag(
      'probe',
      negatable: false,
      help: 'Open each candidate and ask the radio to identify itself. '
          'Sweeps every supported baud, so a wrong CAT RATE menu setting is '
          'reported as such instead of looking like a dead port.',
    );
  }

  @override
  String get name => 'ports';

  @override
  String get description => 'List serial ports and flag the likely CAT port.';

  @override
  Future<int> run() async {
    final List<PortInfo> ports;
    try {
      ports = discoverPorts();
    } on CatTransportException catch (e) {
      stderr.writeln(e);
      return 69;
    }

    if (ports.isEmpty) {
      stdout.writeln('No serial ports found.');
      return 0;
    }

    for (final p in ports) {
      _printPort(p);
    }

    final candidates = ports
        .where((p) => p.likelyCatPort && !p.isDuplicate)
        .toList();
    stdout.writeln();

    if (!argResults!.flag('probe')) {
      if (candidates.isEmpty) {
        stdout.writeln('No likely CAT port identified. Try --probe.');
      } else {
        stdout.writeln(
          'Likely CAT port: ${candidates.map((p) => p.name).join(', ')}',
        );
        stdout.writeln('Confirm with: needle ports --probe');
      }
      return 0;
    }

    return _probe(ports.where((p) => !p.isDuplicate).toList());
  }

  void _printPort(PortInfo p) {
    final flag = p.isDuplicate
        ? '  ·'
        : p.likelyCatPort
        ? '  ✓'
        : '   ';
    stdout.writeln('$flag ${p.name}');
    stdout.writeln(
      '      vid=${_hex(p.vendorId)} pid=${_hex(p.productId)} '
      'serial=${p.serialNumber ?? '-'}',
    );
    if (p.productName != null) {
      stdout.writeln('      ${p.productName}');
    }
    stdout.writeln('      ${p.reason}');
  }

  Future<int> _probe(List<PortInfo> ports) async {
    // Probe the flagged candidates first so the common case answers fast.
    final ordered = [
      ...ports.where((p) => p.likelyCatPort),
      ...ports.where((p) => !p.likelyCatPort && p.serialNumber != null),
    ];

    if (ordered.isEmpty) {
      stdout.writeln('Nothing worth probing.');
      return 1;
    }

    stdout.writeln('Probing ${ordered.length} port(s)...');
    var found = false;

    for (final p in ordered) {
      final result = await probePort(p.name);
      if (result == null) {
        stdout.writeln('  ${p.name}: no response at any supported baud');
        continue;
      }

      found = true;
      final who = result.isFt891
          ? 'FT-891'
          : 'radio id ${result.identifier ?? '(unrecognised answer)'}';
      stdout.writeln('  ${p.name}: $who at ${result.baud} baud');

      if (result.baud != kDefaultBaud) {
        stdout.writeln();
        stdout.writeln(
          '  Note: the radio answered at ${result.baud}, not $kDefaultBaud.',
        );
        stdout.writeln(
          '  Set radio menu 05-06 CAT RATE to $kDefaultBaud — meter polling '
          'cannot sustain 10 Hz at ${result.baud}.',
        );
        stdout.writeln('  Until then, pass --baud ${result.baud}.');
      }
    }

    return found ? 0 : 1;
  }

  String _hex(int? v) =>
      v == null ? '-' : '0x${v.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}
