import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'sniffer_log.dart';

class SnifferLogScreen extends StatefulWidget {
  const SnifferLogScreen({super.key});

  @override
  State<SnifferLogScreen> createState() => _SnifferLogScreenState();
}

class _SnifferLogScreenState extends State<SnifferLogScreen> {
  List<SnifferEntry> _entries = []; // displayed newest-first
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
      _entries = entries.reversed.toList();
      _loading = false;
    });
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
  String _maskHex(int m) =>
      '0x${m.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  String _maskBin(int m) => m.toRadixString(2).padLeft(8, '0');

  Future<void> _editEntry(int displayIndex) async {
    final e = _entries[displayIndex];
    final controller = TextEditingController(text: e.signalName);
    final action = await showDialog<_EditAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit signal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ID ${e.idHex} · byte ${e.byteIndex} · mask ${_maskHex(e.bitmask)} (${_maskBin(e.bitmask)})',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Signal name',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(ctx, _EditAction.save),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _EditAction.delete),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('Delete'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _EditAction.cancel),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _EditAction.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == _EditAction.cancel) return;

    if (action == _EditAction.delete) {
      final confirmed = await _confirmDelete(e);
      if (!mounted || confirmed != true) return;
      await SnifferLog.deleteAt(displayIndex);
      await _load();
      return;
    }

    final newName = controller.text.trim();
    if (newName.isEmpty || newName == e.signalName) {
      return;
    }
    await SnifferLog.updateAt(displayIndex, e.copyWith(signalName: newName));
    await _load();
  }

  Future<bool?> _confirmDelete(SnifferEntry e) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete signal?'),
        content: Text('"${e.signalName}" — ID ${e.idHex} byte ${e.byteIndex} '
            'mask ${_maskHex(e.bitmask)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              foregroundColor: Colors.red.shade700,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    final ts = DateTime.now();
    final defaultName =
        'sniffer_${ts.year}${_pad(ts.month)}${_pad(ts.day)}_'
        '${_pad(ts.hour)}${_pad(ts.minute)}${_pad(ts.second)}';
    final nameController = TextEditingController(text: defaultName);
    var format = SnifferExportFormat.csv;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        return AlertDialog(
          title: const Text('Export sniffer log'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Filename',
                  hintText: 'no extension — added automatically',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Format',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              RadioGroup<SnifferExportFormat>(
                groupValue: format,
                onChanged: (v) => setSt(() => format = v!),
                child: const Column(
                  children: [
                    RadioListTile<SnifferExportFormat>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: SnifferExportFormat.csv,
                      title: Text('CSV'),
                      subtitle: Text(
                        'Spreadsheet-friendly, includes the full timestamp',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    RadioListTile<SnifferExportFormat>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: SnifferExportFormat.dbc,
                      title: Text('DBC'),
                      subtitle: Text(
                        'CAN database — open in cantools, CANdb++, SavvyCAN, etc.',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
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
              child: const Text('Export'),
            ),
          ],
        );
      }),
    );
    if (!mounted || ok != true) return;

    final baseName =
        nameController.text.trim().isEmpty ? defaultName : nameController.text.trim();
    final f = await SnifferLog.export(baseName: baseName, format: format);
    await Share.shareXFiles(
      [XFile(f.path)],
      text: format == SnifferExportFormat.dbc
          ? 'CAN signal sniffer log (DBC)'
          : 'CAN signal sniffer log (CSV)',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sniffer Log'),
        actions: [
          IconButton(
            tooltip: 'Export...',
            onPressed: _entries.isEmpty ? null : _export,
            icon: const Icon(Icons.ios_share),
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
                      onTap: () => _editEntry(i),
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
                        style:
                            const TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    );
                  },
                ),
    );
  }
}

enum _EditAction { save, delete, cancel }
