/// The seam between audio capture and the DSP chain.
///
/// Implementations must not assume a console, a single process, or a
/// particular capture backend — the Flutter app supplies its own.
library;

import 'dart:typed_data';

/// A source of mono PCM.
abstract class PcmSource {
  /// Normalized mono samples in -1.0..1.0.
  ///
  /// Chunk sizes are not guaranteed: a process pipe splits wherever it likes,
  /// so consumers must buffer rather than assume a frame per event.
  Stream<Float64List> get samples;

  int get sampleRate;

  Future<void> start();

  Future<void> stop();
}

/// Raised when audio capture cannot start or dies unexpectedly.
class PcmSourceException implements Exception {
  const PcmSourceException(this.message, {this.remedy});

  final String message;

  /// An actionable next step, when one exists.
  final String? remedy;

  @override
  String toString() =>
      remedy == null ? 'PcmSourceException: $message' : '$message\n\n$remedy';
}
