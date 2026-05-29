import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'sniffer_log.dart';
import 'sniffer_log_screen.dart';
import 'vlinker.dart';

/// Pages over every currently-observed CAN ID's explorer body via a
/// horizontal [PageView] so swipe gestures move between IDs.
class BitExplorerScreen extends StatefulWidget {
  const BitExplorerScreen({
    super.key,
    required this.link,
    required this.tracesById,
    required this.initialCanId,
  });

  final CanProtocolDriver link;
  final Map<int, BitTrace> tracesById;
  final int initialCanId;

  @override
  State<BitExplorerScreen> createState() => _BitExplorerScreenState();
}

class _BitExplorerScreenState extends State<BitExplorerScreen> {
  /// Snapshot of the IDs available when the screen opens. New IDs arriving
  /// after that don't shuffle into the swipe order mid-session — they appear
  /// next time the explorer is opened.
  late final List<int> _ids;
  late int _currentIndex;
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _ids = widget.tracesById.keys.toList()..sort();
    _currentIndex = _ids.indexOf(widget.initialCanId);
    if (_currentIndex < 0) _currentIndex = 0;
    _controller = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _hex(int id) {
    final w = id > 0x7FF ? 8 : 3;
    return id.toRadixString(16).toUpperCase().padLeft(w, '0');
  }

  @override
  Widget build(BuildContext context) {
    if (_ids.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Explorer')),
        body: const Center(child: Text('No IDs to explore yet.')),
      );
    }
    final currentId = _ids[_currentIndex];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_hex(currentId)} · explorer'
          '${_ids.length > 1 ? '  (${_currentIndex + 1}/${_ids.length})' : ''}',
        ),
        actions: [
          IconButton(
            tooltip: 'Sniffer log',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SnifferLogScreen()),
            ),
            icon: const Icon(Icons.list_alt),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _ids.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (_, i) {
          final id = _ids[i];
          final trace = widget.tracesById[id]!;
          return _BitExplorerPage(
            key: ValueKey(id),
            link: widget.link,
            canId: id,
            canIdHex: _hex(id),
            dlc: trace.dlc,
            trace: trace,
          );
        },
      ),
    );
  }
}

enum _ExplorerMode { bits, bytes }

/// Process-wide last-used mode. Persisted across screen pushes so flipping
/// to Bytes once sticks until the user explicitly flips back.
_ExplorerMode _persistedExplorerMode = _ExplorerMode.bits;

class _BitExplorerPage extends StatefulWidget {
  const _BitExplorerPage({
    super.key,
    required this.link,
    required this.canId,
    required this.canIdHex,
    required this.dlc,
    required this.trace,
  });

  final CanProtocolDriver link;
  final int canId;
  final String canIdHex;
  final int dlc;
  final BitTrace trace;

  @override
  State<_BitExplorerPage> createState() => _BitExplorerPageState();
}

/// A user-defined view-time grouping of adjacent bytes inside the message,
/// purely visualization — not yet persisted. Lets the user test the
/// "is this 1 byte or 2?" question interactively.
class _ByteGroup {
  _ByteGroup({
    required this.startByte,
    required this.length,
    this.littleEndian = true,
  });

  final int startByte;
  int length;
  bool littleEndian;

  int get maxValue => (1 << (length * 8)) - 1;

  String get label =>
      length == 1 ? 'Byte $startByte'
      : 'Bytes $startByte-${startByte + length - 1} '
        '${littleEndian ? 'LE' : 'BE'}';

  int extract(List<int> data) {
    var v = 0;
    for (var i = 0; i < length; i++) {
      final byteIdx = startByte + i;
      if (byteIdx >= data.length) continue;
      final shift = littleEndian ? i * 8 : (length - 1 - i) * 8;
      v |= data[byteIdx] << shift;
    }
    return v;
  }
}

class _BitExplorerPageState extends State<_BitExplorerPage> {
  BitTrace get _trace => widget.trace;
  Timer? _ticker;

  _ExplorerMode get _mode => _persistedExplorerMode;
  set _mode(_ExplorerMode v) {
    setState(() {
      _persistedExplorerMode = v;
    });
  }

  /// One entry per visible byte-group. Default = 8 single-byte groups.
  /// Combine-right merges two adjacent entries; split-right peels the last
  /// byte off a multi-byte entry as a new single-byte entry.
  final List<_ByteGroup> _groups = [
    for (var i = 0; i < 8; i++) _ByteGroup(startByte: i, length: 1),
  ];

