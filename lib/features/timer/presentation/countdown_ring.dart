import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/domain/duration_format.dart';

/// A circular countdown showing the remaining rest time, draining clockwise as
/// the deadline approaches. [fraction] is remaining/total in 0..1.
class CountdownRing extends StatelessWidget {
  const CountdownRing({
    super.key,
    required this.remaining,
    required this.fraction,
    this.size = 56,
  });

  final Duration remaining;
  final double fraction;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = remaining <= Duration.zero;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: done ? 1 : fraction.clamp(0.0, 1.0),
          track: scheme.surfaceContainerHighest,
          progress: done ? scheme.primary : scheme.primary,
        ),
        child: Center(
          child: done
              ? Icon(Icons.check, color: scheme.primary, size: size * 0.4)
              : Text(
                  remaining.clockLabel,
                  style: TextStyle(
                    fontSize: size * 0.26,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurface,
                  ),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.track,
    required this.progress,
  });

  final double fraction;
  final Color track;
  final Color progress;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.1;
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2;
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = progress;

    canvas.drawCircle(center, radius, trackPaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.track != track ||
      old.progress != progress;
}
