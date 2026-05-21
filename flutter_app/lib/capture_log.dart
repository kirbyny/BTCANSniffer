import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

const String kLogHeader =
    '# BTCAN Sniffer log v1\n'
    '# columns: timestamp_ms,id_hex,id_decimal,extended,dlc,b0,b1,b2,b3,b4,b5,b6,b7\n';

class CaptureLogFile {
  CaptureLogFile._(this.file, this._sink);

  final File file;
  final IOSink _sink;
  int _frameCount = 0;

  int get frameCount => _frameCount;
  String get path => file.path;
  String get fileName => file.uri.pathSegments.last;

  static Future<Directory> logsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/captures');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<CaptureLogFile> open({required String label}) async {
    final dir = await logsDir();
    final ts = DateTime.now();
    final stamp = '${ts.year}${_two(ts.month)}${_two(ts.day)}_'
        '${_two(ts.hour)}${_two(ts.minute)}${_two(ts.second)}';
    final safeLabel = label.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final fname = safeLabel.isEmpty ? 'capture_$stamp.log' : 'capture_${safeLabel}_$stamp.log';
    final f = File('${dir.path}/$fname');
    final sink = f.openWrite();
    sink.write(kLogHeader);
    return CaptureLogFile._(f, sink);
  }

  void writeFrame(CanFrame frame) {
    _sink.writeln(frame.toLogLine());
    _frameCount++;
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static Future<List<File>> listAll() async {
    final dir = await logsDir();
    if (!await dir.exists()) {
      return [];
    }
    final entries = await dir
        .list()
        .where((e) => e is File && (e.path.endsWith('.log') || e.path.endsWith('.csv')))
        .cast<File>()
        .toList();
    entries.sort((a, b) => b.path.compareTo(a.path));
    return entries;
  }

  static Future<List<CanFrame>> readAll(File file) async {
    final out = <CanFrame>[];
    final lines = await file.readAsLines();
    for (final l in lines) {
      if (l.isEmpty || l.startsWith('#')) {
        continue;
      }
      final f = CanFrame.tryParseLogLine(l);
      if (f != null) {
        out.add(f);
      }
    }
    return out;
  }

  /// Converts a `.log` capture file to a sibling `.csv` (with a friendly header)
  /// suitable for sharing or opening in spreadsheets. Returns the new file.
  static Future<File> exportAsCsv(File logFile) async {
    final csvPath = '${logFile.path.replaceAll(RegExp(r'\.log$'), '')}.csv';
    final csv = File(csvPath);
    final sink = csv.openWrite();
    sink.writeln(
        'timestamp_ms,id_hex,id_decimal,extended,dlc,b0,b1,b2,b3,b4,b5,b6,b7');
    final lines = await logFile.readAsLines();
    for (final l in lines) {
      if (l.isEmpty || l.startsWith('#')) {
        continue;
      }
      sink.writeln(l);
    }
    await sink.flush();
    await sink.close();
    return csv;
  }
}
