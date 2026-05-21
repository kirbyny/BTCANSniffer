class CanFrame {
  CanFrame({
    required this.timestampMs,
    required this.idHex,
    required this.id,
    required this.extended,
    required this.dlc,
    required this.data,
  });

  final int timestampMs;
  final String idHex;
  final int id;
  final bool extended;
  final int dlc;
  final List<int> data;

  String toLogLine() {
    final hexBytes = data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(',');
    return '$timestampMs,$idHex,$id,${extended ? 1 : 0},$dlc,$hexBytes';
  }

  static CanFrame? tryParseLogLine(String line) {
    final parts = line.split(',');
    if (parts.length < 6) {
      return null;
    }
    final ts = int.tryParse(parts[0]);
    final idHex = parts[1];
    final id = int.tryParse(parts[2]);
    final extended = parts[3] == '1';
    final dlc = int.tryParse(parts[4]);
    if (ts == null || id == null || dlc == null) {
      return null;
    }
    final data = <int>[];
    for (var i = 5; i < parts.length && data.length < 8; i++) {
      final b = int.tryParse(parts[i], radix: 16);
      if (b == null) {
        break;
      }
      data.add(b);
    }
    while (data.length < 8) {
      data.add(0);
    }
    return CanFrame(
      timestampMs: ts,
      idHex: idHex,
      id: id,
      extended: extended,
      dlc: dlc,
      data: data,
    );
  }
}

class CanRowModel {
  CanRowModel({
    required this.id,
    required this.idHex,
    required this.extended,
    required this.dlc,
    required this.data,
    required this.changed,
    required this.lastTimestampMs,
    required this.count,
  });

  final int id;
  final String idHex;
  final bool extended;
  int dlc;
  List<int> data;
  Set<int> changed;
  int lastTimestampMs;
  int count;
}

class CanProtocol {
  const CanProtocol({
    required this.code,
    required this.label,
    required this.description,
  });

  final String code;
  final String label;
  final String description;

  static const List<CanProtocol> presets = [
    CanProtocol(
      code: '6',
      label: '11-bit · 500 kbps',
      description: 'ISO 15765-4 CAN (standard ID, 500 kbps) — most modern OBD-II vehicles',
    ),
    CanProtocol(
      code: '7',
      label: '29-bit · 500 kbps',
      description: 'ISO 15765-4 CAN (extended ID, 500 kbps)',
    ),
    CanProtocol(
      code: '8',
      label: '11-bit · 250 kbps',
      description: 'ISO 15765-4 CAN (standard ID, 250 kbps)',
    ),
    CanProtocol(
      code: '9',
      label: '29-bit · 250 kbps',
      description: 'ISO 15765-4 CAN (extended ID, 250 kbps)',
    ),
    CanProtocol(
      code: 'A',
      label: 'J1939 · 29-bit · 250 kbps',
      description: 'SAE J1939 (heavy-duty trucks, marine)',
    ),
    CanProtocol(
      code: '0',
      label: 'Auto-detect',
      description: 'Let the ELM327 negotiate the protocol with the vehicle',
    ),
  ];
}
