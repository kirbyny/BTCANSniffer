import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum SnifferExportFormat { csv, dbc }

/// A recorded signal. Two flavors, sharing one storage format:
///
/// * **Bit signal** — `length == 0`. Identified by `bitmask` over `byteIndex`.
///   Authored via the bit explorer's double-tap on a bit.
/// * **Byte signal** — `length > 0`. A multi-byte field at `byteIndex` of
///   `length` bytes, with `littleEndian` byte order, `signed` interpretation,
///   and a linear `scale * raw + offset` decode into `unit`. Authored via the
///   byte explorer's double-tap on a byte-group card.
class SnifferEntry {
  SnifferEntry({
    required this.timestamp,
    required this.idHex,
    required this.byteIndex,
    required this.bitmask,
    required this.signalName,
    this.length = 0,
    this.littleEndian = true,
    this.signed = false,
    this.scale = 1.0,
    this.offset = 0.0,
    this.unit = '',
  });

  final DateTime timestamp;
  final String idHex;
  final int byteIndex;
  final int bitmask;
  final String signalName;

  // v2 fields — defaulted for backward-compatibility with v1 rows.
  final int length;
  final bool littleEndian;
  final bool signed;
  final double scale;
  final double offset;
  final String unit;

  bool get isBitSignal => length == 0;
  bool get isByteSignal => length > 0;

  /// Total span of the signal in bits. For bit signals this is just 1 (we
  /// only allow single-bit recording from the bit explorer); for byte
  /// signals it's `length * 8`.
  int get bitLength => isBitSignal ? 1 : length * 8;

  SnifferEntry copyWith({
    String? signalName,
    double? scale,
    double? offset,
    String? unit,
    bool? signed,
    bool? littleEndian,
  }) {
    return SnifferEntry(
      timestamp: timestamp,
      idHex: idHex,
      byteIndex: byteIndex,
      bitmask: bitmask,
      signalName: signalName ?? this.signalName,
      length: length,
      littleEndian: littleEndian ?? this.littleEndian,
      signed: signed ?? this.signed,
      scale: scale ?? this.scale,
      offset: offset ?? this.offset,
      unit: unit ?? this.unit,
    );
  }

  String toCsvLine() {
    final mask = '0x${bitmask.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    final safe = _safe(signalName);
    final safeUnit = _safe(unit);
    return [
      timestamp.toUtc().toIso8601String(),
      idHex,
      byteIndex,
      length,
      littleEndian ? 'le' : 'be',
      signed ? 1 : 0,
      mask,
      _formatNum(scale),
      _formatNum(offset),
      safeUnit,
      safe,
    ].join(',');
  }

  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[,"\r\n]'), ' ').trim();

  static String _formatNum(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(1);
    return v.toString();
  }

  static SnifferEntry? tryParseCsv(String line) {
    final parts = line.split(',');
    if (parts.length < 5) return null;
    try {
      final ts = DateTime.parse(parts[0]);
      final id = parts[1];
      final byteIndex = int.parse(parts[2]);

      // v1 layout: timestamp, id_hex, byte_index, bitmask_hex, signal_name
      if (parts.length == 5) {
        final maskStr =
            parts[3].trim().toLowerCase().replaceFirst(RegExp(r'^0x'), '');
        final mask = int.parse(maskStr, radix: 16);
        return SnifferEntry(
          timestamp: ts,
          idHex: id,
          byteIndex: byteIndex,
          bitmask: mask,
          signalName: parts[4],
        );
      }

      // v2 layout: timestamp, id_hex, byte_index, length, byte_order, signed,
      //            bitmask_hex, scale, offset, unit, signal_name
      final length = int.parse(parts[3]);
      final littleEndian = parts[4].trim().toLowerCase() != 'be';
      final signed = parts[5].trim() == '1';
      final maskStr =
          parts[6].trim().toLowerCase().replaceFirst(RegExp(r'^0x'), '');
      final mask = int.parse(maskStr, radix: 16);
      final scale = double.parse(parts[7]);
      final offset = double.parse(parts[8]);
      final unit = parts[9];
      final name = parts.sublist(10).join(',');
      return SnifferEntry(
        timestamp: ts,
        idHex: id,
        byteIndex: byteIndex,
        bitmask: mask,
        signalName: name,
        length: length,
        littleEndian: littleEndian,
        signed: signed,
        scale: scale,
        offset: offset,
        unit: unit,
      );
    } catch (_) {
      return null;
    }
  }
}

class SnifferLog {
  static const String _fileName = 'sniffer.csv';
  static const String _headerV2 =
      'timestamp_iso,can_id_hex,byte_index,length,byte_order,signed,'
      'bitmask_hex,scale,offset,unit,signal_name';
  static const String _headerV1 =
      'timestamp_iso,can_id_hex,byte_index,bitmask_hex,signal_name';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Appends one entry. If the on-disk file is in v1 layout we rewrite it
  /// as v2 first so the file stays consistent (cheaper than carrying mixed
  /// rows forward).
  static Future<File> append(SnifferEntry entry) async {
    final f = await _file();
    final exists = await f.exists();
    if (exists) {
      final firstLine = await _firstNonEmptyLine(f);
      if (firstLine != null && firstLine.startsWith('timestamp_iso') &&
          !firstLine.contains('length')) {
        // v1 file — migrate before appending.
        final existing = await readAll();
        await rewrite([...existing, entry]);
        return f;
      }
    }
    final sink = f.openWrite(mode: FileMode.append);
    if (!exists) {
      sink.writeln(_headerV2);
    }
    sink.writeln(entry.toCsvLine());
    await sink.flush();
    await sink.close();
    return f;
  }

