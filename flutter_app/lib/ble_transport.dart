import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'transport.dart';

/// Candidate BLE UUID sets. We try them in order until one is found on the
/// connected device. VLinker hardware revisions vary, and many generic
/// OBD-II BLE dongles also fall into one of these patterns.
class _UuidSet {
  const _UuidSet({
    required this.service,
    required this.notify,
    required this.write,
  });

  final Guid service;
  final Guid notify;
  final Guid? write; // null = same characteristic as notify (HM-10 style)
}

final List<_UuidSet> _knownUuidSets = [
  // Vgate / VLinker MC+ pattern
  _UuidSet(
    service: Guid('0000fff0-0000-1000-8000-00805f9b34fb'),
    notify: Guid('0000fff1-0000-1000-8000-00805f9b34fb'),
    write: Guid('0000fff2-0000-1000-8000-00805f9b34fb'),
  ),
  // HM-10 style (single combined characteristic)
  _UuidSet(
    service: Guid('0000ffe0-0000-1000-8000-00805f9b34fb'),
    notify: Guid('0000ffe1-0000-1000-8000-00805f9b34fb'),
    write: null,
  ),
  // Nordic UART Service
  _UuidSet(
    service: Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e'),
    notify: Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'),
    write: Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'),
  ),
];

class BleElmTransport implements ElmTransport {
  BleElmTransport(this._device);

  final BluetoothDevice _device;
  BluetoothCharacteristic? _writeChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final StreamController<List<int>> _incoming = StreamController.broadcast();
  final StreamController<void> _disc = StreamController.broadcast();
  bool _open = false;

  @override
  String get name => _device.platformName;
  @override
  bool get isOpen => _open;
  @override
  Stream<List<int>> get incoming => _incoming.stream;
  @override
  Stream<void> get onDisconnected => _disc.stream;

  @override
  Future<void> open() async {
    try {
      await _device.connect(timeout: const Duration(seconds: 12));
    } catch (_) {
      try {
        await _device.disconnect();
      } catch (_) {}
      await _device.connect(timeout: const Duration(seconds: 12));
    }

    _connSub = _device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _open = false;
        if (!_disc.isClosed) {
          _disc.add(null);
        }
      }
    });

    final services = await _device.discoverServices();
    BluetoothCharacteristic? notifyChar;
    BluetoothCharacteristic? writeChar;

    for (final uuidSet in _knownUuidSets) {
      for (final svc in services) {
        if (svc.uuid != uuidSet.service) {
          continue;
        }
        for (final chr in svc.characteristics) {
          if (chr.uuid == uuidSet.notify) {
            notifyChar = chr;
          }
          if (uuidSet.write != null && chr.uuid == uuidSet.write) {
            writeChar = chr;
          }
        }
        if (notifyChar != null) {
          writeChar ??= notifyChar; // HM-10 style
          break;
        }
      }
      if (notifyChar != null) {
        break;
      }
    }

    if (notifyChar == null || writeChar == null) {
      await _device.disconnect();
      throw StateError('No known OBD-II BLE service found on ${_device.platformName}');
    }

    await notifyChar.setNotifyValue(true);
    _notifySub = notifyChar.lastValueStream.listen(_incoming.add);
    _writeChar = writeChar;
    _open = true;
  }

  @override
  Future<void> send(List<int> bytes) async {
    final chr = _writeChar;
    if (chr == null) {
      throw StateError('BLE transport not open');
    }
    final preferNoResp = chr.properties.writeWithoutResponse;
    // BLE MTU is typically small; chunk to be safe.
    const chunkSize = 20;
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize) > bytes.length ? bytes.length : (i + chunkSize);
      await chr.write(bytes.sublist(i, end), withoutResponse: preferNoResp);
    }
  }

  @override
  Future<void> close() async {
    _open = false;
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device.disconnect();
    } catch (_) {}
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_disc.isClosed) {
      await _disc.close();
    }
  }
}
