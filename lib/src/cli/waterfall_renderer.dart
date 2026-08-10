// The CLI layer owns all console output.
// ignore_for_file: avoid_print

/// ANSI rendering for the terminal waterfall.
///
/// Lives under `cli/` because spec 12 forbids anything in the core from
/// assuming a console. Kept separate from `scope_command.dart` so the pooling
/// and colour mapping can be unit tested without a terminal.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Turns magnitude frames into coloured terminal rows.
class WaterfallRenderer {
  WaterfallRenderer({required this.columns});

  /// Terminal width in character cells.
  final int columns;

  /// Upper half block: the foreground paints the top row and the background
  /// the bottom, giving two spectra per line of terminal.
  static const String halfBlock = '▀';

  static const String reset = '\x1b[0m';

  /// Reduces a frame to one value per column by **max**-pooling.
  ///
  /// Averaging would bury a narrow carrier among its quiet neighbours — an
  /// FT8 signal is a few bins wide and would vanish at 80 columns. Taking the
  /// maximum is what keeps single-bin signals visible, which is the entire
  /// point of the display.
  Float64List downsample(Float64List bins) {
    final out = Float64List(columns);
    if (bins.isEmpty) return out;

    for (var c = 0; c < columns; c++) {
      final start = (c * bins.length / columns).floor();
      final end = math.max(
        start + 1,
        ((c + 1) * bins.length / columns).floor(),
      );
      var peak = bins[start.clamp(0, bins.length - 1)];
      for (var i = start; i < end && i < bins.length; i++) {
        if (bins[i] > peak) peak = bins[i];
      }
      out[c] = peak;
    }
    return out;
  }

  /// Renders two spectra as one line of half-block cells.
  String renderRows(
    Float64List top,
    Float64List bottom,
    double floorDb,
    double rangeDb,
  ) {
    final buffer = StringBuffer();
    final width = math.min(columns, math.min(top.length, bottom.length));

    for (var c = 0; c < width; c++) {
      final fg = colorFor(top[c], floorDb, rangeDb);
      final bg = colorFor(bottom[c], floorDb, rangeDb);
      buffer
        ..write('\x1b[38;2;${fg.r};${fg.g};${fg.b}m')
        ..write('\x1b[48;2;${bg.r};${bg.g};${bg.b}m')
        ..write(halfBlock);
    }
    buffer.write(reset);
    return buffer.toString();
  }

  /// Maps a dB value onto the colour ramp.
  ///
  /// Anything at or below [floorDb] is black; anything at or above
  /// `floorDb + rangeDb` clips to white.
  ({int r, int g, int b}) colorFor(double db, double floorDb, double rangeDb) {
    final t = rangeDb <= 0
        ? 0.0
        : ((db - floorDb) / rangeDb).clamp(0.0, 1.0).toDouble();
    return _ramp(t);
  }

  /// Classic waterfall ramp: black, blue, cyan, green, yellow, white.
  ///
  /// Monotonic in brightness so it still reads as intensity in a screenshot,
  /// and on a monochrome terminal.
  static ({int r, int g, int b}) _ramp(double t) {
    const stops = <({double at, int r, int g, int b})>[
      (at: 0.00, r: 0, g: 0, b: 0),
      (at: 0.20, r: 0, g: 0, b: 110),
      (at: 0.40, r: 0, g: 160, b: 190),
      (at: 0.60, r: 0, g: 200, b: 60),
      (at: 0.80, r: 240, g: 220, b: 0),
      (at: 1.00, r: 255, g: 255, b: 255),
    ];

    for (var i = 0; i < stops.length - 1; i++) {
      final lo = stops[i];
      final hi = stops[i + 1];
      if (t > hi.at) continue;
      final span = hi.at - lo.at;
      final u = span <= 0 ? 0.0 : (t - lo.at) / span;
      return (
        r: (lo.r + (hi.r - lo.r) * u).round().clamp(0, 255),
        g: (lo.g + (hi.g - lo.g) * u).round().clamp(0, 255),
        b: (lo.b + (hi.b - lo.b) * u).round().clamp(0, 255),
      );
    }
    final last = stops.last;
    return (r: last.r, g: last.g, b: last.b);
  }

  /// A frequency axis labelled in audio Hz.
  String axis(double maxHz) {
    final line = List<String>.filled(columns, '─');
    final labels = List<String>.filled(columns, ' ');

    // A label roughly every 10 columns, snapped to round frequencies.
    const stepHz = 500.0;
    for (var hz = 0.0; hz <= maxHz; hz += stepHz) {
      final col = ((hz / maxHz) * (columns - 1)).round();
      if (col < 0 || col >= columns) continue;
      line[col] = '┬';
      final text = hz >= 1000 ? '${(hz / 1000).toStringAsFixed(1)}k' : '${hz.toInt()}';
      final start = (col - text.length ~/ 2).clamp(0, columns - text.length);
      for (var i = 0; i < text.length; i++) {
        labels[start + i] = text[i];
      }
    }
    return '${line.join()}\n${labels.join()}';
  }

  /// Marks the IF passband edges derived from `SH;`.
  ///
  /// Returns null when the width is unknown — the renderer must not invent
  /// edges it was not told about.
  String? passbandMarkers(double? lowHz, double? highHz, double maxHz) {
    if (lowHz == null || highHz == null || maxHz <= 0) return null;
    final row = List<String>.filled(columns, ' ');
    for (final (hz, glyph) in [(lowHz, '['), (highHz, ']')]) {
      final col = ((hz / maxHz) * (columns - 1)).round();
      if (col < 0 || col >= columns) continue;
      row[col] = glyph;
    }
    return row.join();
  }
}
