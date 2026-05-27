import 'package:flutter/material.dart';

import 'sniffer_log.dart';

class SnifferLogScreen extends StatefulWidget {
  const SnifferLogScreen({super.key});

  @override
  State<SnifferLogScreen> createState() => _SnifferLogScreenState();
}

class _SnifferLogScreenState extends State<SnifferLogScreen> {
  List<SnifferEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await SnifferLog.readAll();
    if (!mounted) return;
    setState(() {
      _entries = entries.reversed.toList(); // newest first
      _loading = false;
    });
  }

  String _maskHex(int mask) =>
      '0x${mask.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String _maskBin(int mask) => mask.toRadixString(2).padLeft(8, '0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sniffer Log'),
        actions: [
          IconButton(
            tooltip: 'Share CSV',
            onPressed: SnifferLog.share,
            icon: const Icon(Icons.share),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No signals saved yet.\n\n'
                      'Open the bit explorer for any CAN ID, watch the bit graphs, '
                      'and double-tap a bit you want to name.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        e.signalName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        'ID ${e.idHex}  ·  byte ${e.byteIndex}  ·  '
                        'mask ${_maskHex(e.bitmask)} (${_maskBin(e.bitmask)})',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: Text(
                        e.timestamp.toLocal().toString().split('.').first,
                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    );
                  },
                ),
    );
  }
}
