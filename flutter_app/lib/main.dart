import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const BtCanApp());
}

class BtCanApp extends StatelessWidget {
  const BtCanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BTCAN Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A8A5A)),
      ),
      home: const CanHomePage(),
    );
  }
}

class CanFrame {
  CanFrame({
    required this.timestampMs,
    required this.idHex,
    required this.id,
    required this.dlc,
    required this.data,
  });

  final int timestampMs;
  final String idHex;
  final int id;
  final int dlc;
  final List<int> data;
}

class CanRowModel {
  CanRowModel({
    required this.id,
    required this.idHex,
    required this.dlc,
    required this.data,
    required this.changed,
    required this.lastTimestampMs,
  });

  final int id;
  final String idHex;
  int dlc;
  List<int> data;
  Set<int> changed;
  int lastTimestampMs;
}

class CanHomePage extends StatefulWidget {
  const CanHomePage({super.key});

  @override
  State<CanHomePage> createState() => _CanHomePageState();
}

class _CanHomePageState extends State<CanHomePage> {
  static final Guid serviceGuid = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
  static final Guid txGuid = Guid('0000fff1-0000-1000-8000-00805f9b34fb');
  static final Guid rxGuid = Guid('0000fff2-0000-1000-8000-00805f9b34fb');

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _notifySub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;

  bool _isScanning = false;
  bool _isConnected = false;

  final Map<int, CanRowModel> _rowsById = {};
  final List<CanFrame> _captured = [];

  final TextEditingController _maxCaptureController = TextEditingController();

  bool _captureEnabled = false;
  int? _captureLimit;
  String _status = 'Idle';
  String _bitrateMode = 'AUTO';
  String _byteOrderMode = 'AUTO';

