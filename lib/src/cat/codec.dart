/// Yaesu CAT wire format: ASCII, semicolon-terminated, strictly
/// request/response.
///
/// Nothing in this file does I/O — it is pure so the whole protocol surface is
/// testable without a radio.
library;

import 'package:meta/meta.dart';

import 'commands.dart';

/// Accumulates bytes from a serial port and splits them into CAT lines.
///
/// Serial data arrives in arbitrary chunks: one read is not one response, and
/// one read may hold several. Framing on `;` rather than on read boundaries is
/// what keeps the request/response loop in sync.
class CatFramer {
  /// Bytes retained while waiting for a terminator.
  ///
  /// A wrong-baud or disconnected port can emit unbounded data with no `;` in
  /// it. Cap the buffer so a stuck link degrades instead of exhausting memory.
  static const int maxBufferedBytes = 4096;

  static const int _semicolon = 0x3B;
  static const int _printableLow = 0x20;
  static const int _printableHigh = 0x7E;

  final List<int> _buf = [];
  final List<String> _lines = [];

  /// Bytes currently held awaiting a terminator. Exposed for tests.
  int get bufferedBytes => _buf.length;

  /// Feeds a chunk straight from the transport.
  void add(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == _semicolon) {
        _lines.add(String.fromCharCodes(_buf));
        _buf.clear();
        continue;
      }
      // Drop anything outside printable ASCII. Framing errors from a baud
      // mismatch show up as high bytes like 0xF8; they must not corrupt the
      // next well-formed response.
      if (byte < _printableLow || byte > _printableHigh) continue;
      if (_buf.length >= maxBufferedBytes) {
        _buf.clear();
      }
      _buf.add(byte);
    }
  }

  /// Returns every complete line received since the last call, and clears them.
  List<String> takeLines() {
    if (_lines.isEmpty) return const [];
    final out = List<String>.from(_lines);
    _lines.clear();
    return out;
  }

  /// Discards all buffered state. Use after a resync.
  void reset() {
    _buf.clear();
    _lines.clear();
  }
}

/// A parsed CAT response line, with the `;` already stripped.
@immutable
sealed class CatResponse {
  const CatResponse();
}

/// A well-formed answer: a two-letter prefix plus its payload.
@immutable
final class CatData extends CatResponse {
  const CatData(this.prefix, this.payload);

  final String prefix;
  final String payload;

  @override
  bool operator ==(Object other) =>
      other is CatData && other.prefix == prefix && other.payload == payload;

  @override
  int get hashCode => Object.hash(prefix, payload);

  @override
  String toString() => 'CatData($prefix, $payload)';
}

/// The radio answered `?`, meaning the command was unrecognised or invalid in
/// the current state. Never retry this blindly.
@immutable
final class CatRejected extends CatResponse {
  const CatRejected();

  @override
  bool operator ==(Object other) => other is CatRejected;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'CatRejected()';
}

/// Parses one framed line. Returns null when the line is not a valid response.
CatResponse? parseResponse(String line) {
  if (line == '?') return const CatRejected();
  if (line.length < 3) return null;
  if (!_isUpperAlpha(line.codeUnitAt(0)) || !_isUpperAlpha(line.codeUnitAt(1))) {
    return null;
  }
  return CatData(line.substring(0, 2), line.substring(2));
}

/// Parses a 9-digit zero-padded frequency field into Hz.
int? parseFrequency(String payload) {
  if (payload.length < 9) return null;
  return _digits(payload.substring(0, 9));
}

/// Parses an `SM` payload (`0` + three digits) into the raw 0-255 reading.
int? parseSMeter(String payload) {
  if (payload.length != 4) return null;
  final value = _digits(payload.substring(1));
  if (value == null || value > 255) return null;
  return value;
}

/// Parses a `TX` payload. P1 is 0 when receiving, 1 when keyed by CAT, and 2
/// when keyed at the radio.
bool? parseTransmitting(String payload) {
  if (payload.isEmpty) return null;
  return switch (payload[0]) {
    '0' => false,
    '1' || '2' => true,
    _ => null,
  };
}

/// The fields of an `IF` answer that this project uses.
@immutable
class IfReport {
  const IfReport({
    required this.memoryChannel,
    required this.freqHz,
    required this.clarifierHz,
    required this.mode,
    required this.onVfo,
  });

  final String memoryChannel;
  final int freqHz;
  final int clarifierHz;
  final RigMode mode;

  /// True when P7 is `0` (VFO); false for memory and PMS modes.
  final bool onVfo;
}

// Field offsets into the 25-character IF payload, from the reference book.
const int _ifPayloadLength = 25;
const int _ifMemoryChannel = 0, _ifMemoryChannelLen = 3;
const int _ifFrequency = 3, _ifFrequencyLen = 9;
const int _ifClarifierSign = 12;
const int _ifClarifier = 13, _ifClarifierLen = 4;
const int _ifMode = 19;
const int _ifVfoOrMemory = 20;

/// Parses the payload of an `IF` answer.
///
/// Note that `IF` carries no TX/RX field on this radio — poll `TX;` for that.
IfReport? parseIf(String payload) {
  if (payload.length != _ifPayloadLength) return null;

  final freq = _digits(
    payload.substring(_ifFrequency, _ifFrequency + _ifFrequencyLen),
  );
  if (freq == null) return null;

  final clarMagnitude = _digits(
    payload.substring(_ifClarifier, _ifClarifier + _ifClarifierLen),
  );
  if (clarMagnitude == null) return null;
  final negative = payload[_ifClarifierSign] == '-';

  return IfReport(
    memoryChannel: payload.substring(
      _ifMemoryChannel,
      _ifMemoryChannel + _ifMemoryChannelLen,
    ),
    freqHz: freq,
    clarifierHz: negative ? -clarMagnitude : clarMagnitude,
    mode: modeFromCode(payload[_ifMode]),
    onVfo: payload[_ifVfoOrMemory] == '0',
  );
}

bool _isUpperAlpha(int codeUnit) => codeUnit >= 0x41 && codeUnit <= 0x5A;

/// Parses an all-digit string, rejecting the `+`/`-` and whitespace that
/// `int.tryParse` would otherwise accept.
int? _digits(String s) {
  if (s.isEmpty) return null;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return null;
  }
  return int.parse(s);
}
