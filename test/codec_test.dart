import 'dart:convert';
import 'dart:io';

import 'package:needle_cat/src/cat/codec.dart';
import 'package:needle_cat/src/cat/commands.dart';
import 'package:test/test.dart';

/// A well-formed IF answer built to the layout in the FT-891 CAT Reference
/// Book (docs/ft891_cat_reference.pdf): 28 characters on the wire, so a
/// 25-character payload once the `IF` prefix and `;` terminator are removed.
///
///   IF | P1(3) | P2(9) | +/-(1) | P3(4) | P4 P5 P6 P7 P8 | P9(2) | P10 | ;
const _ifUsb14305 = 'IF001014305000+000000200000;';
const _ifNegativeClarifier = 'IF001014305000-012000200000;';

/// Runs a wire-format response through the framer, exactly as the transport
/// would, and returns the parsed payload.
String _payloadOf(String wire) {
  final framer = CatFramer()..add(wire.codeUnits);
  final lines = framer.takeLines();
  expect(lines, hasLength(1), reason: 'fixture should frame to one line');
  final parsed = parseResponse(lines.single);
  expect(parsed, isA<CatData>(), reason: 'fixture should parse as data');
  return (parsed! as CatData).payload;
}

void main() {
  group('CatFramer', () {
    test('splits a whole line', () {
      final f = CatFramer()..add(utf8.encode('FA014074000;'));
      expect(f.takeLines(), ['FA014074000']);
    });

    test('reassembles a response split across chunk boundaries', () {
      final f = CatFramer()
        ..add(utf8.encode('FA0140'))
        ..add(utf8.encode('74000;'));
      expect(f.takeLines(), ['FA014074000']);
    });

    test('emits multiple lines arriving in one read', () {
      final f = CatFramer()..add(utf8.encode('FA014074000;MD02;'));
      expect(f.takeLines(), ['FA014074000', 'MD02']);
    });

    test('holds a partial line until its terminator arrives', () {
      final f = CatFramer()..add(utf8.encode('FA0140'));
      expect(f.takeLines(), isEmpty);
      f.add(utf8.encode('74000;'));
      expect(f.takeLines(), ['FA014074000']);
    });

    test('drops embedded garbage bytes without losing the line', () {
      // A wrong-baud port returns bytes like these; they must not corrupt a
      // subsequent good response.
      final f = CatFramer()
        ..add([0xF8, 0x80, 0xFF, ...utf8.encode('FA014074000;')]);
      expect(f.takeLines(), ['FA014074000']);
    });

    test('takeLines drains, so a second call returns nothing new', () {
      final f = CatFramer()..add(utf8.encode('FA014074000;'));
      expect(f.takeLines(), hasLength(1));
      expect(f.takeLines(), isEmpty);
    });

    test('does not grow without bound when no terminator ever arrives', () {
      final f = CatFramer();
      for (var i = 0; i < 1000; i++) {
        f.add(utf8.encode('0123456789'));
      }
      expect(f.takeLines(), isEmpty);
      expect(f.bufferedBytes, lessThanOrEqualTo(CatFramer.maxBufferedBytes));
    });
  });

  group('parseResponse', () {
    test('parses a data response into prefix and payload', () {
      final r = parseResponse('FA014074000');
      expect(r, isA<CatData>());
      final data = r! as CatData;
      expect(data.prefix, 'FA');
      expect(data.payload, '014074000');
    });

    test('recognises the rejection response', () {
      expect(parseResponse('?'), isA<CatRejected>());
    });

    test('returns null for a truncated response', () {
      expect(parseResponse('F'), isNull);
    });

    test('returns null for an empty line', () {
      expect(parseResponse(''), isNull);
    });

    test('returns null for a lowercase or unexpected prefix', () {
      expect(parseResponse('zz123'), isNull);
    });

    test('returns null for a prefix with no payload', () {
      expect(parseResponse('FA'), isNull);
    });
  });

  group('field parsers', () {
    test('parseFrequency reads 9 zero-padded Hz digits', () {
      expect(parseFrequency('014074000'), 14074000);
    });

    test('parseFrequency rejects a short payload', () {
      expect(parseFrequency('01407'), isNull);
    });

    test('parseFrequency rejects non-digits', () {
      expect(parseFrequency('01407400X'), isNull);
    });

    test('parseSMeter reads the 0-255 reading after the fixed P1', () {
      // SM answer is SMP1P2P2P2; -> payload '0' + three digits.
      expect(parseSMeter('0128'), 128);
      expect(parseSMeter('0000'), 0);
      expect(parseSMeter('0255'), 255);
    });

    test('parseSMeter rejects out-of-range and malformed payloads', () {
      expect(parseSMeter('0999'), isNull);
      expect(parseSMeter('012'), isNull);
      expect(parseSMeter('0X28'), isNull);
    });

    test('parseTransmitting maps the TX answer', () {
      // TX P1: 0 = not transmitting, 1 = keyed by CAT, 2 = keyed at the radio.
      expect(parseTransmitting('0'), isFalse);
      expect(parseTransmitting('1'), isTrue);
      expect(parseTransmitting('2'), isTrue);
      expect(parseTransmitting('x'), isNull);
    });
  });

  group('parseIf', () {
    test('the reference layout yields a 25-character payload', () {
      expect(_payloadOf(_ifUsb14305), hasLength(25));
    });

    test('reads frequency and mode from a real-shaped answer', () {
      final r = parseIf(_payloadOf(_ifUsb14305));
      expect(r, isNotNull);
      expect(r!.freqHz, 14305000);
      expect(r.mode, RigMode.usb);
      expect(r.memoryChannel, '001');
      expect(r.clarifierHz, 0);
      expect(r.onVfo, isTrue);
    });

    test('reads a negative clarifier offset', () {
      final r = parseIf(_payloadOf(_ifNegativeClarifier));
      expect(r!.clarifierHz, -120);
    });

    test('rejects a payload of the wrong length', () {
      expect(parseIf('001014305000'), isNull);
    });

    test('rejects a payload with a non-numeric frequency', () {
      expect(parseIf('001014XX5000+0000002000000'), isNull);
    });
  });

  group('modeFromCode', () {
    test('maps the documented mode codes', () {
      expect(modeFromCode('1'), RigMode.lsb);
      expect(modeFromCode('2'), RigMode.usb);
      expect(modeFromCode('3'), RigMode.cw);
      expect(modeFromCode('4'), RigMode.fm);
      expect(modeFromCode('5'), RigMode.am);
      expect(modeFromCode('8'), RigMode.data);
    });

    test('maps an unlisted code to unknown rather than throwing', () {
      expect(modeFromCode('A'), RigMode.unknown);
      expect(modeFromCode(''), RigMode.unknown);
    });
  });

  // Captured verbatim from the dev FT-891 at 9600 baud on 2026-08-10 while it
  // sat on 14.3043 MHz USB. These are the ground truth for every offset above:
  // if a refactor breaks one of these, the codec is wrong, not the fixture.
  group('real radio captures', () {
    test('ID identifies an FT-891', () {
      expect(_payloadOf('ID0650;'), kFt891Identifier);
    });

    test('IF and FA report the same frequency', () {
      final fromIf = parseIf(_payloadOf('IF001014304300+000000200000;'));
      final fromFa = parseFrequency(_payloadOf('FA014304300;'));
      expect(fromIf!.freqHz, 14304300);
      expect(fromFa, 14304300);
      expect(fromIf.freqHz, fromFa);
    });

    test('IF and MD report the same mode', () {
      final fromIf = parseIf(_payloadOf('IF001014304300+000000200000;'))!.mode;
      // MD answer is MDP1P2; -> payload '0' + mode code.
      final fromMd = modeFromCode(_payloadOf('MD02;')[1]);
      expect(fromIf, RigMode.usb);
      expect(fromMd, RigMode.usb);
    });

    test('SM reports a plausible receive-level reading', () {
      expect(parseSMeter(_payloadOf('SM0047;')), 47);
    });

    test('TX reports not-transmitting while receiving', () {
      expect(parseTransmitting(_payloadOf('TX0;')), isFalse);
    });

    test('the radio rejects RX with a bare question mark', () {
      // Sent 'RX;' to the real rig and it answered '?;'. This is why the
      // un-key path uses TX0; -- see kUnkey.
      final framer = CatFramer()..add('?;'.codeUnits);
      expect(parseResponse(framer.takeLines().single), isA<CatRejected>());
    });
  });

  // The strongest check the codec has: every response in a real 60-second
  // session recorded while the VFO was swept 14.074 -> 15.853 MHz.
  group('the whole recorded session parses', () {
    late List<({String command, String response})> exchanges;

    setUpAll(() {
      exchanges = [
        for (final line
            in File('test/fixtures/cat_session_20m.txt').readAsLinesSync())
          if (line.contains(' RX ')) (
            command: '',
            response: line.split(' RX ').last,
          ),
      ];
    });

    test('the capture is substantial enough to be meaningful', () {
      expect(exchanges.length, greaterThan(500));
    });

    test('every recorded response parses as data, none as garbage', () {
      for (final e in exchanges) {
        final framed = CatFramer()..add(e.response.codeUnits);
        final line = framed.takeLines().single;
        expect(
          parseResponse(line),
          isA<CatData>(),
          reason: 'failed on "${e.response}"',
        );
      }
    });

    test('every IF answer yields a plausible HF frequency', () {
      final ifs = exchanges.where((e) => e.response.startsWith('IF'));
      expect(ifs, isNotEmpty);
      for (final e in ifs) {
        final framed = CatFramer()..add(e.response.codeUnits);
        final report = parseIf(
          (parseResponse(framed.takeLines().single)! as CatData).payload,
        );
        expect(report, isNotNull, reason: 'failed on "${e.response}"');
        expect(report!.freqHz, greaterThan(1000000));
        expect(report.freqHz, lessThan(60000000));
        expect(report.mode, RigMode.usb);
        expect(report.onVfo, isTrue);
      }
    });

    test('every SM answer is in range', () {
      for (final e in exchanges.where((e) => e.response.startsWith('SM'))) {
        final framed = CatFramer()..add(e.response.codeUnits);
        final raw = parseSMeter(
          (parseResponse(framed.takeLines().single)! as CatData).payload,
        );
        expect(raw, isNotNull, reason: 'failed on "${e.response}"');
        expect(raw, inInclusiveRange(0, 255));
      }
    });

    test('the session contains no rejections', () {
      // 591 exchanges under heavy knob motion with zero '?;' answers. If a
      // change to the poll set starts provoking rejections, this catches it.
      expect(exchanges.where((e) => e.response.startsWith('?')), isEmpty);
    });
  });

  group('command construction', () {
    test('read commands are bare and semicolon terminated', () {
      expect(kReadVfoA, 'FA;');
      expect(kReadInfo, 'IF;');
      expect(kReadSMeter, 'SM0;');
      expect(kReadTxState, 'TX;');
      expect(kReadFilterWidth, 'SH0;');
    });

    test('setVfoA zero-pads to 9 digits', () {
      expect(setVfoA(14074000), 'FA014074000;');
      expect(setVfoA(3573000), 'FA003573000;');
    });

    test('setVfoA rejects a frequency that will not fit', () {
      expect(() => setVfoA(-1), throwsArgumentError);
      expect(() => setVfoA(1000000000), throwsArgumentError);
    });

    test('the un-key command is TX0, because this radio has no RX command', () {
      // Verified against docs/ft891_cat_reference.pdf: the command table has
      // no RX entry. Sending 'RX;' returns '?;' and leaves the rig KEYED.
      expect(kUnkey, 'TX0;');
      expect(kKeyViaCat, 'TX1;');
    });

    test('readMeter selects a documented meter index', () {
      expect(readMeter(TxMeter.po), 'RM5;');
      expect(readMeter(TxMeter.swr), 'RM6;');
      expect(readMeter(TxMeter.alc), 'RM4;');
      expect(readMeter(TxMeter.id), 'RM7;');
    });
  });
}
