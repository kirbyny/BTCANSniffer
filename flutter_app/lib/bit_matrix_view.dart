import 'package:flutter/material.dart';

import 'bit_explorer_screen.dart' show BitTrace;

/// Condensed "barcode" view of every bit of every observed CAN ID over the
/// rolling 30s window. Each row is one ID; within the row, 64 stacked lanes
/// (8 bytes × 8 bits, MSB on top). Each lane fills only the time ranges
/// when the bit is 1 — a constant 0 looks empty, a constant 1 looks solid,
/// and oscillating bits look like ticks.
///
/// Wrapped in [InteractiveViewer] so a pinch zooms in on specific IDs/bytes
/// without changing the painted resolution; zoom all the way out to see
/// every observed ID at once.
class BitMatrixView extends StatelessWidget {
  const BitMatrixView({
    super.key,
    required this.tracesById,
    required this.windowMs,
  });

  final Map<int, BitTrace> tracesById;
  final int windowMs;

  @override
  Widget build(BuildContext context) {
    if (tracesById.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No frames yet. Start monitoring to populate the matrix.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final accent = Theme.of(context).colorScheme.primary;
    final labelStyle = const TextStyle(
      fontFamily: 'monospace',
      fontSize: 10,
      color: Colors.black87,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              return InteractiveViewer(
                minScale: 1.0,
                // Cap maxScale at 6×. Going higher pushes the rasterized layer
                // past Skia texture limits on some OEM ROMs and the OS kills
                // the process during a pan.
                maxScale: 6.0,
                constrained: true,
                boundaryMargin: EdgeInsets.zero,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _BitMatrixPainter(
                        tracesById: tracesById,
                        windowMs: windowMs,
                        accent: accent,
                        labelStyle: labelStyle,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const Positioned(
          right: 8,
          top: 8,
          child: _HintChip(text: 'Pinch to zoom'),
        ),
      ],
    );
  }
}

class _HintChip extends StatelessWidget {
  const _HintChip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

class _BitMatrixPainter extends CustomPainter {
  _BitMatrixPainter({
    required this.tracesById,
    required this.windowMs,
    required this.accent,
    required this.labelStyle,
  });

  final Map<int, BitTrace> tracesById;
  final int windowMs;
  final Color accent;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final ids = tracesById.keys.toList()..sort();
    if (ids.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startMs = nowMs - windowMs;
    final stripH = size.height / ids.length;

    // Skip drawing entirely when strips would be visually invisible — at
    // that density the user can't see anything meaningful anyway, and
    // pushing tens of thousands of subpixel rects into the layer is what
    // was killing the rasterizer.
    if (stripH < 1.0) return;

    final showLabel = stripH >= 14;
    const labelColumnWidth = 60.0;
    final laneAreaLeft = showLabel ? labelColumnWidth : 0.0;
    final laneAreaWidth = size.width - laneAreaLeft;
    final laneH = stripH / 64;

    // Level of detail. Draw the full per-bit grid only when each lane has at
    // least 1px of vertical space; otherwise collapse the strip to a single
    // "activity" bar.
    final highDetail = laneH >= 1.0;

    final activeFill = Paint()..color = accent.withValues(alpha: 0.85);
    final dividerStrong = Paint()
      ..color = Colors.black26
      ..strokeWidth = 0.6;
    final dividerWeak = Paint()
      ..color = Colors.black12
      ..strokeWidth = 0.3;
    final byteBoundary = Paint()
      ..color = Colors.black.withValues(alpha: 0.15)
      ..strokeWidth = 0.3;

    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final trace = tracesById[id]!;
      final yTop = i * stripH;

      if (i.isOdd) {
        canvas.drawRect(
          Rect.fromLTWH(0, yTop, size.width, stripH),
          Paint()..color = const Color(0x10000000),
        );
      }

      if (i > 0 && stripH >= 2) {
        canvas.drawLine(Offset(0, yTop), Offset(size.width, yTop), dividerStrong);
      }

      if (showLabel) {
        final idHex = _formatId(id, trace.dlc);
        final tp = TextPainter(
          text: TextSpan(text: idHex, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: labelColumnWidth - 6);
        tp.paint(canvas, Offset(4, yTop + (stripH - tp.height) / 2));
      }

      if (!highDetail) {
        // Low-detail mode: paint one bar per ID showing any-bit-set activity
        // over time.
        _paintActivityBar(
          canvas,
          trace,
          laneAreaLeft,
          yTop,
          laneAreaWidth,
          stripH,
          startMs,
          nowMs,
          activeFill,
        );
        continue;
      }

      if (stripH > 8) {
        for (var b = 1; b < 8; b++) {
          final y = yTop + b * 8 * laneH;
          canvas.drawLine(
            Offset(laneAreaLeft, y),
            Offset(size.width, y),
            byteBoundary,
          );
        }
      }

      for (var byteIdx = 0; byteIdx < 8; byteIdx++) {
        for (var bit = 7; bit >= 0; bit--) {
          final laneIndex = byteIdx * 8 + (7 - bit);
          final laneY = yTop + laneIndex * laneH;
          _paintLane(
            canvas,
            trace,
            byteIdx,
            bit,
            laneAreaLeft,
            laneY,
            laneAreaWidth,
            laneH,
            startMs,
            nowMs,
            activeFill,
          );
          if (laneH > 6) {
            canvas.drawLine(
              Offset(laneAreaLeft, laneY),
              Offset(size.width, laneY),
              dividerWeak,
            );
          }
        }
      }
    }
  }

  /// At zoomed-out density per-bit lanes collapse below 1px so we'd be
  /// emitting tens of thousands of invisible rects. Instead, fill the strip
  /// over any time-window where ≥1 bit of the frame data was non-zero —
  /// gives a useful "is this ID alive" signal at a fraction of the cost.
  void _paintActivityBar(
    Canvas canvas,
    BitTrace trace,
    double laneX,
    double laneY,
    double laneW,
    double laneH,
    int startMs,
    int nowMs,
    Paint activeFill,
  ) {
    final samples = trace.samples;
    if (samples.isEmpty) return;

    double xOf(int t) {
      final clamped = t < startMs ? startMs : (t > nowMs ? nowMs : t);
      return laneX + ((clamped - startMs) / windowMs) * laneW;
    }

    bool? lastActive;
    double lastX = laneX;

    // Initial level from sample most recently before the window.
    for (final s in samples) {
      if (s.t >= startMs) break;
      lastActive = _anyByteNonZero(s.data);
    }

    for (final s in samples) {
      if (s.t < startMs) continue;
      final x = xOf(s.t);
      final v = _anyByteNonZero(s.data);
      if (lastActive == true && x > lastX) {
        canvas.drawRect(Rect.fromLTWH(lastX, laneY, x - lastX, laneH), activeFill);
      }
      lastActive = v;
      lastX = x;
    }
    if (lastActive == true) {
      final endX = laneX + laneW;
      if (endX > lastX) {
        canvas.drawRect(Rect.fromLTWH(lastX, laneY, endX - lastX, laneH), activeFill);
      }
    }
  }

  static bool _anyByteNonZero(List<int> data) {
    for (final b in data) {
      if (b != 0) return true;
    }
    return false;
  }

  String _formatId(int id, int dlc) {
    final hex = id.toRadixString(16).toUpperCase();
    return hex.padLeft(id > 0x7FF ? 8 : 3, '0');
  }

  /// Fills the lane rectangle with [activeFill] over time ranges where the
  /// bit is 1. Cheap: at most one rect per "high" interval.
  void _paintLane(
    Canvas canvas,
    BitTrace trace,
    int byteIdx,
    int bit,
    double laneX,
    double laneY,
    double laneW,
    double laneH,
    int startMs,
    int nowMs,
    Paint activeFill,
  ) {
    final samples = trace.samples;
    if (samples.isEmpty) return;
    if (byteIdx >= 8) return;

    double xOf(int t) {
      final clamped = t < startMs ? startMs : (t > nowMs ? nowMs : t);
      return laneX + ((clamped - startMs) / windowMs) * laneW;
    }

    int? lastVal;
    double lastX = laneX;

    // Initial level: most recent sample before the window.
    for (final s in samples) {
      if (s.t >= startMs) break;
      if (s.data.length <= byteIdx) continue;
      lastVal = (s.data[byteIdx] >> bit) & 1;
    }

    for (final s in samples) {
      if (s.t < startMs) continue;
      if (s.data.length <= byteIdx) continue;
      final x = xOf(s.t);
      final v = (s.data[byteIdx] >> bit) & 1;
      if (lastVal == 1 && x > lastX) {
        canvas.drawRect(Rect.fromLTWH(lastX, laneY, x - lastX, laneH), activeFill);
      }
      lastVal = v;
      lastX = x;
    }
    // Trail to "now"
    if (lastVal == 1) {
      final endX = laneX + laneW;
      if (endX > lastX) {
        canvas.drawRect(Rect.fromLTWH(lastX, laneY, endX - lastX, laneH), activeFill);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BitMatrixPainter old) =>
      old.tracesById != tracesById || old.windowMs != windowMs;
}
