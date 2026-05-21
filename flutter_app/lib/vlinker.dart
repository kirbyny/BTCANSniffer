import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'models.dart';
import 'transport.dart';

/// Status of the high-level connection lifecycle.
enum VlinkerState {
  disconnected,
  connecting,
  initializing,
  monitoring,
  error,
}

/// Drives an ELM327-compatible OBD-II adapter (VLinker MC, MC+, etc.) over an
/// [ElmTransport] (BLE or Classic SPP) and parses streamed CAN frames produced
/// by the `ATMA` (monitor all) command.
class VlinkerConnection {
  VlinkerConnection();

  final _frameController = StreamController<CanFrame>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _stateController = StreamController<VlinkerState>.broadcast();
  final _rawLineController = StreamController<String>.broadcast();

  Stream<CanFrame> get frames => _frameController.stream;
  Stream<String> get statusMessages => _statusController.stream;
  Stream<VlinkerState> get stateChanges => _stateController.stream;

  /// Every non-empty line received from the adapter, including ELM control
  /// tokens like `OK`, `>`, `NO DATA`, etc. Useful for the diagnostics panel.
  Stream<String> get rawLines => _rawLineController.stream;

  /// Total raw bytes received from the adapter since the transport opened.
  int bytesReceived = 0;

  /// When true (default), startMonitor sends a single `0100` (request
  /// supported PIDs) before `ATMA`. ELM327 leaves the CAN interface inactive
  /// after `ATSP <n>` — without a probe, ATMA returns nothing. The probe is
  /// a standard OBD-II diagnostic query, not arbitrary frame injection, but
  /// it is technically a transmission. Set to false for strict passive use.
  bool sendActivationProbe = true;

  VlinkerState _state = VlinkerState.disconnected;
  VlinkerState get state => _state;

  ElmTransport? _transport;
  StreamSubscription<List<int>>? _inSub;
  StreamSubscription<void>? _discSub;

  String _rxBuffer = '';
  bool _monitoring = false;
  CanProtocol _currentProtocol = CanProtocol.presets.first;
  CanProtocol get currentProtocol => _currentProtocol;

  // Serializes AT command writes and waits for the '>' prompt.
  Completer<String>? _pendingPrompt;
  final StringBuffer _atResponseBuffer = StringBuffer();

  // While monitoring, surface the first few non-frame lines to the status
  // stream so silent failures (wrong bitrate, BUS BUSY, etc.) become visible.
  int _unparsedReports = 0;

  String? get connectedDeviceName => _transport?.name;

  void _setState(VlinkerState s) {
    _state = s;
    _stateController.add(s);
  }

  void _emitStatus(String msg) {
    _statusController.add(msg);
  }

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

    _emitStatus('Connected. Initializing ELM327...');
    _setState(VlinkerState.initializing);

