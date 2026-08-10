/// The only code path in this project that may key the transmitter.
///
/// Accidental transmit can damage equipment, cause interference, and put the
/// operator in violation of their licence conditions. Every rule here exists
/// because one of those is the failure mode.
///
/// The un-key command is [kUnkey] (`TX0;`), **never** `RX;` — the FT-891 has
/// no `RX` command and answers `?;` to it, which would leave the transmitter
/// keyed in exactly the situations this class exists to cover.
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../constants.dart';
import 'commands.dart';
import 'rig_controller.dart';

final Logger _log = Logger('needle.tx');

/// Raised when transmit is attempted without explicit authorisation.
class TransmitNotAllowed implements Exception {
  const TransmitNotAllowed();

  @override
  String toString() =>
      'Transmit is disabled. Pass --allow-transmit to enable it, and only '
      'into a dummy load or a known-good antenna.';
}

/// Keys the transmitter under a watchdog.
///
/// Guarantees, each covered by a test:
///
/// * Nothing transmits unless [allowTransmit] was explicitly set.
/// * A watchdog un-keys unconditionally after [maxKeyDown], even if the
///   caller never asks it to.
/// * An exception during key-down still un-keys.
/// * [unkey] is safe to call at any time, including when not transmitting.
class TransmitGuard {
  TransmitGuard(
    this._controller, {
    required this.allowTransmit,
    Duration? maxKeyDown,
  }) : maxKeyDown = maxKeyDown ?? kMaxKeyDown;

  final RigController _controller;

  /// Set only by an explicit operator flag.
  final bool allowTransmit;

  /// Hard ceiling on a single transmission.
  final Duration maxKeyDown;

  Timer? _watchdog;
  bool _keyed = false;

  bool get isKeyed => _keyed;

  /// Keys the transmitter, runs [body], and un-keys — whatever happens.
  ///
  /// The watchdog is armed before the key-up command is sent, so a body that
  /// hangs, throws, or is killed still ends in an un-key.
  Future<T> transmit<T>(Future<T> Function() body) async {
    if (!allowTransmit) throw const TransmitNotAllowed();

    _armWatchdog();
    _keyed = true;
    _log.warning('KEYING TRANSMITTER (max ${maxKeyDown.inSeconds}s)');
    await _controller.request(kKeyViaCat);

    try {
      return await body();
    } finally {
      await unkey();
    }
  }

  /// Un-keys unconditionally. Safe to call when not transmitting.
  ///
  /// Never gated on [allowTransmit]: if the radio is somehow keyed, stopping
  /// it must always be permitted.
  Future<void> unkey() async {
    _watchdog?.cancel();
    _watchdog = null;
    if (!_keyed) return;
    _keyed = false;
    _log.warning('un-keying');
    await _controller.request(kUnkey);
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(maxKeyDown, () {
      _log.severe(
        'WATCHDOG: ${maxKeyDown.inSeconds}s key-down limit reached — '
        'un-keying unconditionally',
      );
      unawaited(unkey());
    });
  }

  /// Releases the watchdog without sending anything.
  void dispose() {
    _watchdog?.cancel();
    _watchdog = null;
  }
}
