import 'package:needle_cat/src/constants.dart';
import 'package:test/test.dart';

void main() {
  test('display range covers 513 bins at the chosen FFT size', () {
    final binHz = kSampleRate / kFftSize;
    expect((kDisplayMaxHz / binHz).floor() + 1, 513);
  });

  test('the hop gives 50% overlap', () {
    expect(kFftHop * 2, kFftSize);
  });

  test('the target baud is one the radio actually offers', () {
    expect(kSupportedBauds, contains(kDefaultBaud));
  });

  test('the fast poll group is faster than the medium group', () {
    expect(kFastPollPeriod, lessThan(kMediumPollPeriod));
    expect(kMediumPollPeriod, lessThan(kSlowPollPeriod));
  });
}
