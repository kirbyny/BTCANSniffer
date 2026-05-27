import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as fbc;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models.dart';
import 'transport.dart';

class ScanPick {
  const ScanPick({
    required this.device,
    required this.protocol,
    required this.sendProbe,
  });

  final DiscoveredDevice device;
  final CanProtocol protocol;
  final bool sendProbe;
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    this.initialProtocol,
    this.initialSendProbe = true,
  });

  final CanProtocol? initialProtocol;
  final bool initialSendProbe;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final Map<String, DiscoveredDevice> _devices = {};
  StreamSubscription<List<ScanResult>>? _bleSub;
  StreamSubscription<fbc.BluetoothDevice>? _classicSub;
  final fbc.FlutterBlueClassic _classic = fbc.FlutterBlueClassic(usesFineLocation: true);

  bool _isScanning = false;
  String _statusMsg = '';
  bool _onlyKnown = true;
  bool _permsRequested = false;

  late CanProtocol _protocol = widget.initialProtocol ?? CanProtocol.presets.first;
  late bool _sendProbe = widget.initialSendProbe;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _classicSub?.cancel();
    FlutterBluePlus.stopScan();
    _classic.stopScan();
    super.dispose();
  }

  Future<void> _start() async {
    await _ensurePermissions();
    await _startScan();
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid || _permsRequested) {
      return;
    }
    _permsRequested = true;
    final result = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final denied = result.entries.where((e) => !e.value.isGranted).toList();
    if (denied.isNotEmpty && mounted) {
      setState(() => _statusMsg = 'Some Bluetooth permissions were denied. Scanning may fail.');
      if (denied.any((e) => e.value.isPermanentlyDenied)) {
        await openAppSettings();
      }
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) {
      return;
    }
    setState(() {
      _isScanning = true;
      _statusMsg = 'Scanning...';
      _devices.clear();
    });

    await _loadBondedClassicDevices();
    await _startBleScan();
    if (Platform.isAndroid) {
      await _startClassicDiscovery();
    }

    // Mirror the BLE scan timeout so the spinner clears at the same time.
    await Future<void>.delayed(const Duration(seconds: 12));

    if (Platform.isAndroid) {
      try {
        _classic.stopScan();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _isScanning = false;
        _statusMsg = _devices.isEmpty
            ? 'No devices found. Make sure the VLinker is powered and, for Classic models, paired in Android Bluetooth settings.'
            : 'Found ${_devices.length} device${_devices.length == 1 ? '' : 's'}.';
      });
    }
  }

  Future<void> _loadBondedClassicDevices() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final bonded = await _classic.bondedDevices ?? const [];
      for (final d in bonded) {
        final name = d.name ?? '';
        if (_onlyKnown && !isLikelyVlinker(name)) {
          continue;
        }
        _devices['spp:${d.address}'] = SppDiscoveredDevice(d, bonded: true);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // Older devices / missing permissions just yield no bonded results.
    }
  }

  Future<void> _startBleScan() async {
    await FlutterBluePlus.stopScan();
    await _bleSub?.cancel();
    _bleSub = FlutterBluePlus.scanResults.listen((results) {
      var dirty = false;
      for (final r in results) {
        final name = r.device.platformName;
        if (name.isEmpty) {
          continue;
        }
        if (_onlyKnown && !isLikelyVlinker(name)) {
          continue;
        }
        _devices['ble:${r.device.remoteId.str}'] = BleDiscoveredDevice(r.device, r.rssi);
        dirty = true;
      }
      if (dirty && mounted) {
        setState(() {});
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      if (mounted) {
        setState(() => _statusMsg = 'BLE scan failed: $e');
      }
    }
  }

  Future<void> _startClassicDiscovery() async {
    await _classicSub?.cancel();
    _classicSub = _classic.scanResults.listen((d) {
      final name = d.name ?? '';
      if (name.isEmpty) {
        return;
      }
      if (_onlyKnown && !isLikelyVlinker(name)) {
        return;
      }
      _devices['spp:${d.address}'] = SppDiscoveredDevice(d);
      if (mounted) setState(() {});
    });
    try {
      _classic.startScan();
    } catch (_) {
      // Discovery is best-effort; bonded list is still usable.
    }
  }

  Widget _settingsCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Session settings',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
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
              onChanged: (p) => p == null ? null : setState(() => _protocol = p),
            ),
            const SizedBox(height: 4),
            Text(
              _protocol.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Switch.adaptive(
                  value: _sendProbe,
                  onChanged: (v) => setState(() => _sendProbe = v),
                ),
                Expanded(
                  child: Text(
                    'Send 0100 probe to activate bus (required on most cars)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _pick(DiscoveredDevice d) {
    Navigator.of(context).pop(ScanPick(
      device: d,
      protocol: _protocol,
      sendProbe: _sendProbe,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _devices.values.toList()
      ..sort((a, b) {
        // Group BLE first (modern), then SPP. Within BLE, strongest signal first.
        if (a.isBle != b.isBle) {
          return a.isBle ? -1 : 1;
        }
        if (a is BleDiscoveredDevice && b is BleDiscoveredDevice) {
          return b.rssi.compareTo(a.rssi);
        }
        return a.name.compareTo(b.name);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select VLinker'),
        actions: [
          IconButton(
            onPressed: _isScanning ? null : _startScan,
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _settingsCard(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                Expanded(child: Text(_statusMsg)),
                const Text('Show all'),
                Switch(
                  value: !_onlyKnown,
                  onChanged: (v) => setState(() => _onlyKnown = !v),
                ),
              ],
            ),
          ),
          if (_isScanning) const LinearProgressIndicator(),
          Expanded(
            child: sorted.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _isScanning
                            ? 'Scanning for nearby Bluetooth devices...'
                            : 'Tap the refresh icon to scan again. Classic SPP adapters must be paired in Android Bluetooth settings first.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: sorted.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _DeviceTile(
                      device: sorted[i],
                      onTap: () => _pick(sorted[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onTap});

  final DiscoveredDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final likely = isLikelyVlinker(device.name);
    final iconColor = likely ? Theme.of(context).colorScheme.primary : null;

    String subtitle;
    if (device is BleDiscoveredDevice) {
      subtitle = 'BLE  ·  ${device.address}  ·  RSSI ${(device as BleDiscoveredDevice).rssi}';
    } else {
      final s = device as SppDiscoveredDevice;
      subtitle = 'Classic SPP  ·  ${device.address}${s.bonded ? '  ·  paired' : ''}';
    }

    return ListTile(
      leading: Icon(
        likely ? Icons.directions_car : (device.isBle ? Icons.bluetooth : Icons.bluetooth_audio),
        color: iconColor,
      ),
      title: Text(device.name),
      subtitle: Text(subtitle),
      trailing: device.isBle
          ? const _Badge(label: 'BLE')
          : const _Badge(label: 'SPP', color: Color(0xFF1A8A5A)),
      onTap: onTap,
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: c)),
    );
  }
}
