import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'sniffer_log.dart';
import 'sniffer_log_screen.dart';
import 'vlinker.dart';

class BitExplorerScreen extends StatefulWidget {
  const BitExplorerScreen({
    super.key,
    required this.link,
    required this.canId,
    required this.canIdHex,
    required this.dlc,
    this.existingTrace,
  });

  final VlinkerConnection link;
  final int canId;
  final String canIdHex;
  final int dlc;

  /// When the home screen already maintains a shared trace for this ID
  /// (it does, to feed the matrix view), reuse it so we don't double-buffer
  /// samples and double-subscribe to the frame stream.
  final BitTrace? existingTrace;

  @override
  State<BitExplorerScreen> createState() => _BitExplorerScreenState();
}

class _BitExplorerScreenState extends State<BitExplorerScreen> {
  late final BitTrace _trace;
  late final bool _ownTrace;
  StreamSubscription<CanFrame>? _frameSub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (widget.existingTrace != null) {
      _trace = widget.existingTrace!;
      _ownTrace = false;
    } else {
      _trace = BitTrace(widget.canId, widget.dlc);
      _ownTrace = true;
      _frameSub = widget.link.frames
          .where((f) => f.id == widget.canId)
          .listen(_trace.addFrame);
    }
    // Advance the "now" cursor (and prune) at ~10 fps even when no frames
    // arrive, so the rolling window keeps scrolling.
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) _trace.tick();
    });
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _ticker?.cancel();
    if (_ownTrace) {
      _trace.dispose();
    }
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
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.canIdHex} · bit explorer'),
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
      body: AnimatedBuilder(
        animation: _trace,
        builder: (_, __) {
          return Column(
            children: [
              _headerBar(),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: 8,
                  itemBuilder: (_, byteIndex) => _byteCard(byteIndex),
                ),
              ),
            ],
          );
        },
      ),
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
          const SizedBox(width: 8),
          Text(
            '${_trace.sampleCount} samples',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
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
