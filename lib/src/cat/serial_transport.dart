/// Serial [CatTransport] over `package:libserialport`, plus the port discovery
/// that tells an operator which of several look-alike devices is the CAT port.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libserialport/libserialport.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../constants.dart';
import 'codec.dart';
import 'commands.dart';
import 'transport.dart';

final Logger _log = Logger('needle.serial');

/// Which UART of a dual-interface bridge a port corresponds to.
enum PortRole {
  /// CP2105 interface 0 — the CAT port on an FT-891.
  enhanced,

  /// CP2105 interface 1 — PTT/RTS, not CAT.
  standard,

  /// Not a dual-interface bridge, or the role could not be determined.
  unknown,
}

/// What `needle ports` prints for one serial device.
@immutable
class PortInfo {
  const PortInfo({
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.productName,
    required this.manufacturer,
    required this.serialNumber,
    required this.role,
    required this.likelyCatPort,
    required this.reason,
    required this.duplicateOf,
  });

  final String name;
  final int? vendorId;
  final int? productId;
  final String? productName;
  final String? manufacturer;
  final String? serialNumber;
  final PortRole role;
  final bool likelyCatPort;

  /// Why this port was or was not flagged, in the operator's language.
  final String reason;

  /// Set when another node addresses the same physical UART.
  ///
  /// On macOS a single CP2105 can appear four times, because Apple's built-in
  /// CP210x driver and the Silicon Labs DriverKit extension each publish their
  /// own device node for both interfaces.
  final String? duplicateOf;

  bool get isDuplicate => duplicateOf != null;
}

/// Enumerates serial ports and flags the likely CAT port.
///
/// Two independent signals exist, and which one is available depends on the
/// driver that published the node:
///
/// * The Silicon Labs driver spells the role out in the product string
///   (`... (Enhanced Port)` / `... (Standard Port)`).
/// * Apple's built-in driver does not, but encodes the USB interface index as
///   the last character of the device name (`usbserial-00B61C5C0`).
///
/// Neither is "pick the lower-numbered device" — on this hardware the Silicon
/// Labs pair is `SLAB_USBtoUART` (Standard) and `SLAB_USBtoUART6` (Enhanced),
/// so a numeric guess would select the PTT port.
List<PortInfo> discoverPorts() {
  final names = _guardDylib(() => SerialPort.availablePorts);
  final ports = <PortInfo>[];

  for (final name in names) {
    final port = _guardDylib(() => SerialPort(name));
    try {
      ports.add(
        _describe(
          name: name,
          vendorId: port.vendorId,
          productId: port.productId,
          productName: port.productName ?? port.description,
          manufacturer: port.manufacturer,
          serialNumber: port.serialNumber,
        ),
      );
    } finally {
      port.dispose();
    }
  }

  return _markDuplicates(ports);
}

@visibleForTesting
PortInfo describePortForTest({
  required String name,
  int? vendorId,
  int? productId,
  String? productName,
  String? manufacturer,
  String? serialNumber,
}) => _describe(
  name: name,
  vendorId: vendorId,
  productId: productId,
  productName: productName,
  manufacturer: manufacturer,
  serialNumber: serialNumber,
);

@visibleForTesting
List<PortInfo> markDuplicatesForTest(List<PortInfo> ports) =>
    _markDuplicates(ports);

PortInfo _describe({
  required String name,
  required int? vendorId,
  required int? productId,
  required String? productName,
  required String? manufacturer,
  required String? serialNumber,
}) {
  final isCp2105 =
      vendorId == kSiliconLabsVendorId && productId == kCp2105ProductId;
  final haystack = (productName ?? '').toLowerCase();

  if (haystack.contains('enhanced')) {
    return PortInfo(
      name: name,
      vendorId: vendorId,
      productId: productId,
      productName: productName,
      manufacturer: manufacturer,
      serialNumber: serialNumber,
      role: PortRole.enhanced,
      likelyCatPort: true,
      reason: 'USB descriptor says Enhanced Port',
      duplicateOf: null,
    );
  }

  if (haystack.contains('standard')) {
    return PortInfo(
      name: name,
      vendorId: vendorId,
      productId: productId,
      productName: productName,
      manufacturer: manufacturer,
      serialNumber: serialNumber,
      role: PortRole.standard,
      likelyCatPort: false,
      reason: 'USB descriptor says Standard Port (PTT/RTS, not CAT)',
      duplicateOf: null,
    );
  }

  final iface = _interfaceIndexFrom(name, serialNumber);
  if (isCp2105 && iface != null) {
    final enhanced = iface == kEnhancedInterfaceIndex;
    return PortInfo(
      name: name,
      vendorId: vendorId,
      productId: productId,
      productName: productName,
      manufacturer: manufacturer,
      serialNumber: serialNumber,
      role: enhanced ? PortRole.enhanced : PortRole.standard,
      likelyCatPort: enhanced,
      reason: enhanced
          ? 'CP2105 interface $iface = Enhanced'
          : 'CP2105 interface $iface = Standard (PTT/RTS, not CAT)',
      duplicateOf: null,
    );
  }

  return PortInfo(
    name: name,
    vendorId: vendorId,
    productId: productId,
    productName: productName,
    manufacturer: manufacturer,
    serialNumber: serialNumber,
    role: PortRole.unknown,
    likelyCatPort: isCp2105,
    reason: isCp2105
        ? 'CP2105 but role is ambiguous — use --probe'
        : 'not a known CAT bridge',
    duplicateOf: null,
  );
}

