/// Streaming STFT: PCM in, trimmed magnitude frames in dB out.
///
/// This layer must never import anything from `../cat/`. The scope command
/// subscribes to both and gates its own rendering; the coupling is
/// one-directional and lives in the CLI.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import '../constants.dart';

/// Windows PCM, runs an FFT, and reports only the bins worth displaying.
///
/// Of the 4097 bins an 8192-point real FFT produces at 48 kHz, only the first
/// 513 fall inside the 0-3000 Hz range a communications receiver passes. The
/// other 94% are discarded here, before they can cross an isolate boundary.
class SpectrumAnalyzer {
  SpectrumAnalyzer({
    this.fftSize = kFftSize,
    this.hop = kFftHop,
    this.sampleRate = kSampleRate,
    this.displayMaxHz = kDisplayMaxHz,
  }) : _stft = STFT(fftSize, Window.hanning(fftSize)) {
    if (hop <= 0 || hop > fftSize) {
      throw ArgumentError.value(
        hop,
        'hop',
        'must be positive and no larger than fftSize ($fftSize)',
      );
    }
    _binWidthHz = sampleRate / fftSize;
    _displayBinCount = (displayMaxHz / _binWidthHz).floor() + 1;
    _scratch = Float64List(_displayBinCount);
  }

  final int fftSize;
  final int hop;
  final int sampleRate;
  final double displayMaxHz;

  final STFT _stft;
  late final double _binWidthHz;
  late final int _displayBinCount;

  /// Reused across frames; callers that keep a frame must copy it.
  late final Float64List _scratch;

  /// Hz between adjacent bins.
  double get binWidthHz => _binWidthHz;

  /// Number of bins inside [displayMaxHz]. 513 at the defaults.
  int get displayBinCount => _displayBinCount;

  /// Centre frequency of [index], in Hz.
  double frequencyOfBin(int index) =>
      _stft.frequency(index, sampleRate.toDouble());

  /// Feeds PCM and reports every complete frame.
  ///
  /// Input may arrive in arbitrary chunk sizes — a process pipe splits wherever
  /// it likes — and leftover samples are carried to the next call.
  ///
  /// The [Float64List] handed to [onFrame] is reused. Anything kept beyond the
  /// callback must be copied.
  void feed(List<double> pcm, void Function(Float64List magsDb) onFrame) {
    _stft.stream(pcm, (freq) => _report(freq, onFrame), hop);
  }

  /// Emits whatever remains buffered, zero-padded. Call on shutdown.
  void flush(void Function(Float64List magsDb) onFrame) {
    _stft.flush((freq) => _report(freq, onFrame));
  }

  void _report(Float64x2List freq, void Function(Float64List) onFrame) {
    final mags = freq.discardConjugates().magnitudes();
    final limit = math.min(_displayBinCount, mags.length);
    for (var i = 0; i < limit; i++) {
      // 20*log10(mag). The epsilon keeps digital silence finite rather than
      // negative infinity, which would poison the colour mapping downstream.
      _scratch[i] = 20 * (math.log(mags[i] + kLogEpsilon) / math.ln10);
    }
    onFrame(_scratch);
  }

  /// Refines the peak to sub-bin accuracy by fitting a parabola through the
  /// strongest bin and its two neighbours.
  ///
  /// A raw bin index is only accurate to +/- half a bin (2.9 Hz at the
  /// defaults); interpolation is what makes `audio --peak` track a whistle
  /// smoothly instead of stepping.
  double interpolatedPeakHz(Float64List magsDb) {
    var peak = 0;
    for (var i = 1; i < magsDb.length; i++) {
      if (magsDb[i] > magsDb[peak]) peak = i;
    }
    if (peak == 0 || peak == magsDb.length - 1) return frequencyOfBin(peak);

    final left = magsDb[peak - 1];
    final centre = magsDb[peak];
    final right = magsDb[peak + 1];
    final denom = left - 2 * centre + right;
    if (denom == 0) return frequencyOfBin(peak);

    final offset = 0.5 * (left - right) / denom;
    return (peak + offset) * _binWidthHz;
  }
}
