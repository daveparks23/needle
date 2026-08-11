import 'package:needle_cat/src/dsp/capture_backend.dart';
import 'package:test/test.dart';

void main() {
  group('command construction', () {
    test('macOS selects an avfoundation audio index', () {
      final argv = const MacOsCaptureBackend().captureCommand('0', 48000);
      expect(argv.first, 'ffmpeg');
      expect(argv, containsAllInOrder(['-f', 'avfoundation']));
      // The leading colon means "no video, audio device 0". Without it
      // ffmpeg reads 0 as a *video* index and captures the webcam.
      expect(argv, containsAllInOrder(['-i', ':0']));
      expect(argv, containsAllInOrder(['-ac', '1']));
      expect(argv, containsAllInOrder(['-f', 's16le']));
      expect(argv.last, '-');
    });

    test('Linux selects an ALSA hw device', () {
      final argv = const LinuxCaptureBackend().captureCommand('hw:1,0', 48000);
      expect(argv.first, 'arecord');
      expect(argv, containsAllInOrder(['-D', 'hw:1,0']));
      expect(argv, containsAllInOrder(['-f', 'S16_LE']));
      expect(argv, containsAllInOrder(['-t', 'raw']));
    });

    test('Windows selects a dshow device by name', () {
      // dshow has no stable index, so the id is the name itself.
      final argv = const WindowsCaptureBackend()
          .captureCommand('Microphone (USB Audio Device)', 48000);
      expect(argv.first, 'ffmpeg');
      expect(argv, containsAllInOrder(['-f', 'dshow']));
      expect(
        argv,
        containsAllInOrder(['-i', 'audio=Microphone (USB Audio Device)']),
      );
    });

    test('every backend honours the requested sample rate', () {
      for (final backend in <CaptureBackend>[
        const MacOsCaptureBackend(),
        const LinuxCaptureBackend(),
        const WindowsCaptureBackend(),
      ]) {
        expect(
          backend.captureCommand('x', 44100).join(' '),
          contains('44100'),
          reason: '$backend ignored the sample rate',
        );
      }
    });

    test('every backend asks for mono raw S16', () {
      for (final backend in <CaptureBackend>[
        const MacOsCaptureBackend(),
        const LinuxCaptureBackend(),
        const WindowsCaptureBackend(),
      ]) {
        final argv = backend.captureCommand('x', 48000).join(' ').toLowerCase();
        expect(argv, contains('s16'), reason: '$backend');
        expect(argv, contains('1'), reason: '$backend needs one channel');
      }
    });
  });

  group('install hints point at the right package manager', () {
    test('each host names a plausible installer', () {
      expect(const MacOsCaptureBackend().installHint, contains('brew'));
      expect(const LinuxCaptureBackend().installHint, contains('apt'));
      expect(const WindowsCaptureBackend().installHint, contains('ffmpeg'));
      expect(
        const WindowsCaptureBackend().installHint,
        isNot(contains('apt')),
        reason: 'Windows was previously told to run "sudo apt install"',
      );
    });
  });

  group('verification honesty', () {
    test('only macOS claims to be verified', () {
      // Nobody has run the Linux or Windows paths. Saying so in the type is
      // better than a comment nobody reads.
      expect(const MacOsCaptureBackend().verified, isTrue);
      expect(const LinuxCaptureBackend().verified, isFalse);
      expect(const WindowsCaptureBackend().verified, isFalse);
    });
  });

  group('Digirig detection', () {
    test('matches the names the codec actually reports', () {
      expect(looksLikeDigirig('USB Audio Device'), isTrue);
      expect(looksLikeDigirig('Microphone (USB Audio Device)'), isTrue);
      expect(looksLikeDigirig('C-Media USB Headphone Set'), isTrue);
      expect(looksLikeDigirig('digirig'), isTrue);
    });

    test('does not match the built-in inputs', () {
      expect(looksLikeDigirig('MacBook Pro Microphone'), isFalse);
      expect(looksLikeDigirig('Pro Tools Aggregate I/O'), isFalse);
      expect(looksLikeDigirig('Microsoft Teams Audio'), isFalse);
    });
  });
}
