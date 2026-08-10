import 'dart:math' as math;
import 'dart:typed_data';

import 'package:needle_cat/src/constants.dart';
import 'package:needle_cat/src/dsp/spectrum.dart';
import 'package:test/test.dart';

/// Generates [samples] of a unit-amplitude sine at [hz].
Float64List _sine(double hz, int samples, {int rate = kSampleRate}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = math.sin(2 * math.pi * hz * i / rate);
  }
  return out;
}

/// Index of the largest value.
int _argmax(Float64List v) {
  var best = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[best]) best = i;
  }
  return best;
}

/// Runs [pcm] through a fresh analyzer and returns the first frame.
Float64List _firstFrame(Float64List pcm, {SpectrumAnalyzer? analyzer}) {
  final a = analyzer ?? SpectrumAnalyzer();
  Float64List? frame;
  a.feed(pcm, (f) => frame ??= Float64List.fromList(f));
  expect(frame, isNotNull, reason: 'analyzer produced no frame');
  return frame!;
}

void main() {
  group('bin geometry', () {
    test('trims to 513 bins covering 0-3000 Hz', () {
      final a = SpectrumAnalyzer();
      expect(a.displayBinCount, 513);
      expect(a.frequencyOfBin(0), 0.0);
      expect(a.frequencyOfBin(512), closeTo(3000.0, 6.0));
    });

    test('bin spacing matches sampleRate / fftSize', () {
      final a = SpectrumAnalyzer();
      expect(a.binWidthHz, closeTo(kSampleRate / kFftSize, 1e-9));
      expect(a.binWidthHz, closeTo(5.859, 0.01));
    });

    test('frequencyOfBin is linear', () {
      final a = SpectrumAnalyzer();
      expect(a.frequencyOfBin(100), closeTo(100 * a.binWidthHz, 1e-6));
    });
  });

  group('peak detection', () {
    test('a 1000 Hz sine peaks in the bin that maps back to 1000 Hz', () {
      final a = SpectrumAnalyzer();
      final frame = _firstFrame(_sine(1000, kFftSize * 2), analyzer: a);
      expect(a.frequencyOfBin(_argmax(frame)), closeTo(1000.0, 6.0));
    });

    test('holds across the whole display range', () {
      for (final hz in [200.0, 700.0, 1500.0, 2400.0, 2900.0]) {
        final a = SpectrumAnalyzer();
        final frame = _firstFrame(_sine(hz, kFftSize * 2), analyzer: a);
        expect(
          a.frequencyOfBin(_argmax(frame)),
          closeTo(hz, 6.0),
          reason: 'failed at $hz Hz',
        );
      }
    });

    test('interpolated peak beats raw bin resolution', () {
      // 1002.9 Hz sits between bins; parabolic interpolation should land
      // closer than the 5.86 Hz bin width allows on its own.
      final a = SpectrumAnalyzer();
      final frame = _firstFrame(_sine(1002.9, kFftSize * 2), analyzer: a);
      expect(a.interpolatedPeakHz(frame), closeTo(1002.9, 2.0));
    });

    test('resolves two tones a few bins apart', () {
      final a = SpectrumAnalyzer();
      final mixed = Float64List(kFftSize * 2);
      final lo = _sine(1000, mixed.length);
      final hi = _sine(1200, mixed.length);
      for (var i = 0; i < mixed.length; i++) {
        mixed[i] = 0.5 * lo[i] + 0.5 * hi[i];
      }
      final frame = _firstFrame(mixed, analyzer: a);

      final loBin = (1000 / a.binWidthHz).round();
      final hiBin = (1200 / a.binWidthHz).round();
      final floor = frame[(2500 / a.binWidthHz).round()];
      expect(frame[loBin], greaterThan(floor + 20));
      expect(frame[hiBin], greaterThan(floor + 20));
    });
  });

  group('dB scaling', () {
    test('silence produces finite values, not negative infinity', () {
      final frame = _firstFrame(Float64List(kFftSize * 2));
      expect(frame.every((v) => v.isFinite), isTrue);
    });

    test('the scale is dBFS, so 0 dB means full scale', () {
      // Without normalising by the transform length, magnitudes grow with FFT
      // size and read as large positive numbers that mean nothing. Calibrated
      // dBFS is what lets an operator set DATA OUT LEVEL (menu 08-11) to a
      // real target instead of guessing.
      //
      // Tolerance covers Hann scalloping loss: a tone between bin centres
      // reads up to ~1.4 dB low, and 1000 Hz sits at bin 170.67.
      for (final amplitude in [1.0, 0.5, 0.1]) {
        final a = SpectrumAnalyzer();
        final pcm = Float64List.fromList(
          _sine(1000, kFftSize * 2).map((v) => v * amplitude).toList(),
        );
        final frame = _firstFrame(pcm, analyzer: a);
        final expected = 20 * math.log(amplitude) / math.ln10;
        expect(
          frame[_argmax(frame)],
          closeTo(expected, 1.5),
          reason: 'amplitude $amplitude should read near $expected dBFS',
        );
      }
    });

    test('a louder tone reads higher in dB', () {
      final quiet = _sine(1000, kFftSize * 2);
      final loud = Float64List.fromList(quiet.map((v) => v * 10).toList());
      final a = SpectrumAnalyzer();
      final qf = _firstFrame(quiet, analyzer: a);
      final lf = _firstFrame(loud, analyzer: SpectrumAnalyzer());
      final bin = (1000 / a.binWidthHz).round();
      // 10x amplitude is +20 dB.
      expect(lf[bin] - qf[bin], closeTo(20.0, 1.0));
    });
  });

  group('streaming', () {
    test('overlapping frames advance by the hop, not the whole window', () {
      final a = SpectrumAnalyzer();
      var frames = 0;
      // Four hops of data should yield roughly (4*hop - fftSize)/hop + 1
      // frames once the first full window is available.
      a.feed(_sine(1000, kFftHop * 6), (_) => frames++);
      expect(frames, greaterThanOrEqualTo(4));
    });

    test('data split across feeds produces the same peak', () {
      final whole = _sine(1000, kFftSize * 2);
      final a = SpectrumAnalyzer();
      Float64List? frame;
      // Deliberately ragged chunk sizes, as a process pipe delivers them.
      var offset = 0;
      for (final size in [37, 1000, 4096, 3000]) {
        final end = math.min(offset + size, whole.length);
        if (offset >= end) break;
        a.feed(
          Float64List.sublistView(whole, offset, end),
          (f) => frame ??= Float64List.fromList(f),
        );
        offset = end;
      }
      a.feed(Float64List.sublistView(whole, offset), (f) => frame ??= Float64List.fromList(f));
      expect(frame, isNotNull);
      expect(a.frequencyOfBin(_argmax(frame!)), closeTo(1000.0, 6.0));
    });

    test('flush emits the tail so shutdown loses nothing', () {
      final a = SpectrumAnalyzer();
      var streamed = 0;
      a.feed(_sine(1000, kFftSize + kFftHop ~/ 2), (_) => streamed++);
      var flushed = 0;
      a.flush((_) => flushed++);
      expect(flushed, greaterThan(0));
    });
  });

  group('configuration', () {
    test('a narrower display range keeps fewer bins', () {
      final a = SpectrumAnalyzer(displayMaxHz: 1500);
      expect(a.displayBinCount, lessThan(513));
      expect(a.frequencyOfBin(a.displayBinCount - 1), closeTo(1500, 6.0));
    });

    test('a different FFT size still maps frequencies correctly', () {
      final a = SpectrumAnalyzer(fftSize: 4096, hop: 2048);
      final frame = _firstFrame(_sine(1000, 4096 * 2), analyzer: a);
      expect(a.frequencyOfBin(_argmax(frame)), closeTo(1000.0, 12.0));
    });

    test('rejects a hop larger than the window', () {
      expect(
        () => SpectrumAnalyzer(fftSize: 1024, hop: 2048),
        throwsArgumentError,
      );
    });
  });
}