  String _incomingBuffer = '';
  bool _permissionFlowDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureAndroidBlePermissions();
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    _maxCaptureController.dispose();
    _disconnect();
    super.dispose();
  }

  Future<void> _startScan() async {
    await _ensureAndroidBlePermissions();

    if (_isScanning) {
      return;
    }
    setState(() {
      _isScanning = true;
      _status = 'Scanning for BTCAN-SNIFFER...';
    });

    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final result in results) {
        final name = result.device.platformName;
        if (name == 'BTCAN-SNIFFER') {
          await FlutterBluePlus.stopScan();
          await _scanSub?.cancel();
          await _connect(result.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [serviceGuid],
      timeout: const Duration(seconds: 8),
    );

    setState(() {
      _isScanning = false;
      if (!_isConnected) {
        _status = 'Scan finished. If no device found, verify permissions and power on BTCAN-SNIFFER.';
      }
    });
  }

  Future<void> _ensureAndroidBlePermissions() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (_permissionFlowDone) {
      return;
    }
    _permissionFlowDone = true;

    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    final current = await permissions.request();
    final denied = current.entries.where((e) => !e.value.isGranted).map((e) => e.key).toList();

    if (!mounted) {
      return;
    }

    if (denied.isEmpty) {
      setState(() {
        _status = 'Bluetooth permissions granted';
      });
      return;
    }

    final permanentlyDenied = denied.where((p) => current[p]?.isPermanentlyDenied ?? false).toList();

    setState(() {
      _status = permanentlyDenied.isNotEmpty
          ? 'Bluetooth permissions denied permanently. Please enable in Android Settings.'
          : 'Bluetooth permissions denied. Scanning may fail until granted.';
    });

    if (permanentlyDenied.isNotEmpty) {
      await openAppSettings();
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 10));
    } catch (_) {
      await device.disconnect();
      await device.connect(timeout: const Duration(seconds: 10));
    }

    final services = await device.discoverServices();
    BluetoothCharacteristic? tx;
    BluetoothCharacteristic? rx;

    for (final svc in services) {
      if (svc.uuid != serviceGuid) {
        continue;
      }
      for (final chr in svc.characteristics) {
        if (chr.uuid == txGuid) {
          tx = chr;
        }
        if (chr.uuid == rxGuid) {
          rx = chr;
        }
      }
    }

    if (tx == null || rx == null) {
      setState(() {
        _status = 'Connected but BLE characteristics not found';
      });
      return;
    }

    await tx.setNotifyValue(true);
    _notifySub?.cancel();
    _notifySub = tx.lastValueStream.listen(_handleBleChunk);

    _device = device;
    _txChar = tx;
    _rxChar = rx;

    setState(() {
      _isConnected = true;
      _status = 'Connected to ${device.platformName}';
    });

    await _sendCommand('GET STATUS');
  }

  Future<void> _disconnect() async {
    try {
      await _device?.disconnect();
    } catch (_) {
      // Ignore disconnect errors.
    }

    setState(() {
      _isConnected = false;
      _device = null;
      _txChar = null;
      _rxChar = null;
      _status = 'Disconnected';
    });
  }

  Future<void> _sendCommand(String cmd) async {
    final rx = _rxChar;
    if (rx == null) {
      return;
    }
    await rx.write(utf8.encode(cmd), withoutResponse: true);
  }

  void _handleBleChunk(List<int> data) {
    _incomingBuffer += utf8.decode(data, allowMalformed: true);

    while (true) {
      final lineEnd = _incomingBuffer.indexOf('\n');
      if (lineEnd < 0) {
        break;
      }
      final line = _incomingBuffer.substring(0, lineEnd).trim();
      _incomingBuffer = _incomingBuffer.substring(lineEnd + 1);
      if (line.isNotEmpty) {
        _handleLine(line);
      }
    }
  }

  void _handleLine(String line) {
    final parts = line.split(',');
    if (parts.isEmpty) {
      return;
    }

    if (parts.first == 'MSG' && parts.length >= 12) {
      final ts = int.tryParse(parts[1]) ?? 0;
      final idHex = parts[2].toUpperCase();
      final id = int.tryParse(idHex, radix: 16) ?? 0;
      final dlc = int.tryParse(parts[3]) ?? 0;
      final bytes = <int>[];
      for (var i = 0; i < 8; i++) {
        bytes.add(int.tryParse(parts[4 + i], radix: 16) ?? 0);
      }
      final frame = CanFrame(
        timestampMs: ts,
        idHex: idHex,
        id: id,
        dlc: dlc,
        data: bytes,
      );
      _upsertFrame(frame);
      return;
    }

    if (parts.first == 'CFG' && parts.length >= 5) {
      setState(() {
        _status = line;
      });
      return;
    }

    if (parts.first == 'INFO' || parts.first == 'ERR') {
      setState(() {
        _status = line;
      });
    }
  }

  void _upsertFrame(CanFrame frame) {
    final existing = _rowsById[frame.id];

    if (existing == null) {
      _rowsById[frame.id] = CanRowModel(
        id: frame.id,
        idHex: frame.idHex,
        dlc: frame.dlc,
        data: List<int>.from(frame.data),
        changed: {for (var i = 0; i < frame.dlc; i++) i},
        lastTimestampMs: frame.timestampMs,
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
    }

    if (_captureEnabled) {
      if (_captureLimit == null || _captured.length < _captureLimit!) {
        _captured.add(frame);
      }
    }

    setState(() {});
  }

  void _toggleCapture() {
    setState(() {
      _captureEnabled = !_captureEnabled;
      if (!_captureEnabled) {
        _status = 'Capture stopped (${_captured.length} frames)';
      } else {
        _status = 'Capture started';
      }
    });
  }

  void _clearCapture() {
    setState(() {
      _captured.clear();
      _status = 'Capture cleared';
    });
  }

  Future<void> _exportCsv() async {
    if (_captured.isEmpty) {
      setState(() {
        _status = 'No captured frames to export';
      });
      return;
    }

    final sb = StringBuffer();
    sb.writeln('timestamp_ms,id_hex,id_decimal,dlc,data0,data1,data2,data3,data4,data5,data6,data7');
    for (final frame in _captured) {
      sb.writeln([
        frame.timestampMs,
        frame.idHex,
        frame.id,
        frame.dlc,
        ...frame.data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()),
      ].join(','));
    }

    final dir = await getTemporaryDirectory();
    final fileName = 'btcan_capture_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(sb.toString());

    await Share.shareXFiles([XFile(file.path)], text: 'BTCAN capture CSV');

    setState(() {
      _status = 'Exported ${_captured.length} frames to CSV';
    });
  }

  void _applyCaptureLimit() {
    final raw = _maxCaptureController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _captureLimit = null;
        _status = 'Capture limit set to unlimited';
      });
      return;
    }

    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      setState(() {
        _status = 'Invalid capture limit';
      });
      return;
    }

    setState(() {
      _captureLimit = parsed;
      _status = 'Capture limit set to $parsed';
    });
  }

  List<CanRowModel> _sortedRows() {
    final rows = _rowsById.values.toList();
    rows.sort((a, b) => a.id.compareTo(b.id));
    return rows;
  }

  Widget _byteCell(CanRowModel row, int index) {
    final active = index < row.dlc;
    final changed = row.changed.contains(index);
    final val = row.data[index].toRadixString(16).padLeft(2, '0').toUpperCase();

    return Container(
      width: 34,
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

  @override
  Widget build(BuildContext context) {
    final rows = _sortedRows();
    final compactControls = MediaQuery.of(context).size.width < 760;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BTCAN Viewer'),
        actions: [
          IconButton(
            onPressed: _isConnected ? _disconnect : _startScan,
            icon: Icon(_isConnected ? Icons.bluetooth_disabled : Icons.bluetooth_searching),
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
                Text(_status),
                const SizedBox(height: 10),
                if (compactControls)
                  Column(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _bitrateMode,
                        items: const [
                          DropdownMenuItem(value: 'AUTO', child: Text('Bitrate: Auto')),
                          DropdownMenuItem(value: '50000', child: Text('Bitrate: 50 kbps')),
                          DropdownMenuItem(value: '100000', child: Text('Bitrate: 100 kbps')),
                          DropdownMenuItem(value: '125000', child: Text('Bitrate: 125 kbps')),
                          DropdownMenuItem(value: '250000', child: Text('Bitrate: 250 kbps')),
                          DropdownMenuItem(value: '500000', child: Text('Bitrate: 500 kbps')),
                          DropdownMenuItem(value: '800000', child: Text('Bitrate: 800 kbps')),
                          DropdownMenuItem(value: '1000000', child: Text('Bitrate: 1 Mbps')),
                        ],
                        onChanged: (value) async {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _bitrateMode = value;
                          });
                          if (value == 'AUTO') {
                            await _sendCommand('SET BITRATE AUTO');
                          } else {
                            await _sendCommand('SET BITRATE $value');
                          }
                          await _sendCommand('GET STATUS');
                        },
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: _byteOrderMode,
                        items: const [
                          DropdownMenuItem(value: 'AUTO', child: Text('Byte Order: Auto')),
                          DropdownMenuItem(value: 'LE', child: Text('Byte Order: Little-endian')),
                          DropdownMenuItem(value: 'BE', child: Text('Byte Order: Big-endian')),
                        ],
                        onChanged: (value) async {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _byteOrderMode = value;
                          });
                          await _sendCommand('SET BYTEORDER $value');
                          await _sendCommand('GET STATUS');
                        },
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _bitrateMode,
                          items: const [
                            DropdownMenuItem(value: 'AUTO', child: Text('Bitrate: Auto')),
                            DropdownMenuItem(value: '50000', child: Text('Bitrate: 50 kbps')),
                            DropdownMenuItem(value: '100000', child: Text('Bitrate: 100 kbps')),
                            DropdownMenuItem(value: '125000', child: Text('Bitrate: 125 kbps')),
                            DropdownMenuItem(value: '250000', child: Text('Bitrate: 250 kbps')),
                            DropdownMenuItem(value: '500000', child: Text('Bitrate: 500 kbps')),
                            DropdownMenuItem(value: '800000', child: Text('Bitrate: 800 kbps')),
                            DropdownMenuItem(value: '1000000', child: Text('Bitrate: 1 Mbps')),
                          ],
                          onChanged: (value) async {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _bitrateMode = value;
                            });
                            if (value == 'AUTO') {
                              await _sendCommand('SET BITRATE AUTO');
                            } else {
                              await _sendCommand('SET BITRATE $value');
                            }
                            await _sendCommand('GET STATUS');
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _byteOrderMode,
                          items: const [
                            DropdownMenuItem(value: 'AUTO', child: Text('Byte Order: Auto')),
                            DropdownMenuItem(value: 'LE', child: Text('Byte Order: Little-endian')),
                            DropdownMenuItem(value: 'BE', child: Text('Byte Order: Big-endian')),
                          ],
                          onChanged: (value) async {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _byteOrderMode = value;
                            });
                            await _sendCommand('SET BYTEORDER $value');
                            await _sendCommand('GET STATUS');
                          },
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: compactControls ? double.infinity : 340,
                      child: TextField(
                        controller: _maxCaptureController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Capture limit (blank = unlimited)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _applyCaptureLimit,
                      child: const Text('Set'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _toggleCapture,
                      child: Text(_captureEnabled ? 'Stop Capture' : 'Start Capture'),
                    ),
                    ElevatedButton(
                      onPressed: _clearCapture,
                      child: const Text('Clear Capture'),
                    ),
                    ElevatedButton(
                      onPressed: _exportCsv,
                      child: const Text('Export CSV'),
                    ),
                    Text('Captured: ${_captured.length}'),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return ListTile(
                  dense: true,
                  title: Row(
                    children: [
                      SizedBox(
                        width: 70,
                        child: Text(
                          row.idHex,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      SizedBox(
                        width: 45,
                        child: Text('DLC ${row.dlc}'),
                      ),
                      Expanded(
                        child: Wrap(
                          children: [for (var i = 0; i < 8; i++) _byteCell(row, i)],
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text('Last: ${row.lastTimestampMs} ms'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
