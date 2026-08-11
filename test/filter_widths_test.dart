import 'package:needle_cat/src/cat/commands.dart';
import 'package:needle_cat/src/cat/filter_widths.dart';
import 'package:test/test.dart';

void main() {
  group('the dev radio', () {
    test('USB with narrow off and SH:14 is a 2400 Hz SSB filter', () {
      // Ground truth: the FT-891 reported SH0014 and NA00 while in USB, and
      // 2400 Hz is the standard SSB roofing width. If this breaks, the table
      // was transcribed wrong.
      expect(
        filterWidthHz(mode: RigMode.usb, narrow: false, index: 14),
        2400,
      );
    });
  });

  group('index 14 means different things per mode', () {
    test('wide SSB', () {
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: 14), 2400);
    });
    test('wide CW', () {
      expect(filterWidthHz(mode: RigMode.cw, narrow: false, index: 14), 1700);
    });
    test('wide RTTY', () {
      expect(filterWidthHz(mode: RigMode.rtty, narrow: false, index: 14), 1700);
    });
    test('narrow SSB does not offer it at all', () {
      expect(filterWidthHz(mode: RigMode.usb, narrow: true, index: 14), isNull);
    });
  });

  group('defaults at index 0', () {
    test('match the reference book', () {
      expect(filterWidthHz(mode: RigMode.usb, narrow: true, index: 0), 1500);
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: 0), 2400);
      expect(filterWidthHz(mode: RigMode.cw, narrow: true, index: 0), 500);
      expect(filterWidthHz(mode: RigMode.cw, narrow: false, index: 0), 2400);
      expect(filterWidthHz(mode: RigMode.rtty, narrow: true, index: 0), 300);
      expect(filterWidthHz(mode: RigMode.rtty, narrow: false, index: 0), 500);
    });
  });

  group('table edges', () {
    test('the widest SSB setting is 3200 Hz at index 21', () {
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: 21), 3200);
    });

    test('the narrowest CW setting is 50 Hz at index 1', () {
      expect(filterWidthHz(mode: RigMode.cw, narrow: true, index: 1), 50);
    });

    test('index 9 is the only one both SSB columns offer', () {
      expect(filterWidthHz(mode: RigMode.usb, narrow: true, index: 9), 1800);
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: 9), 1800);
    });

    test('out-of-range indices are null, not a crash', () {
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: 22), isNull);
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: -1), isNull);
      expect(filterWidthHz(mode: RigMode.usb, narrow: false, index: 999), isNull);
    });

    test('gaps in the printed table are null rather than invented', () {
      // Wide SSB has no entries at 1-8; the book prints dashes.
      for (var i = 1; i <= 8; i++) {
        expect(
          filterWidthHz(mode: RigMode.usb, narrow: false, index: i),
          isNull,
          reason: 'wide SSB index $i should be unavailable',
        );
      }
    });
  });

  group('modes without a filter table', () {
    test('AM and FM return null', () {
      for (final mode in [
        RigMode.am,
        RigMode.amNarrow,
        RigMode.fm,
        RigMode.fmNarrow,
      ]) {
        expect(filterGroupFor(mode), isNull, reason: '$mode');
        expect(
          filterWidthHz(mode: mode, narrow: false, index: 0),
          isNull,
          reason: '$mode has a fixed filter and is absent from the table',
        );
      }
    });

    test('an unknown mode returns null rather than guessing', () {
      expect(filterWidthHz(mode: RigMode.unknown, narrow: false, index: 0), isNull);
    });
  });

  group('mode grouping', () {
    test('both sidebands share the SSB table', () {
      expect(filterGroupFor(RigMode.lsb), FilterGroup.ssb);
      expect(filterGroupFor(RigMode.usb), FilterGroup.ssb);
    });

    test('CW and reverse CW share the CW table', () {
      expect(filterGroupFor(RigMode.cw), FilterGroup.cw);
      expect(filterGroupFor(RigMode.cwReverse), FilterGroup.cw);
    });

    test('DATA is grouped with RTTY/PSK', () {
      expect(filterGroupFor(RigMode.data), FilterGroup.rttyPsk);
      expect(filterGroupFor(RigMode.dataReverse), FilterGroup.rttyPsk);
      expect(filterGroupFor(RigMode.rtty), FilterGroup.rttyPsk);
    });
  });
}
