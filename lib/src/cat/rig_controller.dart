/// The command queue: one command in flight, ever.
///
/// This is the heart of the project. The FT-891 does not pipeline — sending a
/// second command before the first has answered desyncs the stream, and once
/// desynced every subsequent response is attributed to the wrong request.
/// Everything here exists to enforce that one rule while still keeping the
/// meter responsive.
library;

import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';

import '../constants.dart';
import 'codec.dart';
import 'commands.dart';
import 'rig_state.dart';
import 'transport.dart';

final Logger _log = Logger('needle.rig');

/// Queue priority, highest first.
enum CatPriority {
  /// Operator actions: set frequency, set mode. Always jump the queue.
  user,

  /// Meters, ~10 Hz.
  fast,

  /// `IF;` for frequency, mode and VFO, ~4 Hz.
  medium,

  /// Filter width and the control states, 0.5 Hz.
  slow,
}

class _Pending {
  _Pending(this.command, this.priority) : completer = Completer<String?>();

  final String command;
  final CatPriority priority;
  final Completer<String?> completer;
  int attempts = 0;
}

/// Polls the radio, keeps one command in flight, and emits [RigState].
class RigController {
  RigController(
    this._transport, {
    Duration? commandTimeout,
    Duration? reconnectBackoff,
    Duration? rejectionRecovery,
    Duration? fastPollPeriod,
    Duration? mediumPollPeriod,
    Duration? slowPollPeriod,
  }) : _commandTimeout = commandTimeout ?? kCommandTimeout,
       _reconnectBackoff = reconnectBackoff ?? kReconnectBackoff,
       _rejectionRecovery = rejectionRecovery ?? kRejectionRecovery,
       _fastPollPeriod = fastPollPeriod ?? kFastPollPeriod,
       _mediumPollPeriod = mediumPollPeriod ?? kMediumPollPeriod,
       _slowPollPeriod = slowPollPeriod ?? kSlowPollPeriod;

  final CatTransport _transport;
  final Duration _commandTimeout;
  final Duration _reconnectBackoff;
  final Duration _rejectionRecovery;

  // Injectable so tests can exercise the slow group without waiting seconds
  // for it, and so `scope` can trade poll rate against round-trip budget.
  final Duration _fastPollPeriod;
  final Duration _mediumPollPeriod;
  final Duration _slowPollPeriod;

  final Map<CatPriority, Queue<_Pending>> _queues = {
    for (final p in CatPriority.values) p: Queue<_Pending>(),
  };

  /// Commands already queued or in flight, so a poll group can never stack a
  /// second copy of a request the radio has not answered yet. Without this a
  /// slow radio turns the queue into an unbounded backlog.
  final Set<String> _outstanding = {};

  /// Commands that timed out twice. Kept out of the poll rotation.
  final Set<String> degradedCommands = {};

  final SMeterDebouncer _sMeter = SMeterDebouncer();
  final StreamController<RigState> _states =
      StreamController<RigState>.broadcast();

  StreamSubscription<String>? _lineSub;
  final List<Timer> _pollTimers = [];
  Timer? _timeoutTimer;
  Timer? _quietUntil;

  _Pending? _inFlight;
  DateTime? _sentAt;
  int _consecutiveTimeouts = 0;
  bool _running = false;
  bool _resyncing = false;

  RigState _current = const RigState.initial();

  /// The most recent snapshot.
  RigState get current => _current;

  /// Distinct state snapshots. Repeats are suppressed.
  Stream<RigState> get states => _states.stream;

  /// Round-trip of the last answered command, for `--verbose`.
  Duration? lastRoundTrip;

  /// Opens the transport and starts polling.
  Future<void> start() async {
    if (_running) return;
    _running = true;

    _emit(_current.copyWith(phase: ConnectionPhase.connecting));
    await _transport.open();
    _lineSub = _transport.lines.listen(_onLine);
    _emit(
      _current.copyWith(phase: ConnectionPhase.ready, connected: true),
    );

    _schedulePolls();
    _drain();
  }

