import 'dart:async';

import 'package:needle_cat/src/cat/commands.dart';
import 'package:needle_cat/src/cat/rig_controller.dart';
import 'package:needle_cat/src/cat/rig_state.dart';
import 'package:needle_cat/src/cat/transport.dart';
import 'package:needle_cat/src/constants.dart';
import 'package:test/test.dart';

/// A transport whose answers are entirely under the test's control.
///
/// Records every send with a timestamp so the single-in-flight rule can be
/// asserted rather than assumed.
class FakeTransport implements CatTransport {
  FakeTransport({this.turnaround = const Duration(milliseconds: 5)});

  /// How long the "radio" takes to answer.
  Duration turnaround;

  /// Commands this transport silently ignores.
  final Set<String> blackHole = {};

  /// Commands answered with the rejection response.
  final Set<String> reject = {};

  /// Canned answers by command; each is consumed in order then the last
  /// repeats.
  final Map<String, List<String>> answers = {};

  final List<({String command, Duration at})> sent = [];
  final Stopwatch _clock = Stopwatch();
  final StreamController<String> _lines = StreamController<String>.broadcast();

  int openCount = 0;
  int closeCount = 0;
  bool _open = false;

  /// Number of subsequent [open] calls that should throw.
  ///
  /// Models the real failure: the CP2105 lives inside the radio, so powering
  /// the radio off removes the device node entirely and reopening throws
  /// rather than merely returning nothing.
  int failOpensRemaining = 0;

  @override
  bool get isOpen => _open;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> open() async {
    openCount++;
    if (!_clock.isRunning) _clock.start();
    if (failOpensRemaining > 0) {
      failOpensRemaining--;
      throw const CatTransportException('device node is gone');
    }
    _open = true;
  }

  @override
  Future<void> close() async {
    closeCount++;
    _open = false;
  }

  @override
  void send(String command) {
    if (!_open) throw const CatTransportException('not open');
    sent.add((command: command, at: _clock.elapsed));

    if (blackHole.contains(command)) return;

    final reply = reject.contains(command)
        ? '?'
        : _nextAnswer(command) ?? '?';

    Timer(turnaround, () {
      if (!_lines.isClosed) _lines.add(reply);
    });
  }

  String? _nextAnswer(String command) {
    final queued = answers[command];
    if (queued == null || queued.isEmpty) return null;
    return queued.length == 1 ? queued.first : queued.removeAt(0);
  }

  Future<void> dispose() => _lines.close();
}

FakeTransport _healthyRadio() => FakeTransport()
  ..answers[kReadInfo] = ['IF001014074000+000000200000']
  ..answers[kReadSMeter] = ['SM0047']
  ..answers[kReadMode] = ['MD02']
  ..answers[kReadTxState] = ['TX0']
  ..answers[kReadFilterWidth] = ['SH0014']
  ..answers[kReadNarrow] = ['NA00'];

