import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum SnifferExportFormat { csv, dbc }

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

  SnifferEntry copyWith({String? signalName}) {
    return SnifferEntry(
      timestamp: timestamp,
      idHex: idHex,
      byteIndex: byteIndex,
      bitmask: bitmask,
      signalName: signalName ?? this.signalName,
    );
  }

  String toCsvLine() {
    final mask = '0x${bitmask.toRadixString(16).padLeft(2, '0').toUpperCase()}';
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

  /// Rewrites the on-disk log with [entries] (in oldest-first order).
  static Future<File> rewrite(List<SnifferEntry> entries) async {
    final f = await _file();
    final sink = f.openWrite();
    sink.writeln(_header);
    for (final e in entries) {
      sink.writeln(e.toCsvLine());
    }
    await sink.flush();
    await sink.close();
    return f;
  }

  /// Replaces the entry at [displayIndex] (0-based, **newest-first** order as
  /// shown in the viewer) with [replacement] and persists. Returns the new
  /// full list (oldest-first).
  static Future<List<SnifferEntry>> updateAt(
    int displayIndex,
    SnifferEntry replacement,
  ) async {
    final all = await readAll();
    final reversed = all.reversed.toList();
    if (displayIndex < 0 || displayIndex >= reversed.length) return all;
    reversed[displayIndex] = replacement;
    final restored = reversed.reversed.toList();
    await rewrite(restored);
    return restored;
  }

  /// Removes the entry at [displayIndex] (newest-first) and persists.
  static Future<List<SnifferEntry>> deleteAt(int displayIndex) async {
    final all = await readAll();
    final reversed = all.reversed.toList();
    if (displayIndex < 0 || displayIndex >= reversed.length) return all;
    reversed.removeAt(displayIndex);
    final restored = reversed.reversed.toList();
    await rewrite(restored);
    return restored;
  }

  /// Writes a copy of the current log to a temp file using [baseName] (no
  /// extension; the format's natural extension is appended) and returns it.
  /// Caller is responsible for sharing/displaying.
  static Future<File> export({
    required String baseName,
    required SnifferExportFormat format,
  }) async {
    final dir = await getTemporaryDirectory();
    final ext = format == SnifferExportFormat.dbc ? 'dbc' : 'csv';
    final safe = _safeFileName(baseName);
    final out = File('${dir.path}/$safe.$ext');
    final entries = await readAll();
    final content = format == SnifferExportFormat.dbc
        ? formatDbc(entries)
        : formatCsv(entries);
    await out.writeAsString(content);
    return out;
  }

  static String _safeFileName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_').trim();
    return cleaned.isEmpty ? 'sniffer' : cleaned;
  }

  static Future<void> share() async {
    final f = await _file();
    if (await f.exists()) {
      await Share.shareXFiles([XFile(f.path)], text: 'CAN signal sniffer log');
    }
  }

  static Future<File> path() => _file();

  // ----- formatters ---------------------------------------------------------

  static String formatCsv(List<SnifferEntry> entries) {
    final sb = StringBuffer()..writeln(_header);
    for (final e in entries) {
      sb.writeln(e.toCsvLine());
    }
    return sb.toString();
  }

  /// Builds a minimal valid DBC describing each recorded position as a 1-bit
  /// little-endian unsigned signal. Entries that recorded a multi-bit mask
  /// are split into one signal per set bit, suffixed `_bit<n>`.
  static String formatDbc(List<SnifferEntry> entries) {
    final sb = StringBuffer()
      ..writeln('VERSION ""')
      ..writeln()
      ..writeln('NS_ :')
      ..writeln()
      ..writeln('BS_:')
      ..writeln()
      ..writeln('BU_:')
      ..writeln();

    final groups = <String, List<SnifferEntry>>{};
    for (final e in entries) {
      groups.putIfAbsent(e.idHex, () => []).add(e);
    }
    final sortedIds = groups.keys.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a, radix: 16) ?? 0;
        final bi = int.tryParse(b, radix: 16) ?? 0;
        return ai.compareTo(bi);
      });

    for (final idHex in sortedIds) {
      final idDecimal = int.tryParse(idHex, radix: 16) ?? 0;
      sb.writeln('BO_ $idDecimal MSG_$idHex: 8 Vector__XXX');
      // Deduplicate identical (byte, bit, name) combinations so a re-recorded
      // signal doesn't produce two identical SG_ lines.
      final seen = <String>{};
      for (final e in groups[idHex]!) {
        final bits = _setBitPositions(e.bitmask);
        final multi = bits.length > 1;
        for (final bitPos in bits) {
          final startBit = e.byteIndex * 8 + bitPos;
          final base = _dbcIdentifier(e.signalName);
          final name = multi ? '${base}_bit$bitPos' : base;
          final key = '$startBit:$name';
          if (!seen.add(key)) continue;
          sb.writeln(' SG_ $name : $startBit|1@1+ (1,0) [0|1] "" Vector__XXX');
        }
      }
      sb.writeln();
    }

    return sb.toString();
  }

  static List<int> _setBitPositions(int mask) {
    final out = <int>[];
    for (var i = 0; i < 32; i++) {
      if (((mask >> i) & 1) == 1) out.add(i);
    }
    return out;
  }

  static String _dbcIdentifier(String s) {
    var cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (cleaned.isEmpty) cleaned = 'Signal';
    if (RegExp(r'^[0-9]').hasMatch(cleaned)) cleaned = 'S_$cleaned';
    return cleaned;
  }
}
