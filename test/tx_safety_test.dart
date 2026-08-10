import 'dart:async';
import 'dart:io';

import 'package:needle_cat/src/cat/commands.dart';
import 'package:needle_cat/src/cat/rig_controller.dart';
import 'package:needle_cat/src/cat/transmit_guard.dart';
import 'package:needle_cat/src/cat/transport.dart';
import 'package:test/test.dart';

/// Records every command so the safety guarantees can be asserted rather than
/// assumed.
class RecordingFake implements CatTransport {
  final List<String> sent = [];
  final StreamController<String> _lines = StreamController<String>.broadcast();
  bool _open = false;

  @override
  bool get isOpen => _open;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async => _open = false;

  @override
  void send(String command) {
    sent.add(command);
    // Answer with the command's own prefix so the controller stays in sync.
    final prefix = command.length >= 2 ? command.substring(0, 2) : command;
    Timer(const Duration(milliseconds: 2), () {
      if (!_lines.isClosed) _lines.add('${prefix}0');
    });
  }

  Future<void> dispose() => _lines.close();
}

void main() {
  late RecordingFake transport;
  late RigController controller;

  setUp(() async {
    transport = RecordingFake();
    controller = RigController(
      transport,
      fastPollPeriod: const Duration(seconds: 10),
      mediumPollPeriod: const Duration(seconds: 10),
      slowPollPeriod: const Duration(seconds: 10),
    );
    await controller.start();
    transport.sent.clear();
  });

  tearDown(() async {
    await controller.stop();
    await transport.dispose();
  });

  group('authorisation', () {
    test('transmit is refused without --allow-transmit', () async {
      final guard = TransmitGuard(controller, allowTransmit: false);
      await expectLater(
        guard.transmit(() async {}),
        throwsA(isA<TransmitNotAllowed>()),
      );
      expect(
        transport.sent,
        isNot(contains(kKeyViaCat)),
        reason: 'nothing may key the transmitter without explicit consent',
      );
      guard.dispose();
    });

    test('refusing to transmit does not leave a watchdog armed', () async {
      final guard = TransmitGuard(controller, allowTransmit: false);
      try {
        await guard.transmit(() async {});
      } on TransmitNotAllowed {
        // expected
      }
      expect(guard.isKeyed, isFalse);
      guard.dispose();
    });

    test('un-keying is always permitted, even when transmit is disabled', () {
      // If the rig is somehow keyed, stopping it must never be gated.
      final guard = TransmitGuard(controller, allowTransmit: false);
      expect(guard.unkey(), completes);
      guard.dispose();
    });
  });

  group('key-down lifecycle', () {
    test('keys, runs the body, then un-keys', () async {
      final guard = TransmitGuard(controller, allowTransmit: true);
      await guard.transmit(() async {});

      expect(transport.sent, contains(kKeyViaCat));
      expect(transport.sent, contains(kUnkey));
      expect(
        transport.sent.indexOf(kKeyViaCat),
        lessThan(transport.sent.lastIndexOf(kUnkey)),
      );
      expect(guard.isKeyed, isFalse);
      guard.dispose();
    });

    test('an exception during key-down still un-keys', () async {
      final guard = TransmitGuard(controller, allowTransmit: true);
      await expectLater(
        guard.transmit<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(transport.sent, contains(kUnkey));
      expect(guard.isKeyed, isFalse);
      guard.dispose();
    });

    test('the watchdog un-keys after the hard limit', () async {
      final guard = TransmitGuard(
        controller,
        allowTransmit: true,
        maxKeyDown: const Duration(milliseconds: 80),
      );

      // A body that never finishes on its own.
      unawaited(guard.transmit(() => Completer<void>().future));
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(
        transport.sent,
        contains(kUnkey),
        reason: 'the watchdog must fire without anyone asking it to',
      );
      expect(guard.isKeyed, isFalse);
      guard.dispose();
    });

    test('unkey is idempotent', () async {
      final guard = TransmitGuard(controller, allowTransmit: true);
      await guard.transmit(() async {});
      final afterFirst = transport.sent.where((c) => c == kUnkey).length;
      await guard.unkey();
      expect(transport.sent.where((c) => c == kUnkey).length, afterFirst);
      guard.dispose();
    });
  });

  group('the RX trap', () {
    test('the un-key constant is TX0, not RX', () {
      expect(kUnkey, 'TX0;');
      expect(kUnkey, isNot('RX;'));
    });

    test('no source file can send RX;', () {
      // The FT-891 command table has no RX entry and the real radio answers
      // '?;' to it, then ignores CAT for a full second. Sending RX; to un-key
      // would leave the transmitter keyed.
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('commands.dart')) continue; // documents the trap
        expect(
          f.readAsStringSync(),
          isNot(contains("'RX;'")),
          reason: '${f.path} would leave the transmitter keyed',
        );
      }
    });
  });
}