  @override
  void initState() {
    super.initState();
    // Advance the "now" cursor (and prune) at ~10 fps even when no frames
    // arrive, so the rolling window keeps scrolling.
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) _trace.tick();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _recordSignal(int byteIndex, int bit) async {
    final controller = TextEditingController();
    final mask = 1 << bit;
    final maskHex = '0x${mask.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this signal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ID ${widget.canIdHex} · byte $byteIndex · bit $bit · mask $maskHex',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              controller: controller,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Signal name',
                hintText: 'e.g. BrakePressed, LeftBlinker',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await SnifferLog.append(SnifferEntry(
      timestamp: DateTime.now(),
      idHex: widget.canIdHex,
      byteIndex: byteIndex,
      bitmask: mask,
      signalName: name,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$name" to sniffer log'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _trace,
      builder: (_, __) {
        return Column(
          children: [
            _headerBar(),
            _modeToggle(),
            const Divider(height: 1),
            Expanded(
              child: _mode == _ExplorerMode.bits
                  ? ListView.builder(
                      itemCount: 8,
                      itemBuilder: (_, byteIndex) => _byteCard(byteIndex),
                    )
                  : ListView.builder(
                      itemCount: _groups.length,
                      itemBuilder: (_, i) => _byteValueCard(i),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _modeToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Center(
        child: SegmentedButton<_ExplorerMode>(
          segments: const [
            ButtonSegment(
              value: _ExplorerMode.bits,
              label: Text('Bits'),
              icon: Icon(Icons.grid_on),
            ),
            ButtonSegment(
              value: _ExplorerMode.bytes,
              label: Text('Bytes'),
              icon: Icon(Icons.timeline),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
      ),
    );
  }

  // -------- Bytes (value) mode --------------------------------------------

  void _combineRight(int idx) {
    if (idx + 1 >= _groups.length) return;
    final left = _groups[idx];
    final right = _groups[idx + 1];
    final merged = _ByteGroup(
      startByte: left.startByte,
      length: left.length + right.length,
      littleEndian: left.littleEndian,
    );
    setState(() {
      _groups
        ..removeAt(idx + 1)
        ..removeAt(idx)
        ..insert(idx, merged);
    });
  }

  void _splitRight(int idx) {
    final g = _groups[idx];
    if (g.length <= 1) return;
    final newLeft = _ByteGroup(
      startByte: g.startByte,
      length: g.length - 1,
      littleEndian: g.littleEndian,
    );
    final peeled = _ByteGroup(
      startByte: g.startByte + g.length - 1,
      length: 1,
    );
    setState(() {
      _groups
        ..removeAt(idx)
        ..insert(idx, newLeft)
        ..insert(idx + 1, peeled);
    });
  }

  void _toggleEndian(int idx) {
    setState(() {
      _groups[idx].littleEndian = !_groups[idx].littleEndian;
    });
  }

  ({int min, int cur, int max, int count}) _groupStats(_ByteGroup g) {
    final samples = _trace.samples;
    if (samples.isEmpty) return (min: 0, cur: 0, max: 0, count: 0);
    final startMs = _trace.nowMs - BitTrace.windowMs;
    int? minV;
    int? maxV;
    var curV = 0;
    var n = 0;
    for (final s in samples) {
      if (s.t < startMs) continue;
      final v = g.extract(s.data);
      if (minV == null || v < minV) minV = v;
      if (maxV == null || v > maxV) maxV = v;
      curV = v;
      n++;
    }
    return (min: minV ?? 0, cur: curV, max: maxV ?? 0, count: n);
  }

  Widget _byteValueCard(int idx) {
    final g = _groups[idx];
    final stats = _groupStats(g);
    final latest = _trace.latestData();
    final curRaw = latest == null ? 0 : g.extract(latest);
    final maxV = g.maxValue;
    final hexW = g.length * 2;
    final accent = Theme.of(context).colorScheme.primary;
    final canCombine = idx + 1 < _groups.length;
    final canSplit = g.length > 1;
    final beyondDlc = g.startByte >= widget.dlc;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: beyondDlc ? Colors.grey.shade100 : null,
      child: InkWell(
        onDoubleTap: () => _saveByteSignal(g),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    g.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (g.length > 1)
                  TextButton(
                    onPressed: () => _toggleEndian(idx),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(g.littleEndian ? 'LE' : 'BE'),
                  ),
                IconButton(
                  onPressed: canSplit ? () => _splitRight(idx) : null,
                  tooltip: 'Split right byte',
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.call_split),
                ),
                IconButton(
                  onPressed: canCombine ? () => _combineRight(idx) : null,
                  tooltip: 'Combine with byte to the right',
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.link),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    '0x${curRaw.toRadixString(16).toUpperCase().padLeft(hexW, '0')}  ·  $curRaw',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                Expanded(child: _ValueBar(value: curRaw, maxValue: maxV, accent: accent)),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 56,
              child: CustomPaint(
                painter: _ValueGraphPainter(
                  trace: _trace,
                  group: g,
                  accent: accent,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _statBox('min', stats.min, hexW),
                const SizedBox(width: 8),
                _statBox('cur', stats.cur, hexW, emphasis: true),
                const SizedBox(width: 8),
                _statBox('max', stats.max, hexW),
                const Spacer(),
                Text(
                  '${stats.count} samples',
                  style: const TextStyle(fontSize: 10, color: Colors.black54),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Future<void> _saveByteSignal(_ByteGroup g) async {
    final nameCtrl = TextEditingController();
    final scaleCtrl = TextEditingController(text: '1.0');
    final offsetCtrl = TextEditingController(text: '0.0');
    final unitCtrl = TextEditingController();
    var signed = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return AlertDialog(
              title: const Text('Save signal'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ID ${widget.canIdHex} · ${g.label}',
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Signal name',
                        hintText: 'e.g. EngineCoolantTemp',
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
                            keyboardType: const TextInputType.numberWithOptions(
                                signed: true, decimal: true),
                            onChanged: (_) => setSt(() {}),
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
                            keyboardType: const TextInputType.numberWithOptions(
                                signed: true, decimal: true),
                            onChanged: (_) => setSt(() {}),
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
                              hintText: '°C, V, rpm…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) => setSt(() {}),
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
                    const SizedBox(height: 10),
                    _SignalPreview(
                      trace: _trace,
                      group: g,
                      signed: signed,
                      scaleText: scaleCtrl.text,
                      offsetText: offsetCtrl.text,
                      unit: unitCtrl.text,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (!mounted || saved != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final scale = double.tryParse(scaleCtrl.text.trim()) ?? 1.0;
    final offset = double.tryParse(offsetCtrl.text.trim()) ?? 0.0;
    await SnifferLog.append(SnifferEntry(
      timestamp: DateTime.now(),
      idHex: widget.canIdHex,
      byteIndex: g.startByte,
      bitmask: 0,
      signalName: name,
      length: g.length,
      littleEndian: g.littleEndian,
      signed: signed,
      scale: scale,
      offset: offset,
      unit: unitCtrl.text.trim(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$name" to sniffer log'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _statBox(String label, int value, int hexWidth, {bool emphasis = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: const TextStyle(fontSize: 10, color: Colors.black54),
        ),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: emphasis ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _headerBar() {
    final latest = _trace.latestData();
    final hexStrs = List<String>.generate(8, (i) {
      if (latest == null || i >= widget.dlc) return '--';
      return latest[i].toRadixString(16).padLeft(2, '0').toUpperCase();
    });
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              children: [
                for (var i = 0; i < 8; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: i < widget.dlc
                          ? const Color(0xFFD9F3E7)
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      hexStrs[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _byteCard(int byteIndex) {
    final byteVal = _trace.latestByte(byteIndex);
    final active = byteIndex < widget.dlc;
    final hex = byteVal == null ? '--' : byteVal.toRadixString(16).padLeft(2, '0').toUpperCase();
    final bin = byteVal == null ? '--------' : byteVal.toRadixString(2).padLeft(8, '0');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: active ? null : Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Byte $byteIndex',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  '0x$hex',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(width: 8),
                Text(
                  bin,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.black54,
                  ),
                ),
                const Spacer(),
                if (!active)
                  const Text(
                    'beyond DLC',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var bit = 7; bit >= 0; bit--) _bitRow(byteIndex, bit, byteVal),
          ],
        ),
      ),
    );
  }

  Widget _bitRow(int byteIndex, int bit, int? byteVal) {
    final bitVal = byteVal == null ? null : (byteVal >> bit) & 1;
    final accent = Theme.of(context).colorScheme.primary;

    return InkWell(
      onDoubleTap: () => _recordSignal(byteIndex, bit),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(
                'bit$bit',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bitVal == 1
                    ? const Color(0xFFFFD166)
                    : const Color(0xFFD9F3E7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                bitVal == null ? '·' : '$bitVal',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 28,
                child: CustomPaint(
                  painter: BitGraphPainter(
                    trace: _trace,
                    byteIndex: byteIndex,
                    bit: bit,
                    accent: accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Holds a short history of frame samples for a single CAN ID and exposes it
/// as a Listenable so [BitGraphPainter] can repaint on changes.
class BitTrace extends ChangeNotifier {
  BitTrace(this.canId, this.dlc);

  final int canId;
  final int dlc;

  /// (timestamp ms, copy of frame data).
  final List<({int t, List<int> data})> samples = [];

  static const int windowMs = 30000;
  // Hard cap to keep memory and per-paint work bounded even on chatty IDs
  // (e.g. a status frame at 100 Hz × 30 s = 3000 samples; we trim to this).
  static const int _maxSamples = 1500;

  int _nowMs = DateTime.now().millisecondsSinceEpoch;
  int get nowMs => _nowMs;
  int get sampleCount => samples.length;

  void addFrame(CanFrame f) {
    _nowMs = DateTime.now().millisecondsSinceEpoch;
    samples.add((t: f.timestampMs, data: List<int>.from(f.data)));
    _prune();
    notifyListeners();
  }

  void tick() {
    _nowMs = DateTime.now().millisecondsSinceEpoch;
    _prune();
    notifyListeners();
  }

  void _prune() {
    // Drop everything older than the visible window (plus a small grace
    // margin so the painter still has a "value at startMs" reference).
    final cutoff = _nowMs - windowMs - 1000;
    var dropTo = 0;
    while (dropTo < samples.length && samples[dropTo].t < cutoff) {
      dropTo++;
    }
    if (dropTo > 0) {
      samples.removeRange(0, dropTo);
    }
    // Hard cap fallback in case timestamps are out of order or pruning by
    // time alone leaves the list pathologically long.
    if (samples.length > _maxSamples) {
      samples.removeRange(0, samples.length - _maxSamples);
    }
  }

  int? latestByte(int byteIndex) {
    if (samples.isEmpty || byteIndex < 0 || byteIndex >= 8) return null;
    return samples.last.data[byteIndex];
  }

  List<int>? latestData() => samples.isEmpty ? null : samples.last.data;
}

class BitGraphPainter extends CustomPainter {
  BitGraphPainter({
    required this.trace,
    required this.byteIndex,
    required this.bit,
    required this.accent,
  }) : super(repaint: trace);

  final BitTrace trace;
  final int byteIndex;
  final int bit;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFF7F7F7);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );
    canvas.drawRRect(rrect, bg);

    final midline = Paint()
      ..color = Colors.black12
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      midline,
    );

    final samples = trace.samples;
    if (samples.isEmpty || byteIndex >= 8) return;

    final padY = 4.0;
    final yHigh = padY;
    final yLow = size.height - padY;
    final startMs = trace.nowMs - BitTrace.windowMs;

    double xOf(int t) {
      final clamped = t < startMs ? startMs : (t > trace.nowMs ? trace.nowMs : t);
      return ((clamped - startMs) / BitTrace.windowMs) * size.width;
    }

    // Establish the initial level: the most recent sample whose timestamp is
    // still before the visible window. Without this, the graph would start
    // blank until the first in-window sample arrives.
    double? lastY;
    for (final s in samples) {
      if (s.t >= startMs) break;
      if (s.data.length <= byteIndex) continue;
      final v = (s.data[byteIndex] >> bit) & 1;
      lastY = v == 1 ? yHigh : yLow;
    }

    final paint = Paint()
      ..color = accent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    if (lastY != null) {
      path.moveTo(0, lastY);
    }

    for (final s in samples) {
      if (s.t < startMs) continue;
      if (s.data.length <= byteIndex) continue;
      final x = xOf(s.t);
      final v = (s.data[byteIndex] >> bit) & 1;
      final y = v == 1 ? yHigh : yLow;
      if (lastY == null) {
        path.moveTo(x, y);
        lastY = y;
      } else if (y != lastY) {
        path.lineTo(x, lastY);
        path.lineTo(x, y);
        lastY = y;
      }
    }

    if (lastY != null) {
      path.lineTo(size.width, lastY);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Live "raw bytes → decoded value" preview for the Save Signal dialog.
/// Listens to the trace so it ticks at the same ~10 fps as the explorer
/// graphs, which lets the user dial in scale/offset while watching the
/// number snap to the value they expect on the dashboard.
class _SignalPreview extends StatelessWidget {
  const _SignalPreview({
    required this.trace,
    required this.group,
    required this.signed,
    required this.scaleText,
    required this.offsetText,
    required this.unit,
  });

  final BitTrace trace;
  final _ByteGroup group;
  final bool signed;
  final String scaleText;
  final String offsetText;
  final String unit;

  int _interpretRaw(int raw) {
    if (!signed) return raw;
    final bits = group.length * 8;
    if (bits <= 0 || bits >= 63) return raw;
    final signBit = 1 << (bits - 1);
    if ((raw & signBit) != 0) return raw - (1 << bits);
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: trace,
      builder: (_, __) {
        final latest = trace.latestData();
        final rawBytes = <int>[];
        if (latest != null) {
          for (var i = 0; i < group.length; i++) {
            final idx = group.startByte + i;
            if (idx < latest.length) rawBytes.add(latest[idx]);
          }
        }
        final raw = latest == null ? 0 : group.extract(latest);
        final asNumber = _interpretRaw(raw);
        final scale = double.tryParse(scaleText.trim()) ?? 1.0;
        final offset = double.tryParse(offsetText.trim()) ?? 0.0;
        final decoded = asNumber * scale + offset;
        final hexBytes = rawBytes
            .map((b) => '0x${b.toRadixString(16).padLeft(2, '0').toUpperCase()}')
            .join(' ');
        final unitStr = unit.trim();
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF7F2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                latest == null
                    ? 'Raw bytes: (waiting for data…)'
                    : 'Raw bytes: $hexBytes  (${group.littleEndian ? "LE" : "BE"})',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                'as ${signed ? "int" : "uint"}${group.length * 8}: $asNumber',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                'decoded: ${decoded.toStringAsFixed(decoded.abs() >= 100 ? 1 : 2)}'
                '${unitStr.isEmpty ? '' : ' $unitStr'}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Thin horizontal bar showing `value` as a fraction of `maxValue`. Used as
/// the at-a-glance "is this byte changing?" indicator in byte-value mode.
class _ValueBar extends StatelessWidget {
  const _ValueBar({
    required this.value,
    required this.maxValue,
    required this.accent,
  });

  final int value;
  final int maxValue;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ratio = maxValue == 0 ? 0.0 : (value / maxValue).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 8,
        child: Stack(
          children: [
            Container(color: const Color(0xFFEEEEEE)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio,
              child: Container(color: accent.withValues(alpha: 0.85)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 30s rolling line plot of an arbitrary [_ByteGroup]'s combined value. The
/// y-axis spans 0..maxValue of the group (so a single byte plots 0–255, a
/// 16-bit LE group plots 0–65535, etc.). Constants render as flat lines;
/// slow physical signals like coolant temp draw a clear curve.
class _ValueGraphPainter extends CustomPainter {
  _ValueGraphPainter({
    required this.trace,
    required this.group,
    required this.accent,
  }) : super(repaint: trace);

  final BitTrace trace;
  final _ByteGroup group;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFF7F7F7);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );
    canvas.drawRRect(rrect, bg);

    // Half-line and quarter-line guides — give the eye something to anchor on.
    final guide = Paint()
      ..color = Colors.black12
      ..strokeWidth = 0.4;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      guide,
    );
    canvas.drawLine(
      Offset(0, size.height / 4),
      Offset(size.width, size.height / 4),
      guide..color = Colors.black.withValues(alpha: 0.05),
    );
    canvas.drawLine(
      Offset(0, size.height * 3 / 4),
      Offset(size.width, size.height * 3 / 4),
      guide,
    );

    final samples = trace.samples;
    if (samples.isEmpty) return;

    final startMs = trace.nowMs - BitTrace.windowMs;
    final maxV = group.maxValue.toDouble();
    if (maxV <= 0) return;
    const padY = 3.0;
    final yTop = padY;
    final yBot = size.height - padY;

    double xOf(int t) {
      final clamped = t < startMs ? startMs : (t > trace.nowMs ? trace.nowMs : t);
      return ((clamped - startMs) / BitTrace.windowMs) * size.width;
    }

    double yOf(int v) =>
        yTop + (1 - (v.clamp(0, group.maxValue) / maxV)) * (yBot - yTop);

    final paint = Paint()
      ..color = accent
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    var started = false;
    for (final s in samples) {
      if (s.t < startMs) continue;
      if (s.data.length < group.startByte + group.length) continue;
      final x = xOf(s.t);
      final v = group.extract(s.data);
      final y = yOf(v);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    if (started) {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
