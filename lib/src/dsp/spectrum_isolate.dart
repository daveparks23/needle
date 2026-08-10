/// Hosts the FFT in a dedicated isolate.
///
/// The isolate receives raw PCM and sends back **only** the trimmed magnitude
/// array — never the full 4097-bin result and never the audio. That keeps the
/// port traffic to a few kilobytes a second and is the same boundary the
/// Flutter app will use, so nothing here may assume a console or a single
/// process.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../constants.dart';
import 'spectrum.dart';

/// Sent once at startup to configure the worker.
class _Config {
  const _Config({
    required this.reply,
    required this.fftSize,
    required this.hop,
    required this.sampleRate,
    required this.displayMaxHz,
  });

  final SendPort reply;
  final int fftSize;
  final int hop;
  final int sampleRate;
  final double displayMaxHz;
}

/// Tells the worker to flush and exit.
class _Shutdown {
  const _Shutdown();
}

/// A long-lived isolate running the STFT.
///
/// Long-lived rather than `Isolate.run` per frame: at 15 fps the spawn cost
/// would dominate the work. Measure before changing that — the boundary, not
/// the transform, is what costs here.
class SpectrumIsolate {
  SpectrumIsolate._(this._isolate, this._toWorker, this._fromWorker, this._sub);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final StreamSubscription<dynamic> _sub;

  final StreamController<Float64List> _frames =
      StreamController<Float64List>.broadcast();

  bool _disposed = false;

  /// Trimmed magnitude frames in dB.
  Stream<Float64List> get frames => _frames.stream;

  /// Starts a worker and waits for it to report ready.
  static Future<SpectrumIsolate> spawn({
    int fftSize = kFftSize,
    int hop = kFftHop,
    int sampleRate = kSampleRate,
    double displayMaxHz = kDisplayMaxHz,
  }) async {
    final fromWorker = ReceivePort();
    final ready = Completer<SendPort>();

    final isolate = await Isolate.spawn(
      _workerMain,
      _Config(
        reply: fromWorker.sendPort,
        fftSize: fftSize,
        hop: hop,
        sampleRate: sampleRate,
        displayMaxHz: displayMaxHz,
      ),
      debugName: 'needle-spectrum',
    );

    late final SpectrumIsolate host;
    final sub = fromWorker.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is Float64List) {
        host._frames.add(message);
      }
    });

    final toWorker = await ready.future;
    return host = SpectrumIsolate._(isolate, toWorker, fromWorker, sub);
  }

  /// Queues PCM for analysis. Returns immediately.
  void feed(Float64List pcm) {
    if (_disposed) return;
    _toWorker.send(pcm);
  }

  /// Stops the worker and releases the ports.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _toWorker.send(const _Shutdown());
    // Give the worker a moment to flush its tail before killing it.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await _sub.cancel();
    _fromWorker.close();
    _isolate.kill(priority: Isolate.immediate);
    if (!_frames.isClosed) await _frames.close();
  }
}

/// Entry point for the worker isolate.
void _workerMain(_Config config) {
  final commands = ReceivePort();
  config.reply.send(commands.sendPort);

  final analyzer = SpectrumAnalyzer(
    fftSize: config.fftSize,
    hop: config.hop,
    sampleRate: config.sampleRate,
    displayMaxHz: config.displayMaxHz,
  );

  void emit(Float64List frame) {
    // The analyzer reuses its scratch buffer, so copy before handing the frame
    // across the port.
    config.reply.send(Float64List.fromList(frame));
  }

  commands.listen((dynamic message) {
    if (message is Float64List) {
      analyzer.feed(message, emit);
      return;
    }
    if (message is _Shutdown) {
      analyzer.flush(emit);
      commands.close();
    }
  });
}
