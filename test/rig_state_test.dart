import 'package:needle_cat/src/cat/commands.dart';
import 'package:needle_cat/src/cat/rig_state.dart';
import 'package:test/test.dart';

void main() {
  group('SMeterDebouncer', () {
    test('a non-zero reading passes through instantly', () {
      final d = SMeterDebouncer();
      expect(d.update(120), 120);
      expect(d.update(45), 45);
    });

    test('needs three consecutive zeros before believing zero', () {
      final d = SMeterDebouncer()..update(120);
      expect(d.update(0), 120, reason: 'first zero is held');
      expect(d.update(0), 120, reason: 'second zero is held');
      expect(d.update(0), 0, reason: 'third zero is believed');
    });

    test('a single non-zero resets the zero run', () {
      final d = SMeterDebouncer()
        ..update(120)
        ..update(0)
        ..update(0);
      expect(d.update(90), 90);
      expect(d.update(0), 90, reason: 'zero run restarted from scratch');
      expect(d.update(0), 90);
      expect(d.update(0), 0);
    });

    test('leading zeros before any reading report null', () {
      expect(SMeterDebouncer().update(0), isNull);
    });

    test('stays at zero once zero is believed', () {
      final d = SMeterDebouncer()
        ..update(120)
        ..update(0)
        ..update(0)
        ..update(0);
      expect(d.update(0), 0);
      expect(d.update(0), 0);
    });

    test('reset clears the held value and the run', () {
      final d = SMeterDebouncer()
        ..update(120)
        ..reset();
      expect(d.update(0), isNull);
    });
  });

  group('RigState', () {
    test('copyWith preserves untouched fields', () {
      const a = RigState.initial();
      final b = a.copyWith(vfoAHz: 14074000);
      expect(b.vfoAHz, 14074000);
      expect(b.phase, a.phase);
      expect(b.mode, a.mode);
    });

    test('equal states compare equal and hash equal', () {
      final a = const RigState.initial().copyWith(vfoAHz: 1);
      final b = const RigState.initial().copyWith(vfoAHz: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing states are unequal, so the stream can suppress repeats', () {
      final a = const RigState.initial().copyWith(vfoAHz: 1);
      final b = const RigState.initial().copyWith(vfoAHz: 2);
      expect(a, isNot(b));
    });

    test('timestamps participate in equality', () {
      final a = const RigState.initial().copyWith(
        sMeterRaw: 10,
        metersUpdated: DateTime(2026),
      );
      final b = const RigState.initial().copyWith(
        sMeterRaw: 10,
        metersUpdated: DateTime(2025),
      );
      expect(a, isNot(b));
    });

    test('a field group is stale once its timestamp ages out', () {
      final s = const RigState.initial().copyWith(
        sMeterRaw: 100,
        metersUpdated: DateTime(2020),
      );
      expect(s.isStale(s.metersUpdated, const Duration(seconds: 1)), isTrue);
    });

    test('a never-updated field group counts as stale', () {
      const s = RigState.initial();
      expect(s.isStale(s.vfoUpdated, const Duration(seconds: 1)), isTrue);
    });

    test('a fresh field group is not stale', () {
      final s = const RigState.initial().copyWith(
        vfoAHz: 1,
        vfoUpdated: DateTime.now(),
      );
      expect(s.isStale(s.vfoUpdated, const Duration(seconds: 30)), isFalse);
    });

    test('the initial state is disconnected and empty', () {
      const s = RigState.initial();
      expect(s.phase, ConnectionPhase.disconnected);
      expect(s.connected, isFalse);
      expect(s.transmitting, isFalse);
      expect(s.vfoAHz, isNull);
      expect(s.sMeterRaw, isNull);
      expect(s.sMeterSUnits, isNull, reason: 'no calibration table exists yet');
    });

    test('copyWith cannot clear a field, by design', () {
      // Staleness, not nulling, is how consumers grey out old readings after a
      // dropout. Documented here so nobody "fixes" it into null sentinels.
      final s = const RigState.initial().copyWith(sMeterRaw: 42);
      expect(s.copyWith(sMeterRaw: null).sMeterRaw, 42);
    });

    test('copyWith can carry a mode through', () {
      final s = const RigState.initial().copyWith(mode: RigMode.usb);
      expect(s.mode, RigMode.usb);
    });
  });
}
