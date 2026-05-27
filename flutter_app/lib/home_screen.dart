import 'dart:async';

import 'package:flutter/material.dart';

import 'bit_explorer_screen.dart';
import 'bit_matrix_view.dart';
import 'ble_transport.dart';
import 'capture_log.dart';
import 'log_browser_screen.dart';
import 'models.dart';
import 'scan_screen.dart';
import 'sniffer_log_screen.dart';
import 'spp_transport.dart';
import 'transport.dart';
import 'vlinker.dart';

enum _ViewMode { tiles, matrix }

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
  final Map<int, BitTrace> _tracesById = {};
  Timer? _matrixTicker;

  String _status = 'Disconnected';
  VlinkerState _state = VlinkerState.disconnected;
  CanProtocol _protocol = CanProtocol.presets.first;
  bool _sendProbe = true;
  _ViewMode _viewMode = _ViewMode.tiles;

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
    // The matrix view's rolling window has to advance even with no new
    // frames; tick all known traces at ~10 fps so they prune + notify.
    _matrixTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      for (final t in _tracesById.values) {
        t.tick();
      }
    });
  }

  @override
  void dispose() {
    _redrawTimer?.cancel();
    _matrixTicker?.cancel();
    _frameSub?.cancel();
    _statusSub?.cancel();
    _stateSub?.cancel();
    _rawSub?.cancel();
    for (final t in _tracesById.values) {
      t.dispose();
    }
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

    // Feed the shared bit-trace map that powers the matrix view and any
    // open bit-explorer screens.
    final trace = _tracesById.putIfAbsent(
      frame.id,
      () => BitTrace(frame.id, frame.dlc),
    );
    trace.addFrame(frame);

    _dirty = true;
  }

  Future<void> _scanAndConnect() async {
    final result = await Navigator.of(context).push<ScanPick>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          initialProtocol: _protocol,
          initialSendProbe: _sendProbe,
        ),
      ),
    );
    if (result == null) {
      return;
    }
    setState(() {
      _protocol = result.protocol;
      _sendProbe = result.sendProbe;
    });
    // Apply settings before connecting so the ELM init sequence uses the
    // chosen protocol (setProtocol is a no-op on transport when not yet open).
    _link.sendActivationProbe = result.sendProbe;
    await _link.setProtocol(result.protocol);

    final transport = switch (result.device) {
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
    for (final t in _tracesById.values) {
      t.dispose();
    }
    _tracesById.clear();
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
    for (final t in _tracesById.values) {
      t.dispose();
    }
    _tracesById.clear();
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
            tooltip: 'Sniffer log',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SnifferLogScreen()),
            ),
            icon: const Icon(Icons.list_alt),
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
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
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
                    const Spacer(),
                    Text(
                      _protocol.label,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          _transportRow(canMonitor: canMonitor, isMonitoring: isMonitoring, connected: connected),
          if (_showDiagnostics) _buildDiagnostics(),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        connected
                            ? 'No frames yet. Tap ▶ to start monitoring.'
                            : 'Tap the Bluetooth icon to scan for a VLinker MC adapter.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                : _viewMode == _ViewMode.matrix
                    ? BitMatrixView(
                        tracesById: _tracesById,
                        windowMs: BitTrace.windowMs,
                      )
                    : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return ListTile(
                        dense: true,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BitExplorerScreen(
                              link: _link,
                              canId: row.id,
                              canIdHex: row.idHex,
                              dlc: row.dlc,
                              existingTrace: _tracesById[row.id],
                            ),
                          ),
                        ),
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
          const Divider(height: 1),
          _viewToggleBar(),
        ],
      ),
    );
  }

  Widget _transportRow({
    required bool canMonitor,
    required bool isMonitoring,
    required bool connected,
  }) {
    final recording = _activeCapture != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _TransportButton(
            tooltip: isMonitoring ? 'Pause' : 'Start Monitor',
            onPressed: canMonitor ? _toggleMonitor : null,
            icon: isMonitoring ? Icons.pause : Icons.play_arrow,
            iconColor: canMonitor
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).disabledColor,
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TransportButton(
                tooltip: recording ? 'Stop recording' : 'Record to log',
                onPressed: connected ? _toggleCapture : null,
                icon: Icons.fiber_manual_record,
                iconColor: recording
                    ? Colors.red.shade600
                    : (connected ? Colors.black87 : Theme.of(context).disabledColor),
              ),
              if (recording)
                Text(
                  '$_capturedThisSession',
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
            ],
          ),
          _TransportButton(
            tooltip: 'Clear view',
            onPressed: _rowsById.isEmpty ? null : _clearLiveView,
            icon: Icons.stop,
            iconColor: _rowsById.isEmpty
                ? Theme.of(context).disabledColor
                : Colors.black87,
          ),
        ],
      ),
    );
  }

  Widget _viewToggleBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SegmentedButton<_ViewMode>(
            segments: const [
              ButtonSegment(
                value: _ViewMode.tiles,
                label: Text('Tiles'),
                icon: Icon(Icons.view_list),
              ),
              ButtonSegment(
                value: _ViewMode.matrix,
                label: Text('Matrix'),
                icon: Icon(Icons.grid_view),
              ),
            ],
            selected: {_viewMode},
            onSelectionChanged: (s) =>
                setState(() => _viewMode = s.first),
          ),
        ],
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    required this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 40,
      padding: const EdgeInsets.all(10),
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, color: onPressed == null ? null : iconColor),
    );
  }
}