  /// Stops polling and closes the transport.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    for (final t in _pollTimers) {
      t.cancel();
    }
    _pollTimers.clear();
    _timeoutTimer?.cancel();
    _quietUntil?.cancel();

    _failAllPending();
    await _lineSub?.cancel();
    _lineSub = null;
    await _transport.close();

    _emit(
      _current.copyWith(
        phase: ConnectionPhase.disconnected,
        connected: false,
      ),
    );
  }

  /// Enqueues [command] and completes with its payload, or null if it was
  /// rejected, timed out, or the controller stopped.
  Future<String?> request(
    String command, {
    CatPriority priority = CatPriority.user,
  }) {
    final pending = _Pending(command, priority);
    _queues[priority]!.add(pending);
    _outstanding.add(command);
    _drain();
    return pending.completer.future;
  }

  /// Sets VFO-A. User priority, so it takes effect immediately.
  Future<void> setFrequency(int hz) => request(setVfoA(hz));

  /// Sets the operating mode.
  Future<void> setMode(RigMode mode) => request(setModeCommand(mode));

  // -------------------------------------------------------------------------
  // Scheduling
  // -------------------------------------------------------------------------

  void _schedulePolls() {
    void group(Duration period, CatPriority priority, List<String> Function() commands) {
      _pollTimers.add(
        Timer.periodic(period, (_) {
          if (!_running) return;
          for (final c in commands()) {
            if (degradedCommands.contains(c)) continue;
            // Never stack a second copy of a command already awaiting an
            // answer; that is how a slow radio becomes an endless backlog.
            if (_outstanding.contains(c)) continue;
            _enqueuePoll(c, priority);
          }
        }),
      );
    }

    // During transmit the meters that matter are the TX ones; during receive
    // it is the S-meter. Polling the wrong one wastes the fast slot.
    group(_fastPollPeriod, CatPriority.fast, () {
      return _current.transmitting
          ? [readMeter(TxMeter.po), readMeter(TxMeter.swr)]
          : [kReadSMeter];
    });

    group(_mediumPollPeriod, CatPriority.medium, () => [kReadInfo, kReadTxState]);

    group(
      _slowPollPeriod,
      CatPriority.slow,
      () => [kReadFilterWidth, kReadMode, kReadNarrow],
    );
  }

  void _enqueuePoll(String command, CatPriority priority) {
    final pending = _Pending(command, priority);
    _queues[priority]!.add(pending);
    _outstanding.add(command);
    // A poll's result is consumed via the state stream, not its future.
    unawaited(pending.completer.future);
    _drain();
  }

  /// Sends the next command, if the radio is free to receive one.
  void _drain() {
    if (!_running || _inFlight != null || _resyncing) return;
    if (_quietUntil != null && _quietUntil!.isActive) return;
    if (!_transport.isOpen) return;

    for (final priority in CatPriority.values) {
      final queue = _queues[priority]!;
      if (queue.isEmpty) continue;

      final pending = queue.removeFirst();
      _inFlight = pending;
      pending.attempts++;
      _sentAt = DateTime.now();

      try {
        _transport.send(pending.command);
      } on CatTransportException catch (e) {
        _log.warning('send failed: ${e.message}');
        _completeInFlight(null);
        return;
      }

      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(_commandTimeout, _onTimeout);
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Responses
  // -------------------------------------------------------------------------

  void _onLine(String line) {
    final response = parseResponse(line);
    if (response == null) {
      _log.fine('unparseable response dropped: "$line"');
      return;
    }

    final pending = _inFlight;
    if (pending == null) {
      // Nothing outstanding: an echo of a command we already gave up on.
      // Dropping it here is what stops one late answer desyncing everything
      // that follows.
      _log.fine('unsolicited response dropped: "$line"');
      return;
    }

    if (response is CatRejected) {
      _log.warning(
        'radio rejected ${pending.command} — going quiet for '
        '${_rejectionRecovery.inMilliseconds}ms',
      );
      // Arm the quiet window BEFORE completing: _completeInFlight drains the
      // queue, and without the timer already set one more command would slip
      // out into the dead window and be silently discarded.
      _goQuiet();
      degradedCommands.add(pending.command);
      _completeInFlight(null);
      return;
    }

    final data = response as CatData;
    // A response whose prefix does not match the command in flight means the
    // stream has slipped. Do not complete the pending command with someone
    // else's answer.
    if (!pending.command.startsWith(data.prefix)) {
      _log.warning(
        'prefix mismatch: sent ${pending.command}, got ${data.prefix} — '
        'dropping',
      );
      return;
    }

    _consecutiveTimeouts = 0;
    lastRoundTrip = _sentAt == null
        ? null
        : DateTime.now().difference(_sentAt!);

    _applyResponse(data);
    _completeInFlight(data.payload);
  }

  void _applyResponse(CatData data) {
    final now = DateTime.now();
    var next = _current;

    switch (data.prefix) {
      case 'IF':
        final report = parseIf(data.payload);
        if (report != null) {
          next = next.copyWith(
            vfoAHz: report.freqHz,
            mode: report.mode,
            vfoUpdated: now,
          );
        }
      case 'FA':
        final hz = parseFrequency(data.payload);
        if (hz != null) next = next.copyWith(vfoAHz: hz, vfoUpdated: now);
      case 'FB':
        final hz = parseFrequency(data.payload);
        if (hz != null) next = next.copyWith(vfoBHz: hz, vfoUpdated: now);
      case 'MD':
        if (data.payload.length >= 2) {
          next = next.copyWith(
            mode: modeFromCode(data.payload[1]),
            vfoUpdated: now,
          );
        }
      case 'SM':
        final raw = parseSMeter(data.payload);
        if (raw != null) {
          final believed = _sMeter.update(raw);
          if (believed != null) {
            next = next.copyWith(sMeterRaw: believed, metersUpdated: now);
          }
        }
      case 'TX':
        final tx = parseTransmitting(data.payload);
        if (tx != null) next = next.copyWith(transmitting: tx);
      case 'SH':
        if (data.payload.length >= 4) {
          final index = int.tryParse(data.payload.substring(2));
          if (index != null) {
            next = next.copyWith(
              filterWidthIndex: index,
              controlsUpdated: now,
            );
          }
        }
      case 'NA':
        if (data.payload.length >= 2) {
          next = next.copyWith(
            narrowEnabled: data.payload[1] == '1',
            controlsUpdated: now,
          );
        }
    }

    _emit(next);
  }

  void _completeInFlight(String? payload) {
    final pending = _inFlight;
    _inFlight = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    if (pending != null) {
      _outstanding.remove(pending.command);
      if (!pending.completer.isCompleted) pending.completer.complete(payload);
    }
    _drain();
  }

  void _onTimeout() {
    final pending = _inFlight;
    if (pending == null) return;

    _consecutiveTimeouts++;
    _log.fine(
      'timeout on ${pending.command} '
      '(attempt ${pending.attempts}, $_consecutiveTimeouts consecutive)',
    );

    if (_consecutiveTimeouts >= kTimeoutsBeforeResync) {
      _inFlight = null;
      _outstanding.remove(pending.command);
      if (!pending.completer.isCompleted) pending.completer.complete(null);
      unawaited(_resync());
      return;
    }

    if (pending.attempts <= kMaxRetriesPerCommand) {
      // Retry by putting it back at the head of its own queue.
      _inFlight = null;
      _queues[pending.priority]!.addFirst(pending);
      _drain();
      return;
    }

    _log.warning('${pending.command} degraded after ${pending.attempts} tries');
    degradedCommands.add(pending.command);
    _completeInFlight(null);
  }

  /// Stops sending for the CAT TOT window after a rejection.
  void _goQuiet() {
    _quietUntil?.cancel();
    _quietUntil = Timer(_rejectionRecovery, () {
      if (_running) _drain();
    });
  }

  Future<void> _resync() async {
    if (_resyncing || !_running) return;
    _resyncing = true;

    _log.warning('$_consecutiveTimeouts consecutive timeouts — resyncing');
    _emit(_current.copyWith(phase: ConnectionPhase.degraded));

    _failAllPending();
    _sMeter.reset();

    try {
      await _transport.close();
    } on Object catch (e) {
      _log.warning('close during resync failed: $e');
    }

    _emit(_current.copyWith(phase: ConnectionPhase.connecting, connected: false));
    await Future<void>.delayed(_reconnectBackoff);
    if (!_running) {
      _resyncing = false;
      return;
    }

    try {
      await _transport.open();
      await _lineSub?.cancel();
      _lineSub = _transport.lines.listen(_onLine);
      _consecutiveTimeouts = 0;
      // A command that only failed because the radio was away deserves
      // another chance; a genuinely unsupported one will degrade again.
      degradedCommands.clear();
      _emit(_current.copyWith(phase: ConnectionPhase.ready, connected: true));
      _log.info('reconnected');
    } on Object catch (e) {
      _log.warning('reopen failed: $e');
      _emit(_current.copyWith(phase: ConnectionPhase.degraded));
    } finally {
      _resyncing = false;
    }

    _drain();
  }

  void _failAllPending() {
    for (final queue in _queues.values) {
      while (queue.isNotEmpty) {
        final p = queue.removeFirst();
        if (!p.completer.isCompleted) p.completer.complete(null);
      }
    }
    final inFlight = _inFlight;
    _inFlight = null;
    if (inFlight != null && !inFlight.completer.isCompleted) {
      inFlight.completer.complete(null);
    }
    _outstanding.clear();
  }

  void _emit(RigState next) {
    if (next == _current) return;
    _current = next;
    if (!_states.isClosed) _states.add(next);
  }
}
