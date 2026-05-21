import 'dart:io';

import 'package:flutter/material.dart';

import 'capture_log.dart';
import 'models.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  List<CanFrame> _frames = [];
  bool _loading = true;
  String _filter = '';
  bool _groupById = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final frames = await CaptureLogFile.readAll(widget.file);
    if (!mounted) return;
    setState(() {
      _frames = frames;
      _loading = false;
    });
  }

  Iterable<CanFrame> get _filtered {
    if (_filter.isEmpty) return _frames;
    final f = _filter.toUpperCase();
    return _frames.where((fr) => fr.idHex.contains(f));
  }

  Widget _byteCell(int? value, {bool dim = false}) {
    final txt = value == null ? '--' : value.toRadixString(16).padLeft(2, '0').toUpperCase();
    return Container(
      width: 30,
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      padding: const EdgeInsets.symmetric(vertical: 3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: value == null ? Colors.grey.shade200 : (dim ? Colors.grey.shade100 : const Color(0xFFD9F3E7)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(txt, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered.toList();
    Map<int, CanFrame>? lastById;
    if (_groupById) {
      lastById = {};
      for (final f in list) {
        lastById[f.id] = f;
      }
    }
    final rows = _groupById ? lastById!.values.toList() : list;
    if (_groupById) {
      rows.sort((a, b) => a.id.compareTo(b.id));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.file.uri.pathSegments.last),
        actions: [
          IconButton(
            tooltip: _groupById ? 'Switch to chronological list' : 'Switch to per-ID rollup',
            onPressed: () => setState(() => _groupById = !_groupById),
            icon: Icon(_groupById ? Icons.list : Icons.layers),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Filter by ID (hex prefix)',
                      isDense: true,
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.filter_alt_outlined),
                    ),
                    onChanged: (v) => setState(() => _filter = v.trim()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Text('${_frames.length} frames total'),
                      const SizedBox(width: 12),
                      Text('${rows.length} shown'),
                    ],
                  ),
                ),
                const Divider(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final f = rows[i];
                      return ListTile(
                        dense: true,
                        title: Row(
                          children: [
                            SizedBox(
                              width: 80,
                              child: Text(
                                f.idHex,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            SizedBox(width: 40, child: Text('D${f.dlc}')),
                            Expanded(
                              child: Wrap(
                                children: [
                                  for (var j = 0; j < 8; j++)
                                    _byteCell(j < f.dlc ? f.data[j] : null, dim: j >= f.dlc),
                                ],
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text('t=${f.timestampMs} ms${f.extended ? ' · ext' : ''}'),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
