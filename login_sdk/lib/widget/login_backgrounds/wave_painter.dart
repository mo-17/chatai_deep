import 'package:flutter/material.dart';

class WaveBgPainter extends CustomPainter {
  final Color primaryColor;

  const WaveBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Bottom-tinted gradient backdrop.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, primaryColor.withValues(alpha: 0.06)],
        ).createShader(rect),
    );

    Offset p(double x, double y) =>
        Offset(x / 380 * size.width, y / 760 * size.height);

    // Big concentric rings near bottom-center.
    final mainCenter = p(190, 600);
    for (var i = 0; i < 14; i++) {
      final r = 60.0 + i * 40.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = primaryColor.withValues(
            alpha: (0.6 - i * 0.035).clamp(0.0, 1.0));
      canvas.drawCircle(
        Offset(mainCenter.dx, mainCenter.dy),
        r * (size.width / 380),
        paint,
      );
    }

    // Smaller dashed rings near top-left.
    final smallCenter = p(40, 100);
    for (var i = 0; i < 10; i++) {
      final r = (30.0 + i * 28.0) * (size.width / 380);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = primaryColor.withValues(
            alpha: (0.35 - i * 0.025).clamp(0.0, 1.0));
      _drawDashedCircle(canvas, smallCenter, r, dash: 2.5, gap: 3.5, paint: paint);
    }
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset center,
    double radius, {
    required double dash,
    required double gap,
    required Paint paint,
  }) {
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        final segEnd = (d + dash).clamp(0.0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(d, segEnd), paint);
        d = segEnd + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant WaveBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
