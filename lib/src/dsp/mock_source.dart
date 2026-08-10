/// Synthetic PCM, so the whole scope demo runs with no radio and no sound card.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../constants.dart';
import 'audio_source.dart';

/// A steady tone in the synthetic spectrum.
class MockTone {
  MockTone({required this.hz, this.amplitude = 0.2});

  double hz;
  double amplitude;
}

/// An FT8-shaped emitter: 8-FSK, keyed in 15-second cycles.
///
/// Real FT8 sends 79 symbols of 8-FSK at 6.25 Hz spacing over 12.64 s, then
/// goes quiet until the next quarter-minute. Reproducing that shape — rather
/// than a static tone — is what makes `--mock` look like a band rather than a
/// test pattern, and it exercises the noise-floor tracker against signals that
/// come and go.
class MockFt8Signal {
  MockFt8Signal({
    required this.baseHz,
    this.amplitude = 0.25,
    this.startOffset = 0.0,
    this.seed = 0,
  });

  /// Lowest of the eight tones.
  final double baseHz;
  final double amplitude;

  /// Seconds into the 15 s cycle at which this signal starts.
  final double startOffset;

  /// Selects which pseudo-random symbol sequence this signal sends.
  final int seed;

  static const double toneSpacingHz = 6.25;
  static const double symbolSeconds = 0.16;
  static const int symbolCount = 79;
  static const double cycleSeconds = 15.0;

  /// Frequency this signal is emitting at [t] seconds, or null when idle.
  double? frequencyAt(double t) {
    final inCycle = t % cycleSeconds;
    final elapsed = inCycle - startOffset;
    if (elapsed < 0) return null;

    final symbol = (elapsed / symbolSeconds).floor();
    if (symbol >= symbolCount) return null;

    return baseHz + _toneIndex(symbol) * toneSpacingHz;
  }

  /// Picks a tone from (seed, symbol) as a pure function.
  ///
  /// Must not draw from a Random: [frequencyAt] is called once per *sample*
  /// to accumulate phase, so anything stateful would change the tone mid
  /// symbol and smear the signal into noise instead of drawing a clean line.
  int _toneIndex(int symbol) {
    var h = (seed * 0x9E3779B1) ^ (symbol * 0x85EBCA6B);
    h ^= h >>> 13;
    h = (h * 0xC2B2AE35) & 0x7FFFFFFFFFFFFFFF;
    h ^= h >>> 16;
    return h % 8;
  }
}

/// Generates a noise floor plus optional tones and FT8-shaped signals.
class MockSource implements PcmSource {
  MockSource({
    this.sampleRate = kSampleRate,
    this.chunkSize = kFftHop,
    this.noiseAmplitude = 0.02,
    List<MockTone>? tones,
    List<MockFt8Signal>? signals,
    int seed = 1,
  }) : tones = tones ?? [],
       signals = signals ?? [],
       _random = math.Random(seed);

  /// A 20m FT8 window: a handful of signals spread across the passband,
  /// starting at slightly different offsets so they do not key in lockstep.
  factory MockSource.ft8({int count = 6, int seed = 1}) {
    final random = math.Random(seed);
    return MockSource(
      seed: seed,
      signals: [
        for (var i = 0; i < count; i++)
          MockFt8Signal(
            baseHz: 300 + random.nextDouble() * 2200,
            amplitude: 0.12 + random.nextDouble() * 0.25,
            startOffset: random.nextDouble() * 0.6,
            seed: seed + i * 7919,
          ),
      ],
      tones: [
        // A steady carrier, so there is always something to look at even
        // between FT8 cycles.
        MockTone(hz: 1500, amplitude: 0.05),
      ],
    );
  }

  @override
  final int sampleRate;

  final int chunkSize;
  final double noiseAmplitude;
  final List<MockTone> tones;
  final List<MockFt8Signal> signals;

  final math.Random _random;
  final StreamController<Float64List> _controller =
      StreamController<Float64List>.broadcast();

  /// Continuous phase per emitter, so tones do not click at chunk boundaries.
  final Map<Object, double> _phase = {};

  Timer? _timer;
  int _sampleIndex = 0;

  @override
  Stream<Float64List> get samples => _controller.stream;

  @override
  Future<void> start() async {
    _timer?.cancel();
    // Emit in real time so the waterfall scrolls at a believable rate.
    final period = Duration(
      microseconds: (chunkSize * 1000000 / sampleRate).round(),
    );
    _timer = Timer.periodic(period, (_) => _emit());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (!_controller.isClosed) await _controller.close();
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(nextChunk());
  }

  /// Generates the next chunk. Exposed so tests can pull frames without
  /// waiting on wall-clock timers.
  Float64List nextChunk() {
    final out = Float64List(chunkSize);
    final twoPiOverRate = 2 * math.pi / sampleRate;

    for (var i = 0; i < chunkSize; i++) {
      // Box-Muller would be more correct, but a sum of uniforms is cheap and
      // looks like a noise floor once it is 20*log10'd.
      var sample =
          noiseAmplitude * (_random.nextDouble() + _random.nextDouble() - 1.0);

      final t = (_sampleIndex + i) / sampleRate;

      for (final tone in tones) {
        final phase = _phase.update(
          tone,
          (p) => p + tone.hz * twoPiOverRate,
          ifAbsent: () => 0.0,
        );
        sample += tone.amplitude * math.sin(phase);
      }

      for (final signal in signals) {
        final hz = signal.frequencyAt(t);
        if (hz == null) {
          // Hold the phase so the tone resumes cleanly next cycle.
          continue;
        }
        final phase = _phase.update(
          signal,
          (p) => p + hz * twoPiOverRate,
          ifAbsent: () => 0.0,
        );
        sample += signal.amplitude * math.sin(phase);
      }

      out[i] = sample.clamp(-1.0, 1.0);
    }

    _sampleIndex += chunkSize;
    return out;
  }
}
