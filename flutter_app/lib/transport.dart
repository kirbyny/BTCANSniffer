import 'package:flutter_blue_classic/flutter_blue_classic.dart' as fbc;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:usb_serial/usb_serial.dart' as usb;

/// Bytes-in / bytes-out pipe to an ELM327-compatible adapter. The protocol
/// layer in [VlinkerConnection] (see lib/vlinker.dart) is identical regardless
/// of whether bytes arrive over BLE GATT or Classic SPP — only this transport
/// boundary differs.
abstract class ElmTransport {
  String get name;
  bool get isOpen;

  /// Raw bytes received from the adapter, in arrival order.
  Stream<List<int>> get incoming;

  /// Fires (once) when the underlying link drops.
  Stream<void> get onDisconnected;

  /// Establishes the link. Throws on failure.
  Future<void> open();

  /// Writes [bytes] to the adapter. Implementations handle any
  /// transport-specific chunking (e.g. BLE MTU).
  Future<void> send(List<int> bytes);

  /// Tears down the link. Safe to call multiple times.
  Future<void> close();
}

/// A device surfaced by the scan UI. BLE and Classic devices come from
/// different SDKs (`flutter_blue_plus` / `flutter_blue_classic`), so we tag
/// each one and let the caller materialize the appropriate transport.
sealed class DiscoveredDevice {
  String get name;
  String get address;
  bool get isBle;
}

class BleDiscoveredDevice extends DiscoveredDevice {
  BleDiscoveredDevice(this.device, this.rssi);
  final fbp.BluetoothDevice device;
  final int rssi;

  @override
  String get name => device.platformName;
  @override
  String get address => device.remoteId.str;
  @override
  bool get isBle => true;
}

class SppDiscoveredDevice extends DiscoveredDevice {
  SppDiscoveredDevice(this.device, {this.bonded = false});
  final fbc.BluetoothDevice device;
  final bool bonded;

  @override
  String get name => device.name ?? '(unnamed)';
  @override
  String get address => device.address;
  @override
  bool get isBle => false;
}

class WifiDiscoveredDevice extends DiscoveredDevice {
  WifiDiscoveredDevice({
    required this.host,
    required this.port,
    this.label = 'WiFi ELM327',
  });

  final String host;
  final int port;
  final String label;

  @override
  String get name => label;
  @override
  String get address => '$host:$port';
  @override
  bool get isBle => false;
}

class UsbDiscoveredDevice extends DiscoveredDevice {
  UsbDiscoveredDevice(this.device);
  final usb.UsbDevice device;

  @override
  String get name {
    final manuf = device.manufacturerName ?? '';
    final prod = device.productName ?? '';
    final raw = [manuf, prod].where((s) => s.isNotEmpty).join(' ').trim();
    if (raw.isNotEmpty) return raw;
    return 'USB ${_hex4(device.vid ?? 0)}:${_hex4(device.pid ?? 0)}';
  }

  @override
  String get address =>
      '${_hex4(device.vid ?? 0)}:${_hex4(device.pid ?? 0)} dev ${device.deviceId}';
  @override
  bool get isBle => false;

  static String _hex4(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(4, '0');
}

/// Recognized advertised name fragments for VLinker / generic ELM327-over-BT
/// adapters. Case-insensitive substring match.
const List<String> kVlinkerNameHints = [
  'vlinker',
  'vlink',
  'obdii',
  'obd2',
  'obd-ii',
  'elm327',
  'icar',
];

bool isLikelyVlinker(String name) {
  if (name.isEmpty) {
    return false;
  }
  final lower = name.toLowerCase();
  return kVlinkerNameHints.any((h) => lower.contains(h));
}