/// Extracts the USB interface index Apple appends to `usbserial-<serial><n>`.
int? _interfaceIndexFrom(String name, String? serialNumber) {
  if (serialNumber == null || serialNumber.isEmpty) return null;
  final marker = 'usbserial-$serialNumber';
  final at = name.indexOf(marker);
  if (at < 0) return null;
  final tail = name.substring(at + marker.length);
  if (tail.length != 1) return null;
  return int.tryParse(tail);
}

/// Flags nodes that address the same physical UART.
///
/// Grouped by serial number and resolved role. The Apple-published node wins,
/// because the third-party Silicon Labs extension is the one more likely to be
/// absent on another machine.
List<PortInfo> _markDuplicates(List<PortInfo> ports) {
  final groups = <String, List<PortInfo>>{};
  for (final p in ports) {
    if (p.serialNumber == null || p.role == PortRole.unknown) continue;
    groups.putIfAbsent('${p.serialNumber}/${p.role.name}', () => []).add(p);
  }

  final duplicates = <String, String>{};
  for (final group in groups.values) {
    if (group.length < 2) continue;
    final preferred = group.firstWhere(
      (p) => p.name.contains('usbserial-'),
      orElse: () => group.first,
    );
    for (final p in group) {
      if (p.name != preferred.name) duplicates[p.name] = preferred.name;
    }
  }

  return [
    for (final p in ports)
      if (duplicates.containsKey(p.name))
        PortInfo(
          name: p.name,
          vendorId: p.vendorId,
          productId: p.productId,
          productName: p.productName,
          manufacturer: p.manufacturer,
          serialNumber: p.serialNumber,
          role: p.role,
          likelyCatPort: false,
          reason: 'same UART as ${duplicates[p.name]} (other driver)',
          duplicateOf: duplicates[p.name],
        )
      else
        p,
  ];
}

/// Result of probing a port for a live radio.
@immutable
class ProbeResult {
  const ProbeResult({required this.baud, required this.identifier});

  final int baud;

  /// The `ID` payload, or null when the radio answered something else.
  final String? identifier;

  bool get isFt891 => identifier == kFt891Identifier;
}

