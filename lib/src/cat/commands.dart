/// FT-891 CAT command definitions.
///
/// Every layout here was read from the Yaesu **FT-891 CAT Operation Reference
/// Book** (`docs/ft891_cat_reference.pdf`, fetched 2026-08-10), not guessed.
/// Confirmed while transcribing:
///
/// * `IF` answer is **28 characters**: `IF` P1(3) P2(9) sign(1) P3(4) P4 P5 P6
///   P7 P8 P9(2) P10 `;` — so the payload between prefix and terminator is 25.
///   It carries **no TX/RX field**; poll `TX;` for that.
/// * `MD` is `MDP1P2;` where P1 is the fixed receiver selector `0`.
/// * `SM` is read-only: `SM0;` answers `SM0` + three digits, 000-255.
/// * `SH` P3 is a **table index**, not a bandwidth in Hz.
/// * `RM` meter indices: 1=S, 3=COMP, 4=ALC, 5=PO, 6=SWR, 7=ID. This resolves
///   the handoff spec's open question about which index maps to which meter.
/// * **There is no `RX` command on this radio.** The command table runs
///   RA, RC, RD, RG, RI, RL, RM, RS, RU — no RX. Un-keying is `TX0;`. Sending
///   `RX;` returns `?;` and leaves the transmitter keyed.
library;

/// Operating mode. Codes are shared between the `MD` P2 field and the `IF` P6
/// field.
enum RigMode {
  lsb('1'),
  usb('2'),
  cw('3'),
  fm('4'),
  am('5'),
  rtty('6'),
  cwReverse('7'),
  data('8'),
  rttyReverse('9'),
  fmNarrow('B'),
  dataReverse('C'),
  amNarrow('D'),
  unknown('');

  const RigMode(this.code);

  /// The single-character CAT code for this mode.
  final String code;
}

/// Maps a CAT mode character to a [RigMode], never throwing.
RigMode modeFromCode(String code) {
  for (final mode in RigMode.values) {
    if (mode != RigMode.unknown && mode.code == code) return mode;
  }
  return RigMode.unknown;
}

/// `RM` meter selection (P1). Only meaningful during transmit.
enum TxMeter {
  /// Whatever the front panel METER button currently shows.
  frontPanel('0'),
  sMeter('1'),
  comp('3'),
  alc('4'),

  /// Power output.
  po('5'),
  swr('6'),

  /// Drain current.
  id('7');

  const TxMeter(this.selector);

  /// The `RM` P1 selector character. Named `selector` rather than `index`
  /// because every Dart enum already declares an `int index`.
  final String selector;
}

// ---------------------------------------------------------------------------
// Read commands. A bare command reads; the same command with parameters sets.
// ---------------------------------------------------------------------------

const String kReadVfoA = 'FA;';
const String kReadVfoB = 'FB;';

/// Cheapest way to get frequency, clarifier, mode and VFO in one round trip.
const String kReadInfo = 'IF;';

const String kReadMode = 'MD0;';
const String kReadSMeter = 'SM0;';
const String kReadTxState = 'TX;';
const String kReadFilterWidth = 'SH0;';
const String kReadNarrow = 'NA0;';
const String kReadNoiseBlanker = 'NB0;';
const String kReadNoiseReduction = 'NR0;';
const String kReadPreamp = 'PA0;';
const String kReadAttenuator = 'RA0;';
const String kReadRfGain = 'RG0;';
const String kReadAfGain = 'AG0;';
const String kReadPowerState = 'PS;';
const String kReadIdentification = 'ID;';
const String kReadAutoInformation = 'AI;';

/// `ID;` answers `ID0650;` on an FT-891. Used to positively identify the CAT
/// port during probing.
const String kFt891Identifier = '0650';

// ---------------------------------------------------------------------------
// Transmit. Guarded — see the safety section of the README.
// ---------------------------------------------------------------------------

/// Keys the transmitter via CAT.
const String kKeyViaCat = 'TX1;';

/// Un-keys the transmitter.
///
/// This is `TX0;` and **not** `RX;`. The FT-891 command set has no `RX`
/// command; sending one returns `?;` and the radio remains keyed.
const String kUnkey = 'TX0;';

// ---------------------------------------------------------------------------
// Set commands.
// ---------------------------------------------------------------------------

/// Builds `FAnnnnnnnnn;` — frequency in Hz, zero-padded to nine digits.
String setVfoA(int hz) => 'FA${_frequencyField(hz)};';

/// Builds `FBnnnnnnnnn;`.
String setVfoB(int hz) => 'FB${_frequencyField(hz)};';

/// Builds `MD0<code>;`.
String setMode(RigMode mode) {
  if (mode == RigMode.unknown) {
    throw ArgumentError.value(mode, 'mode', 'cannot set an unknown mode');
  }
  return 'MD0${mode.code};';
}

/// Builds `RM<n>;` for the given transmit meter.
String readMeter(TxMeter meter) => 'RM${meter.selector};';

/// Builds `AI0;` or `AI1;`.
String setAutoInformation({required bool enabled}) =>
    'AI${enabled ? 1 : 0};';

String _frequencyField(int hz) {
  if (hz < 0 || hz > 999999999) {
    throw ArgumentError.value(hz, 'hz', 'does not fit the 9-digit CAT field');
  }
  return hz.toString().padLeft(9, '0');
}
