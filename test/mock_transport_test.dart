import 'dart:async';
import 'dart:io';

import 'package:needle_cat/src/cat/mock_transport.dart';
import 'package:needle_cat/src/cat/recording_transport.dart';
import 'package:needle_cat/src/cat/transport.dart';
import 'package:test/test.dart';

/// A transcript in the format described by [MockTransport].
const _fixture = '''
# needle CAT transcript v1
0 TX FA;
12 RX FA014074000;
20 TX SM0;
31 RX SM0047;
40 TX SM0;
52 RX SM0102;
60 TX IF;
75 RX IF001014074000+000000200000;
''';

void main() {
  _fixtureFileTests();
  group('MockTransport', () {
    test('replays the recorded response for a sent command', () async {
      final t = MockTransport(fixture: _fixture, speed: 1000);
      await t.open();
      final got = t.lines.first;
      t.send('FA;');
      expect(await got, 'FA014074000');
      await t.close();
    });

    test('answers an unknown command with the rejection response', () async {
      final t = MockTransport(fixture: _fixture, speed: 1000);
      await t.open();
      final got = t.lines.first;
      t.send('ZZ;');
      expect(await got, '?');
      await t.close();
    });

    test('walks recorded values so a repeated poll looks alive', () async {
      final t = MockTransport(fixture: _fixture, speed: 1000);
      await t.open();
      final seen = <String>[];
      final sub = t.lines.listen(seen.add);

      t.send('SM0;');
      await _settle();
      t.send('SM0;');
      await _settle();

      expect(seen, ['SM0047', 'SM0102']);
      await sub.cancel();
      await t.close();
    });

    test('loops the transcript so long demos never run dry', () async {
      final t = MockTransport(fixture: _fixture, speed: 1000);
      await t.open();
      final seen = <String>[];
      final sub = t.lines.listen(seen.add);

      for (var i = 0; i < 4; i++) {
        t.send('SM0;');
        await _settle();
      }

      expect(seen, ['SM0047', 'SM0102', 'SM0047', 'SM0102']);
      await sub.cancel();
      await t.close();
    });

    test('reports open state', () async {
      final t = MockTransport(fixture: _fixture, speed: 1000);
      expect(t.isOpen, isFalse);
      await t.open();
      expect(t.isOpen, isTrue);
      await t.close();
      expect(t.isOpen, isFalse);
    });

    test('sending before open throws rather than silently dropping', () {
      final t = MockTransport(fixture: _fixture, speed: 1000);
      expect(() => t.send('FA;'), throwsA(isA<CatTransportException>()));
    });

    test('ignores comments and blank lines in the transcript', () async {
      final t = MockTransport(
        fixture: '\n# a comment\n\n0 TX FA;\n5 RX FA000007074000;\n',
        speed: 1000,
      );
      await t.open();
      final got = t.lines.first;
      t.send('FA;');
      expect(await got, 'FA000007074000');
      await t.close();
    });

    test('rejects a transcript with no usable exchanges', () {
      expect(
        () => MockTransport(fixture: '# nothing here\n'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('honours the speed multiplier', () async {
      // Recorded gap is 12ms; at speed 0.5 it should take at least 20ms.
      final t = MockTransport(fixture: _fixture, speed: 0.5);
      await t.open();
      final watch = Stopwatch()..start();
      final got = t.lines.first;
      t.send('FA;');
      await got;
      watch.stop();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(20));
      await t.close();
    });
  });

  group('RecordingTransport', () {
    test('tees both directions to the sink in transcript format', () async {
      final inner = MockTransport(fixture: _fixture, speed: 1000);
      final captured = StringBuffer();
      final rec = RecordingTransport(inner, captured);

      await rec.open();
      final got = rec.lines.first;
      rec.send('FA;');
      await got;
      await rec.close();

      final lines = captured
          .toString()
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();

      expect(lines, hasLength(2));
      expect(lines[0], matches(RegExp(r'^\d+ TX FA;$')));
      expect(lines[1], matches(RegExp(r'^\d+ RX FA014074000;$')));
    });

    test('writes a header so the file is self-describing', () async {
      final inner = MockTransport(fixture: _fixture, speed: 1000);
      final captured = StringBuffer();
      final rec = RecordingTransport(inner, captured);
      await rec.open();
      await rec.close();
      expect(captured.toString(), startsWith('# needle CAT transcript v1'));
    });

    test('a recorded transcript replays through MockTransport', () async {
      // The round trip that makes fixtures worth capturing at all.
      final inner = MockTransport(fixture: _fixture, speed: 1000);
      final captured = StringBuffer();
      final rec = RecordingTransport(inner, captured);
      await rec.open();
      final first = rec.lines.first;
      rec.send('SM0;');
      await first;
      await rec.close();

      final replay = MockTransport(fixture: captured.toString(), speed: 1000);
      await replay.open();
      final got = replay.lines.first;
      replay.send('SM0;');
      expect(await got, 'SM0047');
      await replay.close();
    });

    test('forwards isOpen from the wrapped transport', () async {
      final inner = MockTransport(fixture: _fixture, speed: 1000);
      final rec = RecordingTransport(inner, StringBuffer());
      expect(rec.isOpen, isFalse);
      await rec.open();
      expect(rec.isOpen, isTrue);
      expect(inner.isOpen, isTrue);
      await rec.close();
      expect(rec.isOpen, isFalse);
    });
  });
}

/// The fixture that ships with the package must actually drive the mock,
/// otherwise `needle scope --mock` breaks without any test noticing.
void _fixtureFileTests() {
  group('bundled fixture', () {
    late String bundled;

    setUpAll(() {
      bundled = File('test/fixtures/cat_session_20m.txt').readAsStringSync();
    });

    test('loads and answers the commands the scope demo polls', () async {
      final t = MockTransport(fixture: bundled, speed: 1000);
      await t.open();
      final seen = <String>[];
      final sub = t.lines.listen(seen.add);

      for (final cmd in ['ID;', 'IF;', 'MD0;', 'TX;', 'SH0;', 'FA;']) {
        t.send(cmd);
        await _settle();
      }

      expect(seen, hasLength(6));
      expect(seen[0], 'ID0650');
      expect(seen[1], startsWith('IF'));
      expect(seen[2], 'MD02');
      expect(seen[3], 'TX0');
      expect(seen[4], 'SH0014');
      expect(seen[5], startsWith('FA'));

      await sub.cancel();
      await t.close();
    });

    test('replays the bogus S-meter zeros the debouncer exists to absorb', () async {
      final t = MockTransport(fixture: bundled, speed: 1000);
      await t.open();
      final seen = <String>[];
      final sub = t.lines.listen(seen.add);

      for (var i = 0; i < 8; i++) {
        t.send('SM0;');
        await _settle();
      }

      expect(
        seen.where((s) => s == 'SM0000').length,
        greaterThanOrEqualTo(3),
        reason: 'fixture must contain a run of zeros to be worth having',
      );
      expect(seen.any((s) => s != 'SM0000'), isTrue);

      await sub.cancel();
      await t.close();
    });
  });
}

/// Lets the mock's scheduled reply fire.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
