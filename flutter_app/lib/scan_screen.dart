import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as fbc;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

import 'models.dart';
import 'transport.dart';

class ScanPick {
  const ScanPick({
    required this.device,
    required this.protocol,
    required this.sendProbe,
    required this.family,
  });

  final DiscoveredDevice device;
  final CanProtocol protocol;
  final bool sendProbe;
  final ProtocolFamily family;
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    this.initialProtocol,
    this.initialSendProbe = true,
    this.initialFamily = ProtocolFamily.elm327,
  });

  final CanProtocol? initialProtocol;
  final bool initialSendProbe;
  final ProtocolFamily initialFamily;

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
  late ProtocolFamily _family = widget.initialFamily;

  // Last-used WiFi target persists across re-entries to the scan screen
  // within the app's lifetime.
  static String _lastWifiHost = '192.168.0.10';
  static int _lastWifiPort = 35000;

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
    await _loadUsbDevices();
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

  /// Enumerate attached USB-OTG serial devices. The chips listed in
  /// `usb_device_filter.xml` are nearly always ELM-compatible OBD-II
  /// adapters, so we don't apply the name-hint filter here — if a known
  /// serial chip is attached, the user probably wants to use it.
  Future<void> _loadUsbDevices() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final attached = await usb.UsbSerial.listDevices();
      for (final d in attached) {
        _devices['usb:${d.deviceId}'] = UsbDiscoveredDevice(d);
      }
      if (mounted) setState(() {});
    } catch (_) {
      // No USB host capability / no devices — silent.
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
    final isSlcan = _family == ProtocolFamily.slcan;
    final showProbe = !isSlcan;
    // Auto-detect only applies to ELM327. Filter it out for slcan.
    final formats = isSlcan
        ? CanProtocol.presets.where((p) => p.bitrate != null).toList()
        : CanProtocol.presets;
    // If the user switches to slcan while "Auto" was selected, snap to a
    // sensible default rather than render a broken state.
    if (isSlcan && _protocol.bitrate == null) {
      _protocol = formats.first;
    }
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
            Center(
              child: SegmentedButton<ProtocolFamily>(
                segments: const [
                  ButtonSegment(
                    value: ProtocolFamily.elm327,
                    label: Text('ELM327'),
                    icon: Icon(Icons.directions_car),
                  ),
                  ButtonSegment(
                    value: ProtocolFamily.slcan,
                    label: Text('slcan'),
                    icon: Icon(Icons.memory),
                  ),
                ],
                selected: {_family},
                onSelectionChanged: (s) => setState(() => _family = s.first),
                showSelectedIcon: false,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isSlcan
                  ? 'Raw CAN sniffer over slcan (CANable, Innomaker, etc.) — listen-only, no bus transmissions.'
                  : 'OBD-II adapter speaking ELM327 AT commands (VLinker MC, generic dongles).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<CanProtocol>(
              initialValue: _protocol,
              decoration: const InputDecoration(
                labelText: 'CAN format / bitrate',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final p in formats)
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
            if (showProbe) ...[
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
      family: _family,
    ));
  }

  Future<void> _enterWifi() async {
    final hostCtrl = TextEditingController(text: _lastWifiHost);
    final portCtrl = TextEditingController(text: _lastWifiPort.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WiFi ELM adapter'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connect to a WiFi OBD-II dongle (the phone must be on the '
              'dongle\'s SoftAP — usually OBDII / WiFi-OBD).',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: hostCtrl,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: '192.168.0.10',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portCtrl,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '35000',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    final host = hostCtrl.text.trim();
    final port = int.tryParse(portCtrl.text.trim()) ?? 35000;
    if (host.isEmpty) return;
    _lastWifiHost = host;
    _lastWifiPort = port;
    _pick(WifiDiscoveredDevice(host: host, port: port));
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
        title: const Text('Select Connection'),
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
            child: ListView.separated(
              itemCount: sorted.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return ListTile(
                    leading: const Icon(Icons.wifi, color: Color(0xFF2563EB)),
                    title: const Text('Connect over WiFi…'),
                    subtitle: Text(
                      'Last: $_lastWifiHost:$_lastWifiPort',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: const _Badge(
                      label: 'WiFi',
                      color: Color(0xFF2563EB),
                    ),
                    onTap: _enterWifi,
                  );
                }
                final d = sorted[i - 1];
                return _DeviceTile(device: d, onTap: () => _pick(d));
              },
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

    final (subtitle, badge, leadingIcon) = switch (device) {
      BleDiscoveredDevice(:final rssi) => (
        'BLE  ·  ${device.address}  ·  RSSI $rssi',
        const _Badge(label: 'BLE'),
        Icons.bluetooth,
      ),
      SppDiscoveredDevice(:final bonded) => (
        'Classic SPP  ·  ${device.address}${bonded ? '  ·  paired' : ''}',
        const _Badge(label: 'SPP', color: Color(0xFF1A8A5A)),
        Icons.bluetooth_audio,
      ),
      WifiDiscoveredDevice() => (
        'TCP  ·  ${device.address}',
        const _Badge(label: 'WiFi', color: Color(0xFF2563EB)),
        Icons.wifi,
      ),
      UsbDiscoveredDevice() => (
        'USB serial  ·  ${device.address}',
        const _Badge(label: 'USB', color: Color(0xFFB45309)),
        Icons.usb,
      ),
    };

    return ListTile(
      leading: Icon(
        likely ? Icons.directions_car : leadingIcon,
        color: iconColor,
      ),
      title: Text(device.name),
      subtitle: Text(subtitle),
      trailing: badge,
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
