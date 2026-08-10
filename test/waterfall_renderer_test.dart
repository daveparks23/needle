import 'dart:typed_data';

import 'package:needle_cat/src/cli/waterfall_renderer.dart';
import 'package:test/test.dart';

Float64List _flat(double db, {int n = 513}) =>
    Float64List(n)..fillRange(0, n, db);

void main() {
  group('downsample', () {
    test('max-pools so a narrow carrier survives', () {
      // One loud bin among 513, squeezed into 80 columns. Averaging would
      // dilute it by ~6x and hide an FT8 signal entirely.
      final bins = _flat(-100)..[200] = -10;
      final pooled = WaterfallRenderer(columns: 80).downsample(bins);
      expect(
        pooled.reduce((a, b) => a > b ? a : b),
        -10,
        reason: 'the carrier must survive pooling at full strength',
      );
    });

    test('puts the carrier in the right column', () {
      final bins = _flat(-100)..[200] = -10;
      final pooled = WaterfallRenderer(columns: 80).downsample(bins);
      var peak = 0;
      for (var i = 1; i < pooled.length; i++) {
        if (pooled[i] > pooled[peak]) peak = i;
      }
      expect(peak, closeTo(200 * 80 / 513, 1));
    });

    test('produces exactly one value per column', () {
      for (final columns in [20, 80, 200, 513, 600]) {
        final pooled =
            WaterfallRenderer(columns: columns).downsample(_flat(-90));
        expect(pooled, hasLength(columns));
      }
    });

    test('handles a terminal wider than the bin count', () {
      final pooled = WaterfallRenderer(columns: 600).downsample(_flat(-90));
      expect(pooled.every((v) => v == -90), isTrue);
    });

    test('handles an empty frame without throwing', () {
      expect(
        WaterfallRenderer(columns: 40).downsample(Float64List(0)),
        hasLength(40),
      );
    });
  });

  group('colour mapping', () {
    final r = WaterfallRenderer(columns: 80);

    test('the floor is black and the top is white', () {
      expect(r.colorFor(-100, -100, 40), (r: 0, g: 0, b: 0));
      expect(r.colorFor(-60, -100, 40), (r: 255, g: 255, b: 255));
    });

    test('anything above the range clips rather than wrapping', () {
      expect(r.colorFor(0, -100, 40), (r: 255, g: 255, b: 255));
      expect(r.colorFor(1000, -100, 40), (r: 255, g: 255, b: 255));
    });

    test('anything below the floor stays black', () {
      expect(r.colorFor(-140, -100, 40), (r: 0, g: 0, b: 0));
    });

    test('brightness increases monotonically across the ramp', () {
      var previous = -1.0;
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        final c = r.colorFor(-100 + t * 40, -100, 40);
        final luma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
        expect(
          luma,
          greaterThanOrEqualTo(previous - 1),
          reason: 'ramp must read as intensity, including in a screenshot',
        );
        previous = luma;
      }
    });

    test('a zero range does not divide by zero', () {
      expect(r.colorFor(-50, -100, 0), (r: 0, g: 0, b: 0));
    });
  });

  group('renderRows', () {
    final r = WaterfallRenderer(columns: 10);

    test('emits one half-block per column and resets at the end', () {
      final line = r.renderRows(_flat(-90, n: 10), _flat(-90, n: 10), -100, 40);
      expect(
        WaterfallRenderer.halfBlock.allMatches(line).length,
        10,
      );
      expect(line, endsWith(WaterfallRenderer.reset));
    });

    test('encodes the top row as foreground and the bottom as background', () {
      final line = r.renderRows(
        _flat(-60, n: 10), // top: full scale -> white fg
        _flat(-100, n: 10), // bottom: floor -> black bg
        -100,
        40,
      );
      expect(line, contains('\x1b[38;2;255;255;255m'));
      expect(line, contains('\x1b[48;2;0;0;0m'));
    });

    test('a shorter row does not overrun', () {
      final line = r.renderRows(_flat(-90, n: 4), _flat(-90, n: 10), -100, 40);
      expect(WaterfallRenderer.halfBlock.allMatches(line).length, 4);
    });
  });

  group('axis and markers', () {
    test('labels the frequency axis in audio Hz', () {
      final axis = WaterfallRenderer(columns: 80).axis(3000);
      expect(axis, contains('┬'));
      expect(axis, contains('1.0k'));
      expect(axis, contains('2.0k'));
    });

    test('passband markers sit at the requested frequencies', () {
      final row = WaterfallRenderer(columns: 100).passbandMarkers(300, 2700, 3000);
      expect(row, isNotNull);
      expect(row!.indexOf('['), closeTo(10, 1));
      expect(row.indexOf(']'), closeTo(89, 1));
    });

    test('markers are omitted when the filter width is unknown', () {
      // The renderer must not invent passband edges it was never told about;
      // SH; can be unavailable after the known firmware lockup.
      final r = WaterfallRenderer(columns: 80);
      expect(r.passbandMarkers(null, 2700, 3000), isNull);
      expect(r.passbandMarkers(300, null, 3000), isNull);
    });
  });
}
