import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import 'transport.dart';

/// USB-OTG serial transport for ELM327 USB adapters (FTDI / CP210x / PL2303 /
/// CH340 chipsets). Android-only — iOS doesn't allow third-party USB serial.
///
/// Default 38400 baud. Most ELM327 USB adapters ship at 38400; some clones
/// default to 9600 or 115200. If init never returns, the user should try a
/// different baud rate.
class UsbSerialElmTransport implements ElmTransport {
  UsbSerialElmTransport(this._device, {this.baudRate = 38400});

  final UsbDevice _device;
  final int baudRate;

  UsbPort? _port;
  StreamSubscription<Uint8List>? _inSub;

  final StreamController<List<int>> _incoming = StreamController.broadcast();
  final StreamController<void> _disc = StreamController.broadcast();
  bool _open = false;

  @override
  String get name {
    final p = _device.productName;
    if (p != null && p.isNotEmpty) return p;
    return 'USB ${_hex4(_device.vid ?? 0)}:${_hex4(_device.pid ?? 0)}';
  }

  @override
  bool get isOpen => _open;
  @override
  Stream<List<int>> get incoming => _incoming.stream;
  @override
  Stream<void> get onDisconnected => _disc.stream;

  @override
  Future<void> open() async {
    final p = await _device.create();
    if (p == null) {
      throw StateError('USB: unable to create port (${_device.deviceName})');
    }
    final opened = await p.open();
    if (opened != true) {
      throw StateError('USB: permission denied or device busy');
    }
    await p.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    await p.setDTR(true);
    await p.setRTS(true);
    _port = p;
    _inSub = p.inputStream?.listen(
      _incoming.add,
      onDone: () {
        _open = false;
        if (!_disc.isClosed) _disc.add(null);
      },
      onError: (_) {
        _open = false;
        if (!_disc.isClosed) _disc.add(null);
      },
      cancelOnError: true,
    );
    _open = true;
  }

  @override
  Future<void> send(List<int> bytes) async {
    final p = _port;
    if (p == null) {
      throw StateError('USB transport not open');
    }
    await p.write(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    _open = false;
    await _inSub?.cancel();
    _inSub = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_disc.isClosed) await _disc.close();
  }

  static String _hex4(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(4, '0');
}
