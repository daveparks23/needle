/// An immutable snapshot of what the radio is doing.
///
/// No Flutter types, no console assumptions: the Flutter app consumes this
/// class unchanged.
library;

import 'package:meta/meta.dart';

import '../constants.dart';
import 'commands.dart';
import 'filter_widths.dart' as filters;

/// Where the link to the radio currently stands.
enum ConnectionPhase {
  disconnected,
  connecting,

  /// Polling normally.
  ready,

  /// Still connected, but one or more commands are failing.
  degraded,
}

/// Suppresses the bogus zero readings the FT-891 emits from `SM0;` while the
/// VFO knob is turning.
///
/// The fix, per the Yaesu_Web_Control project's changelog, is to debounce
/// **only the zero path**: require [kSMeterZerosBeforeBelieved] consecutive
/// zeros before believing one, while letting any non-zero reading through
/// instantly. Debouncing both directions makes the meter feel laggy;
/// debouncing neither makes it flicker on every knob movement.
class SMeterDebouncer {
  int _zeroRun = 0;
  int? _last;

  /// Feeds a raw 0-255 reading and returns the value that should be believed,
  /// or null if nothing has been believed yet.
  int? update(int raw) {
    if (raw != 0) {
      _zeroRun = 0;
      return _last = raw;
    }
    if (++_zeroRun >= kSMeterZerosBeforeBelieved) {
      return _last = 0;
    }
    return _last;
  }

  /// Forgets the held reading. Use on resync, so a stale level from before a
  /// dropout is not presented as current.
  void reset() {
    _zeroRun = 0;
    _last = null;
  }
}

/// An immutable snapshot of rig state.
///
/// Raw and interpreted values are kept separate: [sMeterRaw] is the 0-255
/// number the radio reported, while [sMeterSUnits] stays null until a
/// calibration table exists. S-meter response on Yaesu rigs is nonlinear and
/// not worth guessing at.
@immutable
class RigState {
  const RigState({
    this.vfoAHz,
    this.vfoBHz,
    this.mode = RigMode.unknown,
    this.transmitting = false,
    this.sMeterRaw,
    this.sMeterSUnits,
    this.filterWidthIndex,
    this.narrowEnabled,
    this.connected = false,
    this.phase = ConnectionPhase.disconnected,
    this.vfoUpdated,
    this.metersUpdated,
    this.controlsUpdated,
  });

  /// Nothing known, nothing connected.
  const RigState.initial() : this();

  final int? vfoAHz;
  final int? vfoBHz;
  final RigMode mode;
  final bool transmitting;

  /// Raw 0-255 S-meter reading, already zero-debounced.
  final int? sMeterRaw;

  /// Calibrated S-units. Null until a calibration table exists.
  final double? sMeterSUnits;

  /// `SH` P3 as the radio reported it: a table index, not a width in Hz.
  /// Kept raw alongside the derived [filterWidthHz] so the interpreted value
  /// never hides what actually came off the wire.
  final int? filterWidthIndex;

  final bool? narrowEnabled;
  final bool connected;
  final ConnectionPhase phase;

  /// Per-group timestamps so a UI can grey out data that has gone stale.
  final DateTime? vfoUpdated;
  final DateTime? metersUpdated;
  final DateTime? controlsUpdated;

  /// Filter bandwidth in Hz, resolved from [filterWidthIndex] against the
  /// current mode and narrow setting.
  ///
  /// Null when the index is unknown, the mode has no filter table (AM/FM), or
  /// that index is not offered for this combination. Derived rather than
  /// stored so it can never disagree with the raw index it came from.
  int? get filterWidthHz {
    final index = filterWidthIndex;
    if (index == null) return null;
    return filters.filterWidthHz(
      mode: mode,
      narrow: narrowEnabled ?? false,
      index: index,
    );
  }

  /// True when [updated] is null or older than [maxAge].
  bool isStale(DateTime? updated, Duration maxAge) {
    if (updated == null) return true;
    return DateTime.now().difference(updated) > maxAge;
  }

  /// Returns a copy with the given fields replaced.
  ///
  /// Passing null leaves a field unchanged — it cannot clear one. That is
  /// deliberate: after a dropout the readings are not wrong, they are *old*,
  /// and [isStale] against the per-group timestamps is how consumers decide to
  /// grey them out. If a future caller genuinely needs to blank the readings,
  /// build a fresh [RigState] rather than adding null sentinels here.
  RigState copyWith({
    int? vfoAHz,
    int? vfoBHz,
    RigMode? mode,
    bool? transmitting,
    int? sMeterRaw,
    double? sMeterSUnits,
    int? filterWidthIndex,
    bool? narrowEnabled,
    bool? connected,
    ConnectionPhase? phase,
    DateTime? vfoUpdated,
    DateTime? metersUpdated,
    DateTime? controlsUpdated,
  }) {
    return RigState(
      vfoAHz: vfoAHz ?? this.vfoAHz,
      vfoBHz: vfoBHz ?? this.vfoBHz,
      mode: mode ?? this.mode,
      transmitting: transmitting ?? this.transmitting,
      sMeterRaw: sMeterRaw ?? this.sMeterRaw,
      sMeterSUnits: sMeterSUnits ?? this.sMeterSUnits,
      filterWidthIndex: filterWidthIndex ?? this.filterWidthIndex,
      narrowEnabled: narrowEnabled ?? this.narrowEnabled,
      connected: connected ?? this.connected,
      phase: phase ?? this.phase,
      vfoUpdated: vfoUpdated ?? this.vfoUpdated,
      metersUpdated: metersUpdated ?? this.metersUpdated,
      controlsUpdated: controlsUpdated ?? this.controlsUpdated,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RigState &&
      other.vfoAHz == vfoAHz &&
      other.vfoBHz == vfoBHz &&
      other.mode == mode &&
      other.transmitting == transmitting &&
      other.sMeterRaw == sMeterRaw &&
      other.sMeterSUnits == sMeterSUnits &&
      other.filterWidthIndex == filterWidthIndex &&
      other.narrowEnabled == narrowEnabled &&
      other.connected == connected &&
      other.phase == phase &&
      other.vfoUpdated == vfoUpdated &&
      other.metersUpdated == metersUpdated &&
      other.controlsUpdated == controlsUpdated;

  @override
  int get hashCode => Object.hash(
    vfoAHz,
    vfoBHz,
    mode,
    transmitting,
    sMeterRaw,
    sMeterSUnits,
    filterWidthIndex,
    narrowEnabled,
    connected,
    phase,
    vfoUpdated,
    metersUpdated,
    controlsUpdated,
  );

  @override
  String toString() =>
      'RigState(vfoA: $vfoAHz, mode: $mode, tx: $transmitting, '
      'sMeter: $sMeterRaw, phase: $phase)';
}
