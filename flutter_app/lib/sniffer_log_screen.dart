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

  String _subtitleFor(SnifferEntry e) {
    if (e.isBitSignal) {
      return 'bit · ID ${e.idHex}  ·  byte ${e.byteIndex}  ·  '
          'mask ${_maskHex(e.bitmask)} (${_maskBin(e.bitmask)})';
    }
    final lenLabel = e.length == 1
        ? '1 byte'
        : '${e.length} bytes ${e.littleEndian ? 'LE' : 'BE'}';
    final type = e.signed ? 'int' : 'uint';
    final scaleStr = e.scale == 1.0 ? '' : ' × ${e.scale}';
    final offsetStr = e.offset == 0.0
        ? ''
        : (e.offset > 0 ? ' + ${e.offset}' : ' − ${e.offset.abs()}');
    final unitStr = e.unit.isEmpty ? '' : ' ${e.unit}';
    return '$type${e.length * 8} · ID ${e.idHex}  ·  byte ${e.byteIndex} '
        '($lenLabel)$scaleStr$offsetStr$unitStr';
  }

  Future<void> _editEntry(int displayIndex) async {
    final e = _entries[displayIndex];
    final result = e.isBitSignal
        ? await _editBitDialog(e)
        : await _editByteDialog(e);
    if (!mounted || result == null) return;

    if (result.delete) {
      final confirmed = await _confirmDelete(e);
      if (!mounted || confirmed != true) return;
      await SnifferLog.deleteAt(displayIndex);
      await _load();
      return;
    }

    if (result.replacement != null) {
      await SnifferLog.updateAt(displayIndex, result.replacement!);
      await _load();
    }
  }

  Future<_EditResult?> _editBitDialog(SnifferEntry e) async {
    final controller = TextEditingController(text: e.signalName);
    return showDialog<_EditResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit bit signal'),
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
              onSubmitted: (_) => Navigator.pop(
                ctx,
                _EditResult.save(e.copyWith(signalName: controller.text.trim())),
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, const _EditResult.delete()),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('Delete'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = controller.text.trim();
              Navigator.pop(
                ctx,
                _EditResult.save(e.copyWith(signalName: n.isEmpty ? e.signalName : n)),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<_EditResult?> _editByteDialog(SnifferEntry e) async {
    final nameCtrl = TextEditingController(text: e.signalName);
    final scaleCtrl = TextEditingController(text: e.scale.toString());
    final offsetCtrl = TextEditingController(text: e.offset.toString());
    final unitCtrl = TextEditingController(text: e.unit);
    var signed = e.signed;
    var littleEndian = e.littleEndian;

    return showDialog<_EditResult>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSt) {
          return AlertDialog(
            title: const Text('Edit byte signal'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ID ${e.idHex} · byte ${e.byteIndex} · ${e.length} byte${e.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Signal name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: scaleCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Scale',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType:
                              const TextInputType.numberWithOptions(
                                  signed: true, decimal: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: offsetCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Offset',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType:
                              const TextInputType.numberWithOptions(
                                  signed: true, decimal: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: unitCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Unit',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: signed,
                            onChanged: (v) =>
                                setSt(() => signed = v ?? false),
                          ),
                          const Text('Signed'),
                        ],
                      ),
                    ],
                  ),
                  if (e.length > 1)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Byte order: '),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, label: Text('LE')),
                            ButtonSegment(value: false, label: Text('BE')),
                          ],
                          selected: {littleEndian},
                          onSelectionChanged: (s) =>
                              setSt(() => littleEndian = s.first),
                          showSelectedIcon: false,
                        ),
                      ],
                    ),
                ],
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, const _EditResult.delete()),
                style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                child: const Text('Delete'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final n = nameCtrl.text.trim();
                  final s = double.tryParse(scaleCtrl.text.trim()) ?? e.scale;
                  final o = double.tryParse(offsetCtrl.text.trim()) ?? e.offset;
                  Navigator.pop(
                    ctx,
                    _EditResult.save(e.copyWith(
                      signalName: n.isEmpty ? e.signalName : n,
                      scale: s,
                      offset: o,
                      unit: unitCtrl.text.trim(),
                      signed: signed,
                      littleEndian: littleEndian,
                    )),
                  );
                },
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<bool?> _confirmDelete(SnifferEntry e) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete signal?'),
        content: Text('"${e.signalName}" — ID ${e.idHex} byte ${e.byteIndex}'),
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

  Widget _typeBadge(SnifferEntry e) {
    final isByte = e.isByteSignal;
    final c = isByte ? Colors.indigo : Colors.teal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(
        isByte ? 'BYTE' : 'BIT',
        style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600),
      ),
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
                      'Open the explorer for any CAN ID and double-tap '
                      '— a bit lane in Bits mode, or a byte card in Bytes mode.',
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
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.signalName,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _typeBadge(e),
                        ],
                      ),
                      subtitle: Text(
                        _subtitleFor(e),
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

class _EditResult {
  const _EditResult.save(this.replacement) : delete = false;
  const _EditResult.delete()
      : replacement = null,
        delete = true;

  final SnifferEntry? replacement;
  final bool delete;
}