    try {
      await _initializeElm();
      _emitStatus('Adapter ready. Select a CAN format and tap Start Monitor.');
      _setState(VlinkerState.initializing);
    } catch (e) {
      _emitStatus('ELM327 init failed: $e');
      _setState(VlinkerState.error);
    }
  }

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

  Future<void> _initializeElm() async {
    // Brief reset, then the standard quiet setup. Headers ON so we get CAN IDs;
    // CAN Auto-Format OFF so we receive raw frames rather than ISO-TP messages.
    await _sendAt('ATZ', waitMs: 1500);
    await _sendAt('ATE0'); // echo off
    await _sendAt('ATL0'); // linefeeds off
    await _sendAt('ATS0'); // spaces off (compact)
    await _sendAt('ATH1'); // headers on
    await _sendAt('ATCAF0'); // CAN auto-formatting off (raw)
    await _sendAt('ATAL'); // allow long messages
    await _sendAt('ATSP${_currentProtocol.code}');
  }

  Future<void> setProtocol(CanProtocol protocol) async {
    if (_monitoring) {
      await stopMonitor();
    }
    _currentProtocol = protocol;
    if (_transport == null) {
      return;
    }
    await _sendAt('ATSP${protocol.code}');
    _emitStatus('Protocol set to ${protocol.label}');
  }

  Future<void> startMonitor() async {
    if (_transport == null || _monitoring) {
      return;
    }
    _monitoring = true;
    _unparsedReports = 0;
    _setState(VlinkerState.monitoring);
    if (sendActivationProbe) {
      _emitStatus('Activating bus (0100 probe)...');
      try {
        await _sendAt('0100', waitMs: 3000);
      } catch (_) {
        // Probe failed — proceed to ATMA anyway and let the user see what
        // (if anything) comes back.
      }
    }
    _emitStatus('Monitoring CAN bus (${_currentProtocol.label})...');
    await _writeRaw('ATMA\r');
  }

  Future<void> stopMonitor() async {
    if (!_monitoring) {
      return;
    }
    _monitoring = false;
    // Any byte stops monitor mode.
    await _writeRaw('\r');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _setState(VlinkerState.initializing);
    _emitStatus('Monitor stopped.');
  }

  Future<String> _sendAt(String cmd, {int waitMs = 800}) async {
    if (_transport == null) {
      throw StateError('Not connected');
    }
    _pendingPrompt = Completer<String>();
    _atResponseBuffer.clear();
    await _writeRaw('$cmd\r');
    try {
      return await _pendingPrompt!.future.timeout(Duration(milliseconds: waitMs * 3));
    } on TimeoutException {
      return _atResponseBuffer.toString();
    } finally {
      _pendingPrompt = null;
    }
  }

  Future<void> _writeRaw(String s) async {
    await _transport?.send(utf8.encode(s));
  }

  void _onIncomingBytes(List<int> bytes) {
    bytesReceived += bytes.length;
    // ELM327 line endings are \r; the prompt is '>'. Treat both as line breaks
    // for frame parsing, and use '>' to satisfy pending AT command waits.
    final chunk = utf8.decode(bytes, allowMalformed: true);
    developer.log('rx ${bytes.length}B: ${chunk.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}', name: 'btcan');
    _rxBuffer += chunk;

    if (_pendingPrompt != null) {
      _atResponseBuffer.write(chunk);
      final promptIdx = _atResponseBuffer.toString().indexOf('>');
      if (promptIdx >= 0) {
        final response = _atResponseBuffer.toString().substring(0, promptIdx);
        final completer = _pendingPrompt;
        _pendingPrompt = null;
        if (completer != null && !completer.isCompleted) {
          completer.complete(response);
        }
      }
    }

    while (true) {
      var sep = -1;
      for (var i = 0; i < _rxBuffer.length; i++) {
        final c = _rxBuffer.codeUnitAt(i);
        // ELM uses '>' as a prompt without a trailing CR, so treat it as a
        // line separator too. Otherwise a prompt followed by an unsolicited
        // event (e.g. `>SEARCHING...`) reaches the parser as one line.
        if (c == 0x0D || c == 0x0A || c == 0x3E /* '>' */) {
          sep = i;
          break;
        }
      }
      if (sep < 0) {
        break;
      }
      final raw = _rxBuffer.substring(0, sep).trim();
      _rxBuffer = _rxBuffer.substring(sep + 1);
      if (raw.isEmpty) {
        continue;
      }
      _rawLineController.add(raw);
      developer.log('line: $raw', name: 'btcan');
      if (raw == '>' || raw == 'OK' || raw.startsWith('SEARCHING') || raw.startsWith('STOPPED') ||
          raw.startsWith('NO DATA') || raw.startsWith('BUS ') || raw.startsWith('?') ||
          raw.startsWith('ELM') || raw.startsWith('CAN ERROR') || raw.startsWith('UNABLE') ||
          raw.startsWith('BUFFER FULL') || raw.startsWith('DATA ERROR')) {
        if (raw.startsWith('NO DATA') || raw.startsWith('CAN ERROR') ||
            raw.startsWith('BUS ') || raw.startsWith('UNABLE') ||
            raw.startsWith('BUFFER FULL') || raw.startsWith('DATA ERROR')) {
          _emitStatus('Adapter: $raw');
        }
        continue;
      }
      final frame = _tryParseElmFrame(raw);
      if (frame != null) {
        _frameController.add(frame);
      } else if (_monitoring && _unparsedReports < 5) {
        _unparsedReports++;
        _emitStatus('Adapter sent unparseable line: "$raw"');
      }
    }
  }

  /// Parses a raw ELM327 monitor-mode line into a [CanFrame].
  ///
  /// With ATH1 + ATS0 + ATCAF0 (spaces off) the lines look like one of:
  ///   `7E80241000BE7FB813`  (11-bit ID 0x7E8, then 7 data bytes)
  ///   `18DAF110024100`      (29-bit ID 0x18DAF110, then 3 data bytes)
  CanFrame? _tryParseElmFrame(String raw) {
    var s = raw.replaceAll(' ', '').toUpperCase();
    if (s.isEmpty || s.length < 4) {
      return null;
    }
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final isHex = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46);
      if (!isHex) {
        return null;
      }
    }

    // ELM327 prints 3 hex chars for 11-bit IDs and 8 for 29-bit. A few
    // firmwares zero-pad 11-bit to 4 chars; accept that too. Whichever ID
    // width we pick, the *remaining* characters (the data bytes) must be
    // a positive, even number of hex digits.
    final extended = _currentProtocol.code == '7' ||
        _currentProtocol.code == '9' ||
        _currentProtocol.code == 'A';
    final candidateIdLens = extended ? const [8] : const [3, 4];

    int? idHexLen;
    for (final n in candidateIdLens) {
      final remaining = s.length - n;
      if (remaining >= 2 && remaining.isEven) {
        idHexLen = n;
        break;
      }
    }
    if (idHexLen == null) {
      return null;
    }

    final idHex = s.substring(0, idHexLen);
    final id = int.tryParse(idHex, radix: 16);
    if (id == null) {
      return null;
    }
    final dataHex = s.substring(idHexLen);
    final data = <int>[];
    for (var i = 0; i + 1 < dataHex.length && data.length < 8; i += 2) {
      final b = int.tryParse(dataHex.substring(i, i + 2), radix: 16);
      if (b == null) {
        return null;
      }
      data.add(b);
    }
    final dlc = data.length;
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

  Future<void> dispose() async {
    await _inSub?.cancel();
    await _discSub?.cancel();
    await _frameController.close();
    await _statusController.close();
    await _stateController.close();
    await _rawLineController.close();
  }
}