  static Future<String?> _firstNonEmptyLine(File f) async {
    final lines = await f.readAsLines();
    for (final l in lines) {
      if (l.trim().isNotEmpty) return l;
    }
    return null;
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

  static Future<File> rewrite(List<SnifferEntry> entries) async {
    final f = await _file();
    final sink = f.openWrite();
    sink.writeln(_headerV2);
    for (final e in entries) {
      sink.writeln(e.toCsvLine());
    }
    await sink.flush();
    await sink.close();
    return f;
  }

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

  static Future<List<SnifferEntry>> deleteAt(int displayIndex) async {
    final all = await readAll();
    final reversed = all.reversed.toList();
    if (displayIndex < 0 || displayIndex >= reversed.length) return all;
    reversed.removeAt(displayIndex);
    final restored = reversed.reversed.toList();
    await rewrite(restored);
    return restored;
  }

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

  /// Returns the file containing both schemas. Currently identical to [path].
  static String get headerV1 => _headerV1;

  // ----- formatters ---------------------------------------------------------

  static String formatCsv(List<SnifferEntry> entries) {
    final sb = StringBuffer()..writeln(_headerV2);
    for (final e in entries) {
      sb.writeln(e.toCsvLine());
    }
    return sb.toString();
  }

  /// Builds a minimal valid DBC. Bit signals become `length=1` unsigned LE
  /// signals; byte signals carry their full metadata (length, endianness,
  /// signedness, scale, offset, unit). Multi-bit masks on bit entries are
  /// split into one signal per set bit, suffixed `_bit<n>`.
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
      final seen = <String>{};
      for (final e in groups[idHex]!) {
        for (final line in _dbcSignalLines(e, seen)) {
          sb.writeln(line);
        }
      }
      sb.writeln();
    }

    return sb.toString();
  }

  static Iterable<String> _dbcSignalLines(
    SnifferEntry e,
    Set<String> seen,
  ) sync* {
    if (e.isByteSignal) {
      final startBit = e.byteIndex * 8;
      final bits = e.length * 8;
      final byteOrder = e.littleEndian ? '1' : '0';
      final sign = e.signed ? '-' : '+';
      final (minV, maxV) = _signalRange(e);
      final name = _dbcIdentifier(e.signalName);
      final key = '$startBit:$bits:$name';
      if (seen.add(key)) {
        yield ' SG_ $name : $startBit|$bits@$byteOrder$sign '
            '(${_dbcNum(e.scale)},${_dbcNum(e.offset)}) '
            '[${_dbcNum(minV)}|${_dbcNum(maxV)}] '
            '"${e.unit}" Vector__XXX';
      }
      return;
    }

    // Bit signal — split multi-bit masks into per-bit signals.
    final bits = _setBitPositions(e.bitmask);
    final multi = bits.length > 1;
    final base = _dbcIdentifier(e.signalName);
    for (final bitPos in bits) {
      final startBit = e.byteIndex * 8 + bitPos;
      final name = multi ? '${base}_bit$bitPos' : base;
      final key = '$startBit:1:$name';
      if (!seen.add(key)) continue;
      yield ' SG_ $name : $startBit|1@1+ (1,0) [0|1] "" Vector__XXX';
    }
  }

  static (double, double) _signalRange(SnifferEntry e) {
    final bits = e.bitLength;
    final scale = e.scale;
    final offset = e.offset;
    if (e.signed) {
      final maxRaw = (1 << (bits - 1)) - 1;
      final minRaw = -(1 << (bits - 1));
      return (minRaw * scale + offset, maxRaw * scale + offset);
    } else {
      final maxRaw = bits >= 63 ? double.maxFinite : ((1 << bits) - 1).toDouble();
      return (offset, maxRaw * scale + offset);
    }
  }

  static String _dbcNum(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toStringAsFixed(1);
    }
    return v.toString();
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
