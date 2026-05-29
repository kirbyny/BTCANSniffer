import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// TCP-socket transport for WiFi ELM327 dongles (Wifi-OBD2, generic
/// ESP-Link/HM-10-WiFi adapters). Most dongles expose a single TCP listener
/// at `192.168.0.10:35000` once the phone has joined the dongle's SoftAP;
/// the user can override host + port from the scan screen.
///
/// Works on every platform Flutter supports — there's no MFi or USB-OTG
/// restriction on opening outbound TCP sockets.
class WifiElmTransport implements ElmTransport {
  WifiElmTransport({required this.host, required this.port});

  final String host;
  final int port;

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;

  final StreamController<List<int>> _incoming = StreamController.broadcast();
  final StreamController<void> _disc = StreamController.broadcast();
  bool _open = false;

  @override
  String get name => '$host:$port';
  @override
  bool get isOpen => _open;
  @override
  Stream<List<int>> get incoming => _incoming.stream;
  @override
  Stream<void> get onDisconnected => _disc.stream;

  @override
  Future<void> open() async {
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 8),
    );
    // ELM dongles are latency-sensitive; default Nagle would batch our short
    // AT writes into bigger packets and the prompt detector would block.
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _sub = s.listen(
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
    final s = _socket;
    if (s == null) {
      throw StateError('WiFi transport not open');
    }
    s.add(bytes);
    await s.flush();
  }

  @override
  Future<void> close() async {
    _open = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_disc.isClosed) await _disc.close();
  }
}
