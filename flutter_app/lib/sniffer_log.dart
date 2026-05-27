import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SnifferEntry {
  SnifferEntry({
    required this.timestamp,
    required this.idHex,
    required this.byteIndex,
    required this.bitmask,
    required this.signalName,
  });

  final DateTime timestamp;
  final String idHex;
  final int byteIndex;
  final int bitmask;
  final String signalName;

  String toCsvLine() {
    final mask = '0x${bitmask.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    // Strip commas/quotes from user-supplied name so the CSV stays single-line.
    final safe = signalName.replaceAll(RegExp(r'[,"\r\n]'), ' ').trim();
    return '${timestamp.toUtc().toIso8601String()},$idHex,$byteIndex,$mask,$safe';
  }

  static SnifferEntry? tryParseCsv(String line) {
    final parts = line.split(',');
    if (parts.length < 5) return null;
    try {
      final ts = DateTime.parse(parts[0]);
      final id = parts[1];
      final byteIndex = int.parse(parts[2]);
      final maskStr = parts[3].trim().toLowerCase().replaceFirst(RegExp(r'^0x'), '');
      final mask = int.parse(maskStr, radix: 16);
      final name = parts.sublist(4).join(',');
      return SnifferEntry(
        timestamp: ts,
        idHex: id,
        byteIndex: byteIndex,
        bitmask: mask,
        signalName: name,
      );
    } catch (_) {
      return null;
    }
  }
}

class SnifferLog {
  static const String _fileName = 'sniffer.csv';
  static const String _header =
      'timestamp_iso,can_id_hex,byte_index,bitmask_hex,signal_name';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<File> append(SnifferEntry entry) async {
    final f = await _file();
    final exists = await f.exists();
    final sink = f.openWrite(mode: FileMode.append);
    if (!exists) {
      sink.writeln(_header);
    }
    sink.writeln(entry.toCsvLine());
    await sink.flush();
    await sink.close();
    return f;
  }

  static Future<List<SnifferEntry>> readAll() async {
    final f = await _file();
    if (!await f.exists()) return [];
    final lines = await f.readAsLines();
    final out = <SnifferEntry>[];
    for (final l in lines) {
      if (l.isEmpty || l.startsWith('timestamp_iso')) continue;
      final e = SnifferEntry.tryParseCsv(l);
      if (e != null) out.add(e);
    }
    return out;
  }

  static Future<void> share() async {
    final f = await _file();
    if (await f.exists()) {
      await Share.shareXFiles([XFile(f.path)], text: 'CAN signal sniffer log');
    }
  }

  static Future<File> path() => _file();
}
