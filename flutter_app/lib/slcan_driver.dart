import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'models.dart';
import 'transport.dart';
import 'vlinker.dart';

/// Lawicel slcan driver. Talks the standard ASCII slcan command set:
///
/// * `C\r` — close the channel
/// * `Sn\r` — set bitrate (S0=10k … S6=500k … S8=1M)
/// * `L\r` — open listen-only (no transmission)
/// * `O\r` — open normal
/// * `t<id3><dlc><data>\r` — RX standard frame (sent by adapter)
/// * `T<id8><dlc><data>\r` — RX extended frame (sent by adapter)
///
/// We never send `O`, `t`, or `T` — only `L` — so this driver is strictly
/// read-only at the bus level. The activation-probe setting is therefore
/// ignored.
///
/// Supports dongles like CANable, Innomaker USB2CAN, CANUSB, and the
/// candleLight firmware running on slcan-compatible builds.
class SlcanDriver implements CanProtocolDriver {
  SlcanDriver();

  final _frameController = StreamController<CanFrame>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _stateController = StreamController<VlinkerState>.broadcast();
  final _rawLineController = StreamController<String>.broadcast();

  @override
  Stream<CanFrame> get frames => _frameController.stream;
  @override
  Stream<String> get statusMessages => _statusController.stream;
  @override
  Stream<VlinkerState> get stateChanges => _stateController.stream;
  @override
  Stream<String> get rawLines => _rawLineController.stream;

  @override
  int bytesReceived = 0;

  /// slcan can't transmit OBD-II probes; the field exists only because the
  /// driver interface does. Reads/writes are no-ops in terms of behavior.
  @override
  bool sendActivationProbe = false;

  VlinkerState _state = VlinkerState.disconnected;
  @override
  VlinkerState get state => _state;

  ElmTransport? _transport;
  StreamSubscription<List<int>>? _inSub;
  StreamSubscription<void>? _discSub;

  String _rxBuffer = '';
  bool _monitoring = false;
  CanProtocol _currentProtocol = CanProtocol.presets.first;
  @override
  CanProtocol get currentProtocol => _currentProtocol;

  @override
  String? get connectedDeviceName => _transport?.name;

  int _unparsedReports = 0;

  void _setState(VlinkerState s) {
    _state = s;
    _stateController.add(s);
  }

  void _emitStatus(String msg) {
    _statusController.add(msg);
    developer.log(msg, name: 'btcan.slcan');
  }

  @override
  Future<void> connect(ElmTransport transport) async {
    _setState(VlinkerState.connecting);
    _emitStatus('Connecting to ${transport.name}...');
    _transport = transport;

    try {
      await transport.open();
    } catch (e) {
      _emitStatus('Connect failed: $e');
      _setState(VlinkerState.error);
      _transport = null;
      return;
    }

    _inSub = transport.incoming.listen(_onIncomingBytes);
    _discSub = transport.onDisconnected.listen((_) => _handleDisconnected());

    _emitStatus('Connected. Initializing slcan...');
    _setState(VlinkerState.initializing);

    try {
      await _sendCommand('C');
      await _sendCommand(_bitrateCommand(_currentProtocol));
      _emitStatus('Adapter ready. Tap Start Monitor to open the channel.');
    } catch (e) {
      _emitStatus('slcan init failed: $e');
      _setState(VlinkerState.error);
    }
  }

  @override
  Future<void> disconnect() async {
    if (_monitoring) {
      try {
        await stopMonitor();
      } catch (_) {}
    }
    try {
      await _transport?.close();
    } catch (_) {}
    _handleDisconnected();
  }

  void _handleDisconnected() {
    _inSub?.cancel();
    _inSub = null;
    _discSub?.cancel();
    _discSub = null;
    _transport = null;
    _monitoring = false;
    _setState(VlinkerState.disconnected);
  }

  @override
  Future<void> setProtocol(CanProtocol protocol) async {
    _currentProtocol = protocol;
    if (_transport == null) return;
    if (_monitoring) {
      await stopMonitor();
    }
    await _sendCommand('C');
    await _sendCommand(_bitrateCommand(protocol));
    _emitStatus('Bitrate set to ${protocol.bitrate ?? "(auto, defaulted to 500k)"} bps');
  }

