import 'package:needle_cat/src/cat/serial_transport.dart';
import 'package:needle_cat/src/constants.dart';
import 'package:test/test.dart';

/// Builds a port description the way the four real nodes on the dev Mac look.
PortInfo _port(String name, String? product) => describePortForTest(
  name: name,
  vendorId: kSiliconLabsVendorId,
  productId: kCp2105ProductId,
  productName: product,
  manufacturer: 'Silicon Labs',
  serialNumber: '00B61C5C',
);

/// Exactly what `SerialPort.availablePorts` reported on 2026-08-10 with the
/// FT-891 attached and both CP210x drivers active.
List<PortInfo> _realWorldPorts() => markDuplicatesForTest([
  describePortForTest(name: '/dev/cu.wlan-debug'),
  describePortForTest(name: '/dev/cu.Bluetooth-Incoming-Port'),
  _port(
    '/dev/cu.usbserial-00B61C5C0',
    'CP2105 Dual USB to UART Bridge Controller',
  ),
  _port(
    '/dev/cu.usbserial-00B61C5C1',
    'CP2105 Dual USB to UART Bridge Controller',
  ),
  _port(
    '/dev/cu.SLAB_USBtoUART',
    'CP210x USB to UART Bridge Controller (Standard Port)',
  ),
  _port(
    '/dev/cu.SLAB_USBtoUART6',
    'CP210x USB to UART Bridge Controller (Enhanced Port)',
  ),
]);

void main() {
  group('role detection', () {
    test('the Enhanced product string wins outright', () {
      final p = _port(
        '/dev/cu.SLAB_USBtoUART6',
        'CP210x USB to UART Bridge Controller (Enhanced Port)',
      );
      expect(p.role, PortRole.enhanced);
      expect(p.likelyCatPort, isTrue);
    });

    test('the Standard product string is rejected as CAT', () {
      final p = _port(
        '/dev/cu.SLAB_USBtoUART',
        'CP210x USB to UART Bridge Controller (Standard Port)',
      );
      expect(p.role, PortRole.standard);
      expect(p.likelyCatPort, isFalse);
    });

    test('a numeric guess would pick the wrong Silicon Labs node', () {
      // SLAB_USBtoUART6 is Enhanced while plain SLAB_USBtoUART is Standard, so
      // "lowest device number" selects the PTT port. This is the trap the
      // handoff spec warns about; assert we do not fall into it.
      final ports = _realWorldPorts();
      final slab = ports.where((p) => p.name.contains('SLAB')).toList();
      final enhanced = slab.firstWhere((p) => p.role == PortRole.enhanced);
      expect(enhanced.name, endsWith('SLAB_USBtoUART6'));
    });

    test('interface 0 is Enhanced when the product string is silent', () {
      final p = _port(
        '/dev/cu.usbserial-00B61C5C0',
        'CP2105 Dual USB to UART Bridge Controller',
      );
      expect(p.role, PortRole.enhanced);
      expect(p.likelyCatPort, isTrue);
      expect(p.reason, contains('interface 0'));
    });

    test('interface 1 is Standard when the product string is silent', () {
      final p = _port(
        '/dev/cu.usbserial-00B61C5C1',
        'CP2105 Dual USB to UART Bridge Controller',
      );
      expect(p.role, PortRole.standard);
      expect(p.likelyCatPort, isFalse);
    });

    test('a non-bridge port is not a candidate', () {
      final p = describePortForTest(name: '/dev/cu.Bluetooth-Incoming-Port');
      expect(p.role, PortRole.unknown);
      expect(p.likelyCatPort, isFalse);
    });

    test('a CP2105 with no usable signal defers to probing', () {
      final p = describePortForTest(
        name: '/dev/ttyUSB0',
        vendorId: kSiliconLabsVendorId,
        productId: kCp2105ProductId,
        productName: 'CP2105 Dual USB to UART Bridge Controller',
        serialNumber: '00B61C5C',
      );
      expect(p.role, PortRole.unknown);
      expect(p.reason, contains('--probe'));
    });
  });

  group('duplicate driver nodes', () {
    test('four nodes collapse to two real UARTs', () {
      final ports = _realWorldPorts();
      final live = ports.where((p) => !p.isDuplicate && p.serialNumber != null);
      expect(live, hasLength(2));
    });

    test('exactly one non-duplicate port is flagged as CAT', () {
      final flagged = _realWorldPorts()
          .where((p) => p.likelyCatPort && !p.isDuplicate)
          .toList();
      expect(flagged, hasLength(1));
      expect(flagged.single.name, '/dev/cu.usbserial-00B61C5C0');
    });

    test('the Apple-published node is preferred over the Silicon Labs one', () {
      final ghost = _realWorldPorts().firstWhere(
        (p) => p.name.endsWith('SLAB_USBtoUART6'),
      );
      expect(ghost.isDuplicate, isTrue);
      expect(ghost.duplicateOf, '/dev/cu.usbserial-00B61C5C0');
    });

    test('a duplicate is never itself flagged as the CAT port', () {
      for (final p in _realWorldPorts().where((p) => p.isDuplicate)) {
        expect(p.likelyCatPort, isFalse, reason: p.name);
      }
    });

    test('ports without a serial number are left alone', () {
      final ports = _realWorldPorts();
      final wlan = ports.firstWhere((p) => p.name.contains('wlan-debug'));
      expect(wlan.isDuplicate, isFalse);
    });

    test('a single CP2105 with only one driver has no duplicates', () {
      final ports = markDuplicatesForTest([
        _port(
          '/dev/cu.usbserial-00B61C5C0',
          'CP2105 Dual USB to UART Bridge Controller',
        ),
        _port(
          '/dev/cu.usbserial-00B61C5C1',
          'CP2105 Dual USB to UART Bridge Controller',
        ),
      ]);
      expect(ports.where((p) => p.isDuplicate), isEmpty);
    });
  });
}
