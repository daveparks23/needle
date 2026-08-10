/// Replays a recorded CAT transcript so the whole application — including the
/// scope demo — runs with no radio attached.
library;

import 'dart:async';

import 'transport.dart';

/// One recorded request/response pair.
class _Exchange {
  const _Exchange(this.response, this.gap);

  /// Response payload with the trailing `;` already stripped.
  final String response;

  /// How long the radio took to answer.
  final Duration gap;
}

/// A [CatTransport] backed by a recorded transcript.
///
/// Transcript format, one event per line so it stays diffable and hand-editable:
///
/// ```
/// # needle CAT transcript v1
/// 0 TX FA;
/// 12 RX FA014074000;
/// ```
///
/// The leading integer is milliseconds since the recording opened. Each `TX`
/// is paired with the next `RX`, and the difference becomes the simulated
/// turnaround. Where a command appears several times, its responses are
/// replayed in order and then wrap — that is what makes a repeated `SM0;` poll
/// look alive rather than frozen.
class MockTransport implements CatTransport {
  MockTransport({required String fixture, this.speed = 1.0})
    : _script = _parse(fixture) {
    if (_script.isEmpty) {
      throw ArgumentError.value(
        fixture,
        'fixture',
        'transcript contains no TX/RX exchanges',
      );
    }
  }

  /// Playback rate multiplier. Values above 1 replay faster than recorded.
  final double speed;

  final Map<String, List<_Exchange>> _script;
  final Map<String, int> _cursors = {};
  final List<Timer> _pending = [];

  StreamController<String>? _controller;

  @override
  bool get isOpen => _controller != null;

  @override
  Stream<String> get lines =>
      (_controller ??= StreamController<String>.broadcast()).stream;

  @override
  Future<void> open() async {
    _controller ??= StreamController<String>.broadcast();
  }

  @override
  Future<void> close() async {
    for (final timer in _pending) {
      timer.cancel();
    }
    _pending.clear();
    final controller = _controller;
    _controller = null;
    await controller?.close();
  }

  @override
  void send(String command) {
    final controller = _controller;
    if (controller == null) {
      throw const CatTransportException('transport is not open');
    }

    final exchanges = _script[command];
    // An unrecognised command gets the radio's rejection answer, not silence.
    final exchange = exchanges == null
        ? const _Exchange('?', Duration(milliseconds: 8))
        : exchanges[_advance(command, exchanges.length)];

    final micros = (exchange.gap.inMicroseconds / speed).round();
    late Timer timer;
    timer = Timer(Duration(microseconds: micros), () {
      _pending.remove(timer);
      if (!controller.isClosed) controller.add(exchange.response);
    });
    _pending.add(timer);
  }

  /// Returns the cursor for [command] and advances it, wrapping at [length].
  int _advance(String command, int length) {
    final current = _cursors[command] ?? 0;
    _cursors[command] = (current + 1) % length;
    return current;
  }

  static Map<String, List<_Exchange>> _parse(String fixture) {
    final script = <String, List<_Exchange>>{};
    String? pendingCommand;
    var pendingAt = 0;

    for (final raw in fixture.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final space = line.indexOf(' ');
      if (space < 0) continue;
      final millis = int.tryParse(line.substring(0, space));
      if (millis == null) continue;

      final rest = line.substring(space + 1);
      if (rest.startsWith('TX ')) {
        pendingCommand = rest.substring(3).trim();
        pendingAt = millis;
      } else if (rest.startsWith('RX ') && pendingCommand != null) {
        final payload = rest.substring(3).trim();
        script.putIfAbsent(pendingCommand, () => []).add(
          _Exchange(
            payload.endsWith(';')
                ? payload.substring(0, payload.length - 1)
                : payload,
            Duration(milliseconds: (millis - pendingAt).clamp(0, 5000)),
          ),
        );
        pendingCommand = null;
      }
    }
    return script;
  }
}