/// Opens [portName] at each candidate baud and asks the radio to identify
/// itself, returning the rate that produced a well-formed answer.
///
/// A wrong-baud port is not silent — it returns framing garbage that looks
/// like a live-but-broken link — so sweeping is the only way to tell "wrong
/// rate" from "nothing there".
Future<ProbeResult?> probePort(
  String portName, {
  List<int> bauds = kSupportedBauds,
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  for (final baud in _probeOrder(bauds)) {
    final transport = SerialTransport(portName, baud: baud);
    try {
      await transport.open();
    } on CatTransportException catch (e) {
      _log.fine('probe: cannot open $portName at $baud: ${e.message}');
      continue;
    }

    try {
      // Deliberately no "flush" command here. Sending a bare ';' looks like a
      // tidy way to clear a half-received command, but it is itself invalid,
      // so the radio answers '?;' and then ignores everything for a full
      // kRejectionRecovery — turning a working port into a silent one. A
      // clean open followed straight by ID; succeeds every time.
      final answer = transport.lines.firstWhere(_isIdentificationAnswer);
      transport.send(kReadIdentification);
      final line = await answer.timeout(timeout, onTimeout: () => '');
      if (parseResponse(line) case CatData(prefix: 'ID', :final payload)) {
        return ProbeResult(baud: baud, identifier: payload);
      }
    } on TimeoutException {
      // Fall through to the next rate.
    } finally {
      await transport.close();
      // A failed attempt sent this rate's bytes at whatever rate the radio is
      // actually using, which reads as a malformed command and costs a full
      // CAT TOT before the rig listens again. Wait it out rather than probing
      // the next rate into a radio that is not listening.
      await Future<void>.delayed(kRejectionRecovery);
    }
  }
  return null;
}

/// True only for a well-formed `ID` answer.
///
/// Deliberately strict: at the wrong baud the radio's reply arrives mangled,
/// and a loose predicate would accept noise as proof of life.
bool _isIdentificationAnswer(String line) {
  final response = parseResponse(line);
  return response is CatData && response.prefix == 'ID';
}

/// Tries the configured rate first, then the rest fastest-first.
///
/// Every failed attempt pushes garbage at the radio, so reaching the right
/// answer sooner means less confusion to recover from.
List<int> _probeOrder(List<int> bauds) => [
  if (bauds.contains(kDefaultBaud)) kDefaultBaud,
  ...bauds.where((b) => b != kDefaultBaud).toList().reversed,
];

/// A CAT link over a real serial port.
class SerialTransport implements CatTransport {
  SerialTransport(this.portName, {this.baud = kDefaultBaud});

  final String portName;
  final int baud;

  final CatFramer _framer = CatFramer();

  SerialPort? _port;
  Timer? _pump;
  StreamController<String>? _controller;

  @override
  bool get isOpen => _port != null;

  @override
  Stream<String> get lines =>
      (_controller ??= StreamController<String>.broadcast()).stream;

  @override
  Future<void> open() async {
    if (_port != null) return;

    final port = _guardDylib(() => SerialPort(portName));
    if (!port.openReadWrite()) {
      final err = SerialPort.lastError;
      port.dispose();
      throw CatTransportException(
        'cannot open $portName: ${err?.message ?? 'unknown error'}',
        remedy: 'Check the cable, that no other program holds the port, and '
            'that the radio is powered on.',
      );
    }

    // Two hard-won rules about libserialport 0.3.0+1 on macOS, both found by
    // bisecting a SIGABRT during `needle ports --probe`:
    //
    //  1. Build a FRESH SerialPortConfig for every open. Reusing one instance
    //     across ports makes the second `port.config = ...` fail with
    //     ETIMEDOUT (errno 60).
    //  2. NEVER call SerialPortConfig.dispose(). Disposing the config and then
    //     disposing the port aborts the process. Either dispose alone is safe;
    //     together they are fatal.
    //
    // The cost is one leaked sp_port_config (a few dozen bytes) per open.
    // That is bounded and cheap next to killing the process on every resync.
    port.config = SerialPortConfig()
      ..baudRate = baud
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);

    // Discard anything the OS buffered from a previous session. This is a
    // local buffer flush — it sends nothing, unlike a bare ';' on the wire.
    port.flush();

    _framer.reset();
    _controller ??= StreamController<String>.broadcast();
    _port = port;

    // Own the read loop rather than using SerialPortReader — see
    // kSerialPollInterval for why.
    _pump = Timer.periodic(kSerialPollInterval, (_) => _drain());

    _log.fine('opened $portName at $baud 8N1');
  }

  /// Moves whatever the OS has buffered into the framer.
  void _drain() {
    final port = _port;
    if (port == null) return;

    try {
      final waiting = port.bytesAvailable;
      if (waiting <= 0) return;
      // Default timeout is negative, which is libserialport's non-blocking
      // read. Nothing here may block the event loop.
      _framer.add(port.read(waiting));
    } on SerialPortError catch (e) {
      _log.warning('serial read error on $portName: $e');
      return;
    }

    for (final line in _framer.takeLines()) {
      _log.finest('RX $line;');
      _controller?.add(line);
    }
  }

  @override
  Future<void> close() async {
    // Stop the pump before the port goes away, so nothing can touch a freed
    // sp_port. This ordering is the whole reason for the custom read loop.
    _pump?.cancel();
    _pump = null;

    final port = _port;
    _port = null;
    if (port != null) {
      port.close();
      port.dispose();
    }

    final controller = _controller;
    _controller = null;
    await controller?.close();
  }

  @override
  void send(String command) {
    final port = _port;
    if (port == null) {
      throw const CatTransportException('transport is not open');
    }
    _log.finest('TX $command');
    port.write(Uint8List.fromList(ascii.encode(command)));
  }
}

/// Runs [body], converting a failure to load the native library into an error
/// that tells the operator exactly what to do.
T _guardDylib<T>(T Function() body) {
  try {
    return body();
  } on ArgumentError catch (e) {
    if (!e.toString().contains('serialport')) rethrow;
    throw CatTransportException(
      'could not load the libserialport native library',
      remedy: _dylibRemedy(),
    );
  }
}

String _dylibRemedy() {
  const candidates = [
    '/opt/homebrew/lib/libserialport.dylib',
    '/usr/local/lib/libserialport.dylib',
    '/usr/lib/x86_64-linux-gnu/libserialport.so.0',
    '/usr/lib/aarch64-linux-gnu/libserialport.so.0',
  ];
  final found = candidates.where((p) => File(p).existsSync()).toList();

  if (found.isNotEmpty) {
    // The library is present; Dart just cannot see it. On Apple Silicon,
    // Homebrew installs into /opt/homebrew/lib, which is not on dyld's
    // default search path.
    return 'It is installed at ${found.first}, but the dynamic loader does '
        'not search that directory.\n\n'
        '  export LIBSERIALPORT_PATH=${found.first}\n\n'
        'Add that line to your shell profile to make it permanent.';
  }

  return 'Install it, then retry:\n\n'
      '  brew install libserialport          # macOS\n'
      '  sudo apt install libserialport-dev  # Debian / Raspberry Pi\n\n'
      'If it is installed somewhere unusual, point at it directly:\n\n'
      '  export LIBSERIALPORT_PATH=/path/to/libserialport.dylib';
}
