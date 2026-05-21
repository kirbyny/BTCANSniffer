import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'capture_log.dart';
import 'log_viewer_screen.dart';

class LogBrowserScreen extends StatefulWidget {
  const LogBrowserScreen({super.key});

  @override
  State<LogBrowserScreen> createState() => _LogBrowserScreenState();
}

class _LogBrowserScreenState extends State<LogBrowserScreen> {
  List<File> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final files = await CaptureLogFile.listAll();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  Future<void> _exportCsv(File f) async {
    final csv = await CaptureLogFile.exportAsCsv(f);
    await Share.shareXFiles([XFile(csv.path)], text: 'CAN capture (CSV)');
  }

  Future<void> _shareRaw(File f) async {
    await Share.shareXFiles([XFile(f.path)], text: 'CAN capture (raw log)');
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete log?'),
        content: Text(f.uri.pathSegments.last),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await f.delete();
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capture Logs'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No captures yet. Connect to a VLinker and start a capture from the main screen.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final f = _files[i];
                    final stat = f.statSync();
                    return ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(f.uri.pathSegments.last),
                      subtitle: Text(
                        '${_humanSize(stat.size)}  ·  ${stat.modified.toLocal().toString().split('.').first}',
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => LogViewerScreen(file: f)),
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          switch (action) {
                            case 'view':
                              await Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => LogViewerScreen(file: f)),
                              );
                              break;
                            case 'csv':
                              await _exportCsv(f);
                              break;
                            case 'raw':
                              await _shareRaw(f);
                              break;
                            case 'delete':
                              await _delete(f);
                              break;
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'view', child: Text('View')),
                          PopupMenuItem(value: 'csv', child: Text('Export as CSV')),
                          PopupMenuItem(value: 'raw', child: Text('Share raw log')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
