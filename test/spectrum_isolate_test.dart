import 'dart:math' as math;
import 'dart:typed_data';

import 'package:needle_cat/src/constants.dart';
import 'package:needle_cat/src/dsp/spectrum_isolate.dart';
import 'package:test/test.dart';

Float64List _sine(double hz, int samples) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = math.sin(2 * math.pi * hz * i / kSampleRate);
  }
  return out;
}

void main() {
  test('spawns, analyses, and returns trimmed frames', () async {
    final worker = await SpectrumIsolate.spawn();
    final first = worker.frames.first;

    worker.feed(_sine(1000, kFftSize * 2));

    final frame = await first.timeout(const Duration(seconds: 5));
    expect(
      frame,
      hasLength(513),
      reason: 'only the display bins may cross the port, never all 4097',
    );

    var peak = 0;
    for (var i = 1; i < frame.length; i++) {
      if (frame[i] > frame[peak]) peak = i;
    }
    expect(peak * (kSampleRate / kFftSize), closeTo(1000, 6));

    await worker.dispose();
  });

  test('keeps up across many chunks without dropping frames', () async {
    final worker = await SpectrumIsolate.spawn();
    final received = <Float64List>[];
    final sub = worker.frames.listen(received.add);

    // Ten hops of audio: roughly nine overlapping frames once the first full
    // window is available.
    for (var i = 0; i < 10; i++) {
      worker.feed(_sine(1500, kFftHop));
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(received.length, greaterThanOrEqualTo(8));
    await sub.cancel();
    await worker.dispose();
  });

  test('each frame is a distinct copy, not a shared buffer', () async {
    // The analyzer reuses one scratch array; if it crossed the port by
    // reference every stored frame would end up identical.
    final worker = await SpectrumIsolate.spawn();
    final received = <Float64List>[];
    final sub = worker.frames.listen(received.add);

    worker.feed(_sine(500, kFftSize * 2));
    worker.feed(_sine(2500, kFftSize * 2));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(received.length, greaterThanOrEqualTo(2));
    expect(
      identical(received.first, received.last),
      isFalse,
      reason: 'frames must not alias one another',
    );
    expect(received.first, isNot(received.last));

    await sub.cancel();
    await worker.dispose();
  });

  test('honours a custom configuration', () async {
    final worker = await SpectrumIsolate.spawn(displayMaxHz: 1500);
    final first = worker.frames.first;
    worker.feed(_sine(1000, kFftSize * 2));
    final frame = await first.timeout(const Duration(seconds: 5));
    expect(frame.length, lessThan(513));
    await worker.dispose();
  });

  test('dispose is idempotent and feeding afterwards is a no-op', () async {
    final worker = await SpectrumIsolate.spawn();
    await worker.dispose();
    await worker.dispose();
    worker.feed(_sine(1000, kFftSize));
  });
}
