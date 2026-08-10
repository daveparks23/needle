/// Tees CAT traffic to a sink in the transcript format [MockTransport] reads.
///
/// This is how fixtures get made. Build it early — it pays for itself the
/// first time you want to reproduce a glitch that only happens while the
/// operator is spinning the VFO knob.
library;

import 'dart:async';

import 'transport.dart';

/// Header written at the top of every transcript.
const String kTranscriptHeader = '# needle CAT transcript v1';

/// A decorator that forwards everything to [inner] while recording it.
class RecordingTransport implements CatTransport {
  RecordingTransport(this.inner, this.sink);

  final CatTransport inner;

  /// Where the transcript goes. Both `IOSink` and `StringBuffer` fit, so the
  /// same class serves the CLI and the tests.
  final StringSink sink;

  final Stopwatch _since = Stopwatch();
  StreamSubscription<String>? _tee;

  @override
  bool get isOpen => inner.isOpen;

  @override
  Stream<String> get lines => inner.lines;

  @override
  Future<void> open() async {
    await inner.open();
    _since
      ..reset()
      ..start();
    sink.writeln(kTranscriptHeader);
    // Record what the radio said, not what we asked for — a response that
    // never arrives is exactly the case worth capturing.
    _tee = inner.lines.listen((line) {
      sink.writeln('${_since.elapsedMilliseconds} RX $line;');
    });
  }

  @override
  Future<void> close() async {
    await _tee?.cancel();
    _tee = null;
    _since.stop();
    await inner.close();
  }

  @override
  void send(String command) {
    sink.writeln('${_since.elapsedMilliseconds} TX $command');
    inner.send(command);
  }
}
