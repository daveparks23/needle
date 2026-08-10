import 'dart:typed_data';

import 'package:needle_cat/src/constants.dart';
import 'package:needle_cat/src/dsp/mock_source.dart';
import 'package:needle_cat/src/dsp/spectrum.dart';
import 'package:test/test.dart';

/// Runs enough mock audio through the analyzer to get one frame.
Float64List _analyze(MockSource source, SpectrumAnalyzer a) {
  Float64List? frame;
  var guard = 0;
  while (frame == null && guard++ < 64) {
    a.feed(source.nextChunk(), (f) => frame ??= Float64List.fromList(f));
  }
  expect(frame, isNotNull, reason: 'mock produced no analysable audio');
  return frame!;
}

void main() {
  group('MockSource', () {
    test('produces samples inside the normalized range', () {
      final s = MockSource();
      final chunk = s.nextChunk();
      expect(chunk, hasLength(kFftHop));
      expect(chunk.every((v) => v >= -1.0 && v <= 1.0), isTrue);
    });

    test('a configured tone lands where it was asked for', () {
      final s = MockSource(
        noiseAmplitude: 0.0,
        tones: [MockTone(hz: 1200, amplitude: 0.5)],
      );
      final a = SpectrumAnalyzer();
      final frame = _analyze(s, a);

      var peak = 0;
      for (var i = 1; i < frame.length; i++) {
        if (frame[i] > frame[peak]) peak = i;
      }
      expect(a.frequencyOfBin(peak), closeTo(1200, 6.0));
    });

    test('noise alone has no dominant peak', () {
      final s = MockSource(noiseAmplitude: 0.05);
      final a = SpectrumAnalyzer();
      final frame = _analyze(s, a);

      final sorted = Float64List.fromList(frame)..sort();
      final median = sorted[sorted.length ~/ 2];
      final max = sorted.last;
      // Noise should not tower over its own median the way a carrier does.
      expect(max - median, lessThan(40));
    });

    test('the streaming API delivers chunks', () async {
      final s = MockSource();
      await s.start();
      final chunk = await s.samples.first.timeout(const Duration(seconds: 2));
      expect(chunk, hasLength(kFftHop));
      await s.stop();
    });

    test('stop closes the stream', () async {
      final s = MockSource();
      await s.start();
      await s.stop();
      expect(s.samples.isEmpty, completion(isTrue));
    });
  });

  group('MockSource.ft8', () {
    test('keys and unkeys on a 15 second cycle', () {
      final signal = MockFt8Signal(baseHz: 1000, startOffset: 0);
      expect(signal.frequencyAt(0.5), isNotNull, reason: 'should be sending');
      expect(
        signal.frequencyAt(13.5),
        isNull,
        reason: '79 symbols at 0.16s ends by ~12.6s',
      );
      expect(signal.frequencyAt(15.5), isNotNull, reason: 'next cycle');
    });

    test('stays within the 8-FSK tone set', () {
      final signal = MockFt8Signal(baseHz: 1000, startOffset: 0);
      for (var t = 0.0; t < 12.0; t += 0.05) {
        final hz = signal.frequencyAt(t);
        if (hz == null) continue;
        final step = (hz - 1000) / MockFt8Signal.toneSpacingHz;
        expect(step, closeTo(step.roundToDouble(), 1e-9));
        expect(step, inInclusiveRange(0, 7));
      }
    });

    test('holds one frequency for a whole symbol', () {
      // Symbol boundaries fall at multiples of 0.16s, so symbol 2 spans
      // 0.32-0.48s. frequencyAt is called once per sample to accumulate
      // phase; if it were not a pure function of the symbol index the tone
      // would wander mid-symbol and smear the line.
      final signal = MockFt8Signal(baseHz: 1000, startOffset: 0);
      final within = [0.33, 0.38, 0.44, 0.479].map(signal.frequencyAt).toSet();
      expect(within, hasLength(1), reason: 'symbol 2 must be one tone');
    });

    test('the tone changes across a symbol boundary', () {
      final signal = MockFt8Signal(baseHz: 1000, startOffset: 0);
      final tones = <double?>{
        for (var symbol = 0; symbol < 20; symbol++)
          signal.frequencyAt(symbol * 0.16 + 0.08),
      };
      expect(
        tones.length,
        greaterThan(3),
        reason: 'a constant tone would not look like 8-FSK',
      );
    });

    test('the preset puts energy in the FT8 passband', () {
      final s = MockSource.ft8();
      final a = SpectrumAnalyzer();
      final frame = _analyze(s, a);

      // Something should be well above the floor somewhere in 300-2600 Hz.
      final lo = (300 / a.binWidthHz).round();
      final hi = (2600 / a.binWidthHz).round();
      final band = frame.sublist(lo, hi);
      final sorted = Float64List.fromList(frame)..sort();
      final median = sorted[sorted.length ~/ 2];
      expect(band.reduce((x, y) => x > y ? x : y), greaterThan(median + 15));
    });
  });
}