void main() {
  group('single command in flight', () {
    test('never sends again before the previous answer arrives', () async {
      final t = _healthyRadio()..turnaround = const Duration(milliseconds: 20);
      final c = RigController(t);
      await c.start();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      await c.stop();

      expect(t.sent.length, greaterThan(3), reason: 'needs enough traffic');
      // Every send must be at least one turnaround after the previous one.
      for (var i = 1; i < t.sent.length; i++) {
        final gap = t.sent[i].at - t.sent[i - 1].at;
        expect(
          gap.inMilliseconds,
          greaterThanOrEqualTo(18),
          reason: 'commands ${i - 1} and $i overlapped: '
              '${t.sent[i - 1].command} then ${t.sent[i].command}',
        );
      }
      await t.dispose();
    });

    test('a burst of user commands is serialised, not pipelined', () async {
      final t = _healthyRadio()..turnaround = const Duration(milliseconds: 15);
      final c = RigController(t);
      await c.start();

      await Future.wait([
        c.request('FA;'),
        c.request('FB;'),
        c.request('MD0;'),
      ]);
      await c.stop();

      final idx = <int>[
        for (var i = 0; i < t.sent.length; i++)
          if (const ['FA;', 'FB;', 'MD0;'].contains(t.sent[i].command)) i,
      ];
      for (var i = 1; i < idx.length; i++) {
        final gap = t.sent[idx[i]].at - t.sent[idx[i - 1]].at;
        expect(gap.inMilliseconds, greaterThanOrEqualTo(13));
      }
      await t.dispose();
    });
  });

  group('priority', () {
    test('a user command preempts queued polls', () async {
      final t = _healthyRadio()..turnaround = const Duration(milliseconds: 10);
      final c = RigController(t);
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final before = t.sent.length;
      unawaited(c.request('FA;'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final after = t.sent.sublist(before).map((s) => s.command).toList();
      expect(after, isNotEmpty);
      expect(
        after.indexOf('FA;'),
        lessThanOrEqualTo(1),
        reason: 'user command should jump the queue, saw $after',
      );
      await c.stop();
      await t.dispose();
    });
  });

  group('timeouts and retries', () {
    test('retries once, then gives up and keeps the queue moving', () async {
      final t = _healthyRadio()..blackHole.add(kReadFilterWidth);
      final c = RigController(
        t,
        commandTimeout: const Duration(milliseconds: 40),
        slowPollPeriod: const Duration(milliseconds: 60),
      );
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await c.stop();

      final shCount =
          t.sent.where((s) => s.command == kReadFilterWidth).length;
      expect(shCount, 2, reason: 'one attempt plus exactly one retry');
      expect(
        t.sent.where((s) => s.command == kReadSMeter).length,
        greaterThan(1),
        reason: 'other commands must keep flowing after a degraded one',
      );
      await t.dispose();
    });

    test('a degraded command is not retried forever', () async {
      final t = _healthyRadio()..blackHole.add(kReadFilterWidth);
      final c = RigController(
        t,
        commandTimeout: const Duration(milliseconds: 30),
        slowPollPeriod: const Duration(milliseconds: 60),
      );
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await c.stop();
      expect(c.degradedCommands, contains(kReadFilterWidth));
      await t.dispose();
    });
  });

  group('rejection handling', () {
    test('a rejected command is sent once, never retried', () async {
      final t = _healthyRadio()..reject.add(kReadFilterWidth);
      final c = RigController(
        t,
        slowPollPeriod: const Duration(milliseconds: 60),
      );
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.stop();

      expect(
        t.sent.where((s) => s.command == kReadFilterWidth).length,
        1,
        reason: 'the SH lockup bug turns blind retries into a flood',
      );
      await t.dispose();
    });

    test('the queue goes quiet for CAT TOT after a rejection', () async {
      // Measured on the radio: after '?;' it ignores CAT for a full second.
      // Anything sent during that window is thrown away, so the controller
      // must wait rather than burn commands into a rig that is not listening.
      final t = _healthyRadio()..reject.add(kReadFilterWidth);
      final c = RigController(
        t,
        slowPollPeriod: const Duration(milliseconds: 60),
      );
      await c.start();

      await Future<void>.delayed(const Duration(milliseconds: 900));
      await c.stop();

      final rejectedAt = t.sent
          .firstWhere((s) => s.command == kReadFilterWidth)
          .at;
      final after = t.sent.where((s) => s.at > rejectedAt).toList();
      for (final s in after) {
        expect(
          (s.at - rejectedAt).inMilliseconds,
          greaterThanOrEqualTo(kRejectionRecovery.inMilliseconds - 30),
          reason: 'sent ${s.command} during the CAT TOT dead window',
        );
      }
      await t.dispose();
    });
  });

  group('resync', () {
    test('consecutive timeouts trigger close, reopen and a phase walk', () async {
      final t = _healthyRadio();
      // The radio goes away entirely.
      t.blackHole.addAll([
        kReadInfo,
        kReadSMeter,
        kReadMode,
        kReadTxState,
        kReadFilterWidth,
        kReadNarrow,
      ]);

      final c = RigController(
        t,
        commandTimeout: const Duration(milliseconds: 30),
        reconnectBackoff: const Duration(milliseconds: 40),
      );
      final phases = <ConnectionPhase>[];
      final sub = c.states.listen((s) => phases.add(s.phase));

      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await c.stop();
      await sub.cancel();

      expect(t.closeCount, greaterThan(0), reason: 'should have closed');
      expect(t.openCount, greaterThan(1), reason: 'should have reopened');
      expect(phases, contains(ConnectionPhase.degraded));
      expect(phases, contains(ConnectionPhase.connecting));
      await t.dispose();
    });

    test('keeps retrying when the device node has vanished', () async {
      // Powering the radio off removes the CP2105 from the USB bus, so the
      // reopen throws. Nothing else can restart the controller: with the
      // transport closed no command is sent, so no timeout fires, so nothing
      // schedules another resync. Without an explicit retry it wedges here
      // forever -- which is exactly what success criterion 3.3 forbids.
      final t = _healthyRadio();
      final c = RigController(
        t,
        commandTimeout: const Duration(milliseconds: 25),
        reconnectBackoff: const Duration(milliseconds: 40),
        slowPollPeriod: const Duration(milliseconds: 60),
      );
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Operator switches the radio off: it stops answering AND the device
      // node disappears, so every reopen attempt throws.
      t.blackHole.addAll([
        kReadInfo,
        kReadSMeter,
        kReadMode,
        kReadTxState,
        kReadFilterWidth,
        kReadNarrow,
      ]);
      t.failOpensRemaining = 3;
      final opensAtOutage = t.openCount;

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        t.openCount,
        greaterThan(opensAtOutage + 1),
        reason: 'must keep retrying while the node is missing',
      );

      // Radio comes back: the node reappears and it answers again.
      t.blackHole.clear();

      await c.states
          .firstWhere((s) => s.phase == ConnectionPhase.ready)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => fail('controller wedged after a failed reopen'),
          );

      await c.stop();
      await t.dispose();
    });

    test('recovers to ready when the radio answers again', () async {
      final t = _healthyRadio()..blackHole.add(kReadInfo);
      final c = RigController(
        t,
        commandTimeout: const Duration(milliseconds: 30),
        reconnectBackoff: const Duration(milliseconds: 40),
      );
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Radio comes back.
      t.blackHole.clear();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(c.current.phase, ConnectionPhase.ready);
      expect(c.current.connected, isTrue);
      await c.stop();
      await t.dispose();
    });
  });

  group('state stream', () {
    test('parses a real IF answer into frequency and mode', () async {
      final t = _healthyRadio();
      final c = RigController(t);
      await c.start();
      await c.states.firstWhere((s) => s.vfoAHz != null);

      expect(c.current.vfoAHz, 14074000);
      expect(c.current.mode, RigMode.usb);
      await c.stop();
      await t.dispose();
    });

    test('does not emit when nothing changed', () async {
      final t = _healthyRadio();
      final c = RigController(t);
      var emissions = 0;
      final sub = c.states.listen((_) => emissions++);

      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await c.stop();
      await sub.cancel();

      // Everything is constant after the first few reads, so a 500ms run at
      // 10Hz must not produce dozens of identical snapshots.
      expect(emissions, lessThan(10));
      await t.dispose();
    });

    test('routes the S-meter through the zero debounce', () async {
      final t = _healthyRadio()
        ..answers[kReadSMeter] = ['SM0047', 'SM0000', 'SM0000', 'SM0051'];
      final c = RigController(t);
      await c.start();

      final seen = <int?>[];
      final sub = c.states.listen((s) => seen.add(s.sMeterRaw));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await c.stop();
      await sub.cancel();

      expect(seen, isNot(contains(0)), reason: 'two zeros must not be believed');
      await t.dispose();
    });

    test('tracks transmit state from TX;', () async {
      final t = _healthyRadio()..answers[kReadTxState] = ['TX1'];
      final c = RigController(t);
      await c.start();
      await c.states.firstWhere((s) => s.transmitting);
      expect(c.current.transmitting, isTrue);
      await c.stop();
      await t.dispose();
    });
  });

  group('lifecycle', () {
    test('stop is idempotent and leaves the transport closed', () async {
      final t = _healthyRadio();
      final c = RigController(t);
      await c.start();
      await c.stop();
      await c.stop();
      expect(t.isOpen, isFalse);
      await t.dispose();
    });

    test('reports round-trip timing for --verbose', () async {
      final t = _healthyRadio()..turnaround = const Duration(milliseconds: 12);
      final c = RigController(t);
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.lastRoundTrip, isNotNull);
      expect(c.lastRoundTrip!.inMilliseconds, greaterThanOrEqualTo(10));
      await c.stop();
      await t.dispose();
    });
  });
}
