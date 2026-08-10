import 'dart:typed_data';

import 'package:needle_cat/src/dsp/noise_floor.dart';
import 'package:test/test.dart';

Float64List _flat(double db, {int bins = 513}) =>
    Float64List(bins)..fillRange(0, bins, db);

/// A flat floor with [count] strong bins, as a real band looks.
Float64List _withSignals(double floorDb, double signalDb, int count) {
  final frame = _flat(floorDb);
  for (var i = 0; i < count; i++) {
    frame[50 + i * 7] = signalDb;
  }
  return frame;
}

void main() {
  group('NoiseFloorTracker', () {
    test('reports the level of a flat spectrum', () {
      final t = NoiseFloorTracker();
      for (var i = 0; i < 10; i++) {
        t.add(_flat(-90));
      }
      expect(t.floorDb, closeTo(-90, 0.5));
    });

    test('a few strong signals barely move it', () {
      // 500 bins of floor and 13 carriers: a mean would be dragged upward,
      // which is exactly why this tracks a low percentile instead.
      final t = NoiseFloorTracker();
      for (var i = 0; i < 10; i++) {
        t.add(_withSignals(-100, -20, 13));
      }
      expect(t.floorDb, closeTo(-100, 1.0));
    });

    test('follows the floor when band conditions change', () {
      final t = NoiseFloorTracker(windowFrames: 10);
      for (var i = 0; i < 20; i++) {
        t.add(_flat(-100));
      }
      expect(t.floorDb, closeTo(-100, 0.5));

      for (var i = 0; i < 20; i++) {
        t.add(_flat(-70));
      }
      expect(
        t.floorDb,
        closeTo(-70, 0.5),
        reason: 'auto-scaling is the whole point; a stuck floor washes out',
      );
    });

    test('old frames age out of the window', () {
      final t = NoiseFloorTracker(windowFrames: 4);
      t.add(_flat(-40));
      for (var i = 0; i < 4; i++) {
        t.add(_flat(-100));
      }
      expect(t.floorDb, closeTo(-100, 0.5));
    });

    test('reports a usable value before the window fills', () {
      final t = NoiseFloorTracker(windowFrames: 75);
      t.add(_flat(-88));
      expect(t.floorDb, closeTo(-88, 0.5));
    });

    test('has a sane value before any frame arrives', () {
      expect(NoiseFloorTracker().floorDb.isFinite, isTrue);
    });

    group('freezing', () {
      test('a frozen tracker ignores what it is fed', () {
        // Spec 6.6: keying up paints a solid bar across the waterfall and
        // would poison the floor for seconds afterwards.
        final t = NoiseFloorTracker();
        for (var i = 0; i < 10; i++) {
          t.add(_flat(-100));
        }
        final before = t.floorDb;

        t.freeze();
        for (var i = 0; i < 50; i++) {
          t.add(_flat(-5));
        }
        expect(t.floorDb, before);
      });

      test('unfreezing resumes tracking', () {
        final t = NoiseFloorTracker(windowFrames: 5)..freeze();
        for (var i = 0; i < 10; i++) {
          t.add(_flat(-5));
        }
        t.unfreeze();
        for (var i = 0; i < 10; i++) {
          t.add(_flat(-95));
        }
        expect(t.floorDb, closeTo(-95, 0.5));
      });

      test('freeze is idempotent', () {
        final t = NoiseFloorTracker()
          ..add(_flat(-90))
          ..freeze()
          ..freeze();
        final before = t.floorDb;
        t.add(_flat(0));
        expect(t.floorDb, before);
      });
    });

    test('does not mutate the frame it is given', () {
      // Frames are a reused scratch buffer; sorting in place would corrupt
      // the renderer's view of the same data.
      final t = NoiseFloorTracker();
      final frame = _withSignals(-100, -20, 5);
      final copy = Float64List.fromList(frame);
      t.add(frame);
      expect(frame, copy);
    });

    test('ignores an empty frame rather than throwing', () {
      final t = NoiseFloorTracker()..add(Float64List(0));
      expect(t.floorDb.isFinite, isTrue);
    });
  });
}
