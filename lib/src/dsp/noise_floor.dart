/// Rolling estimate of the noise floor, so the display auto-scales.
///
/// Without this the waterfall washes out the moment band conditions change:
/// a fixed colour range that suits a quiet evening is solid white at noon.
library;

import 'dart:typed_data';

import '../constants.dart';

/// Tracks a low percentile of recent spectra.
///
/// Per frame it takes the [percentile] value of the bins — a low percentile
/// rather than a mean, because a mean is dragged upward by every carrier on
/// the band, which is precisely the thing the floor should ignore. Those
/// per-frame estimates go into a ring buffer and the reported floor is their
/// median, which keeps one anomalous frame from moving the display.
class NoiseFloorTracker {
  NoiseFloorTracker({
    this.percentile = kNoiseFloorPercentile,
    int? windowFrames,
  }) : windowFrames = windowFrames ??
           (kNoiseFloorWindow.inMilliseconds * kTargetFps / 1000).round() {
    _ring = Float64List(this.windowFrames);
  }

  /// Which quantile of each frame's bins counts as "floor". 0.25 by default.
  final double percentile;

  /// How many frames the estimate looks back over.
  final int windowFrames;

  late final Float64List _ring;
  int _count = 0;
  int _next = 0;
  bool _frozen = false;

  /// Fallback until the first frame arrives. Finite so the colour mapping
  /// never has to cope with infinity.
  static const double _initialFloorDb = -120.0;

  /// Whether updates are currently ignored.
  bool get isFrozen => _frozen;

  /// Stops accepting frames.
  ///
  /// Spec 6.6: keying up paints a solid bar across the spectrum, and letting
  /// that into the estimate poisons the floor for several seconds after
  /// unkeying — long after the display would otherwise have recovered.
  void freeze() => _frozen = true;

  /// Resumes accepting frames.
  void unfreeze() => _frozen = false;

  /// Feeds one magnitude frame.
  ///
  /// The frame is not modified: it is a reused scratch buffer shared with the
  /// renderer, so sorting it in place would corrupt what gets drawn.
  void add(Float64List magsDb) {
    if (_frozen || magsDb.isEmpty) return;

    final sorted = Float64List.fromList(magsDb)..sort();
    final index = (sorted.length * percentile)
        .floor()
        .clamp(0, sorted.length - 1);

    _ring[_next] = sorted[index];
    _next = (_next + 1) % windowFrames;
    if (_count < windowFrames) _count++;
  }

  /// The current floor estimate in dB.
  double get floorDb {
    if (_count == 0) return _initialFloorDb;
    final window = Float64List.sublistView(_ring, 0, _count)..sort();
    return window[_count ~/ 2];
  }

  /// Forgets everything. Use after a long gap, when old frames say nothing
  /// about current conditions.
  void reset() {
    _count = 0;
    _next = 0;
  }
}
