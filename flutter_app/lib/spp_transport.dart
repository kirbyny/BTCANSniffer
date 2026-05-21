import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_classic/flutter_blue_classic.dart';

import 'transport.dart';

/// Bluetooth Classic SPP (RFCOMM) transport built on `flutter_blue_classic`.
/// Android-only — iOS forbids third-party SPP without MFi certification.
class SppElmTransport implements ElmTransport {
  SppElmTransport(this._device) : _classic = FlutterBlueClassic(usesFineLocation: true);

  final BluetoothDevice _device;
  final FlutterBlueClassic _classic;
  BluetoothConnection? _conn;
  StreamSubscription<List<int>>? _inSub;

  final StreamController<List<int>> _incoming = StreamController.broadcast();
  final StreamController<void> _disc = StreamController.broadcast();
  bool _open = false;

  @override
  String get name => _device.name ?? _device.address;
  @override
  bool get isOpen => _open;
  @override
  Stream<List<int>> get incoming => _incoming.stream;
  @override
  Stream<void> get onDisconnected => _disc.stream;

  @override
  Future<void> open() async {
    final conn = await _classic.connect(_device.address);
    if (conn == null || !conn.isConnected) {
      throw StateError('Failed to open SPP connection to ${_device.address}');
    }
    _conn = conn;
    _open = true;

    // The connection's input stream closes when the link drops.
    _inSub = conn.input?.listen(
      _incoming.add,
      onDone: () {
        _open = false;
        if (!_disc.isClosed) {
          _disc.add(null);
        }
      },
      onError: (_) {
        _open = false;
        if (!_disc.isClosed) {
          _disc.add(null);
        }
      },
      cancelOnError: true,
    );
  }

  @override
  Future<void> send(List<int> bytes) async {
    final conn = _conn;
    if (conn == null || !conn.isConnected) {
      throw StateError('SPP transport not open');
    }
    conn.output.add(Uint8List.fromList(bytes));
    await conn.output.allSent;
  }

  @override
  Future<void> close() async {
    _open = false;
    await _inSub?.cancel();
    _inSub = null;
    try {
      await _conn?.finish();
    } catch (_) {
      try {
        _conn?.close();
      } catch (_) {}
    }
    _conn = null;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_disc.isClosed) {
      await _disc.close();
    }
  }
}