  @override
  Future<void> startMonitor() async {
    if (_transport == null || _monitoring) return;
    _monitoring = true;
    _unparsedReports = 0;
    _setState(VlinkerState.monitoring);
    _emitStatus('Listening on CAN bus (slcan)...');
    // L = open channel in listen-only mode. Strictly passive — adapter will
    // not ACK or transmit. This is the killer feature vs. ELM327.
    await _sendCommand('L');
  }

  @override
  Future<void> stopMonitor() async {
    if (!_monitoring) return;
    _monitoring = false;
    await _sendCommand('C');
    _setState(VlinkerState.initializing);
    _emitStatus('Channel closed.');
  }

  /// Maps a [CanProtocol] preset to an slcan `Sn` index. slcan has fixed
  /// rate slots; we pick the closest match for the chosen ELM preset. Auto
  /// (`code='0'`) falls back to 500 kbps — slcan can't actually auto-detect.
  String _bitrateCommand(CanProtocol p) {
    final r = p.bitrate;
    final s = switch (r) {
      10000 => 0,
      20000 => 1,
      50000 => 2,
      100000 => 3,
      125000 => 4,
      250000 => 5,
      800000 => 7,
      1000000 => 8,
      _ => 6, // 500k default
    };
    return 'S$s';
  }

  Future<void> _sendCommand(String cmd) async {
    final t = _transport;
    if (t == null) throw StateError('Not connected');
    await t.send(utf8.encode('$cmd\r'));
    // slcan ACKs are essentially a single byte (CR or BEL), arrive quickly,
    // and we tolerate missing them rather than blocking the connect path.
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  void _onIncomingBytes(List<int> bytes) {
    bytesReceived += bytes.length;
    final chunk = utf8.decode(bytes, allowMalformed: true);
    _rxBuffer += chunk;

    while (true) {
      var sep = -1;
      for (var i = 0; i < _rxBuffer.length; i++) {
        final c = _rxBuffer.codeUnitAt(i);
        // slcan terminates every frame with CR; some firmware also emits
        // a literal BEL (0x07) on error.
        if (c == 0x0D || c == 0x0A || c == 0x07) {
          sep = i;
          break;
        }
      }
      if (sep < 0) break;

      final raw = _rxBuffer.substring(0, sep).trim();
      _rxBuffer = _rxBuffer.substring(sep + 1);
      if (raw.isEmpty) continue;

      _rawLineController.add(raw);
      developer.log('line: $raw', name: 'btcan.slcan');

      final frame = _tryParseSlcanFrame(raw);
      if (frame != null) {
        _frameController.add(frame);
      } else if (_monitoring && _unparsedReports < 5) {
        _unparsedReports++;
        _emitStatus('Adapter sent unparseable line: "$raw"');
      }
    }
  }

  /// Parses an slcan ASCII frame:
  ///   `t<id3><dlc><data>`  — standard 11-bit
  ///   `T<id8><dlc><data>`  — extended 29-bit
  /// We ignore RTR (`r`/`R`) frames since they carry no data payload.
  CanFrame? _tryParseSlcanFrame(String raw) {
    if (raw.isEmpty) return null;
    final tag = raw[0];
    final extended = tag == 'T';
    if (tag != 't' && tag != 'T') return null;

    final idLen = extended ? 8 : 3;
    if (raw.length < 1 + idLen + 1) return null;

    final idHex = raw.substring(1, 1 + idLen).toUpperCase();
    final id = int.tryParse(idHex, radix: 16);
    if (id == null) return null;

    final dlcChar = raw[1 + idLen];
    final dlc = int.tryParse(dlcChar, radix: 16);
    if (dlc == null || dlc < 0 || dlc > 8) return null;

    final dataStart = 1 + idLen + 1;
    final dataHex =
        raw.length >= dataStart + dlc * 2 ? raw.substring(dataStart, dataStart + dlc * 2) : '';
    final data = <int>[];
    for (var i = 0; i + 1 < dataHex.length && data.length < 8; i += 2) {
      final b = int.tryParse(dataHex.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      data.add(b);
    }
    while (data.length < 8) {
      data.add(0);
    }

    return CanFrame(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      idHex: idHex,
      id: id,
      extended: extended,
      dlc: dlc,
      data: data,
    );
  }

  @override
  Future<void> dispose() async {
    await _inSub?.cancel();
    await _discSub?.cancel();
    await _frameController.close();
    await _statusController.close();
    await _stateController.close();
    await _rawLineController.close();
  }
}
