import 'dart:async';

import 'package:flutter/material.dart';

import 'ble_transport.dart';
import 'capture_log.dart';
import 'log_browser_screen.dart';
import 'models.dart';
import 'scan_screen.dart';
import 'spp_transport.dart';
import 'transport.dart';
import 'vlinker.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final VlinkerConnection _link = VlinkerConnection();

  StreamSubscription<CanFrame>? _frameSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<VlinkerState>? _stateSub;
  StreamSubscription<String>? _rawSub;

  final List<String> _recentRaw = [];
  bool _showDiagnostics = false;

  final Map<int, CanRowModel> _rowsById = {};
  String _status = 'Disconnected';
  VlinkerState _state = VlinkerState.disconnected;
  CanProtocol _protocol = CanProtocol.presets.first;

  CaptureLogFile? _activeCapture;
  int _capturedThisSession = 0;

  Timer? _redrawTimer;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _statusSub = _link.statusMessages.listen((m) {
      if (!mounted) return;
      setState(() => _status = m);
    });
    _stateSub = _link.stateChanges.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);
    });
    _frameSub = _link.frames.listen(_onFrame);
    _rawSub = _link.rawLines.listen((line) {
      _recentRaw.add(line);
      while (_recentRaw.length > 30) {
        _recentRaw.removeAt(0);
      }
      _dirty = true;
    });

    // Coalesce UI updates so heavy bus traffic doesn't peg the framework.
    _redrawTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _redrawTimer?.cancel();
    _frameSub?.cancel();
    _statusSub?.cancel();
    _stateSub?.cancel();
    _rawSub?.cancel();
    _activeCapture?.close();
    _link.dispose();
    super.dispose();
  }

  void _onFrame(CanFrame frame) {
    final existing = _rowsById[frame.id];
    if (existing == null) {
      _rowsById[frame.id] = CanRowModel(
        id: frame.id,
        idHex: frame.idHex,
        extended: frame.extended,
        dlc: frame.dlc,
        data: List<int>.from(frame.data),
        changed: {for (var i = 0; i < frame.dlc; i++) i},
        lastTimestampMs: frame.timestampMs,
        count: 1,
      );
    } else {
      final changed = <int>{};
      for (var i = 0; i < frame.dlc && i < existing.data.length; i++) {
        if (existing.data[i] != frame.data[i]) {
          changed.add(i);
        }
      }
      existing.dlc = frame.dlc;
      existing.data = List<int>.from(frame.data);
      existing.changed = changed;
      existing.lastTimestampMs = frame.timestampMs;
      existing.count += 1;
    }

    if (_activeCapture != null) {
      _activeCapture!.writeFrame(frame);
      _capturedThisSession = _activeCapture!.frameCount;
    }
    _dirty = true;
  }

  Future<void> _scanAndConnect() async {
    final picked = await Navigator.of(context).push<DiscoveredDevice>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (picked == null) {
      return;
    }
    final transport = switch (picked) {
      BleDiscoveredDevice(:final device) => BleElmTransport(device),
      SppDiscoveredDevice(:final device) => SppElmTransport(device),
    };
    await _link.connect(transport);
  }

  Future<void> _disconnect() async {
    if (_activeCapture != null) {
      await _stopCapture();
    }
    await _link.disconnect();
    setState(() {
      _rowsById.clear();
    });
  }

  Future<void> _toggleMonitor() async {
    if (_state == VlinkerState.monitoring) {
      await _link.stopMonitor();
    } else {
      await _link.startMonitor();
    }
  }

  Future<void> _setProtocol(CanProtocol p) async {
    setState(() => _protocol = p);
    await _link.setProtocol(p);
  }

  Future<void> _toggleCapture() async {
    if (_activeCapture == null) {
      final label = _link.connectedDeviceName ?? '';
      final f = await CaptureLogFile.open(label: label);
      setState(() {
        _activeCapture = f;
        _capturedThisSession = 0;
        _status = 'Capturing to ${f.fileName}';
      });
    } else {
      await _stopCapture();
    }
  }

  Future<void> _stopCapture() async {
    final cap = _activeCapture;
    if (cap == null) return;
    await cap.close();
    setState(() {
      _activeCapture = null;
      _status = 'Capture saved: ${cap.fileName} (${cap.frameCount} frames)';
    });
  }

  void _clearLiveView() {
    setState(() {
      _rowsById.clear();
    });
  }

  Future<void> _openLogBrowser() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LogBrowserScreen()),
    );
  }

  Widget _buildDiagnostics() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFF5F5F5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Diagnostics  ·  bytes from adapter: ${_link.bytesReceived}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 120,
            child: _recentRaw.isEmpty
                ? const Text(
                    '(no bytes received yet)',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: _recentRaw.length,
                    itemBuilder: (_, i) {
                      final line = _recentRaw[_recentRaw.length - 1 - i];
                      return Text(
                        line,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _byteCell(CanRowModel row, int index) {
    final active = index < row.dlc;
    final changed = row.changed.contains(index);
    final val = row.data[index].toRadixString(16).padLeft(2, '0').toUpperCase();
    return Container(
      width: 32,
      margin: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: !active
            ? Colors.grey.shade200
            : changed
                ? const Color(0xFFFFD166)
                : const Color(0xFFD9F3E7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        active ? val : '--',
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
  }

  String _stateLabel() {
    switch (_state) {
      case VlinkerState.disconnected:
        return 'Disconnected';
      case VlinkerState.connecting:
        return 'Connecting';
      case VlinkerState.initializing:
        return 'Adapter ready';
      case VlinkerState.monitoring:
        return 'Monitoring';
      case VlinkerState.error:
        return 'Error';
    }
  }

  Color _stateColor() {
    switch (_state) {
      case VlinkerState.monitoring:
        return Colors.green;
      case VlinkerState.initializing:
        return Colors.blue;
      case VlinkerState.connecting:
        return Colors.orange;
      case VlinkerState.error:
        return Colors.red;
      case VlinkerState.disconnected:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _state != VlinkerState.disconnected && _state != VlinkerState.error;
    final canMonitor = _state == VlinkerState.initializing || _state == VlinkerState.monitoring;
    final isMonitoring = _state == VlinkerState.monitoring;
    final rows = _rowsById.values.toList()..sort((a, b) => a.id.compareTo(b.id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('BTCAN Viewer'),
        actions: [
          IconButton(
            tooltip: _showDiagnostics ? 'Hide diagnostics' : 'Show diagnostics',
            onPressed: () => setState(() => _showDiagnostics = !_showDiagnostics),
            icon: Icon(_showDiagnostics ? Icons.bug_report : Icons.bug_report_outlined),
          ),
          IconButton(
            tooltip: 'Capture logs',
            onPressed: _openLogBrowser,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: connected ? 'Disconnect' : 'Connect',
            onPressed: connected ? _disconnect : _scanAndConnect,
            icon: Icon(connected ? Icons.bluetooth_disabled : Icons.bluetooth_searching),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: _stateColor(), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(_stateLabel(), style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (_link.connectedDeviceName != null) ...[
                      const SizedBox(width: 8),
                      Flexible(child: Text('· ${_link.connectedDeviceName}', overflow: TextOverflow.ellipsis)),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 10),
                DropdownButtonFormField<CanProtocol>(
                  initialValue: _protocol,
                  decoration: const InputDecoration(
                    labelText: 'CAN format / bitrate',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final p in CanProtocol.presets)
                      DropdownMenuItem(
                        value: p,
                        child: Text(p.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: connected ? (p) => p == null ? null : _setProtocol(p) : null,
                ),
                const SizedBox(height: 4),
                Text(
                  _protocol.description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Row(
                  children: [
                    Switch.adaptive(
                      value: _link.sendActivationProbe,
                      onChanged: (v) => setState(() => _link.sendActivationProbe = v),
                    ),
                    Expanded(
                      child: Text(
                        'Send 0100 probe to activate bus (required on most cars)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: canMonitor ? _toggleMonitor : null,
                      icon: Icon(isMonitoring ? Icons.pause : Icons.play_arrow),
                      label: Text(isMonitoring ? 'Stop Monitor' : 'Start Monitor'),
                    ),
                    OutlinedButton.icon(
                      onPressed: connected ? _toggleCapture : null,
                      icon: Icon(_activeCapture == null ? Icons.fiber_manual_record : Icons.stop_circle_outlined),
                      label: Text(_activeCapture == null ? 'Record to Log' : 'Stop Recording'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _rowsById.isEmpty ? null : _clearLiveView,
                      icon: const Icon(Icons.clear_all),
                      label: const Text('Clear View'),
                    ),
                    if (_activeCapture != null)
                      Chip(
                        avatar: const Icon(Icons.circle, size: 12, color: Colors.red),
                        label: Text('$_capturedThisSession frames'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_showDiagnostics) _buildDiagnostics(),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        connected
                            ? 'No frames yet. Pick a CAN format and tap Start Monitor.'
                            : 'Tap the Bluetooth icon to scan for a VLinker MC adapter.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return ListTile(
                        dense: true,
                        title: Row(
                          children: [
                            SizedBox(
                              width: 80,
                              child: Text(
                                row.idHex,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            SizedBox(width: 42, child: Text('D${row.dlc}')),
                            Expanded(
                              child: Wrap(
                                children: [for (var i = 0; i < 8; i++) _byteCell(row, i)],
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          '${row.extended ? '29-bit · ' : ''}count ${row.count}  ·  last ${row.lastTimestampMs} ms',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
