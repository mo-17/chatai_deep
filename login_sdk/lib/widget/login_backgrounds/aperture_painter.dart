import 'dart:math';

import 'package:flutter/material.dart';

class ApertureBgPainter extends CustomPainter {
  final Color primaryColor;

  const ApertureBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Dark backdrop with a warm/primary halo above-center.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.3),
          radius: 1.0,
          colors: [
            primaryColor.withValues(alpha: 0.33),
            primaryColor.withValues(alpha: 0.13),
            const Color(0xFF0A0E1A),
            const Color(0xFF060810),
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(rect),
    );

    // 16 radial light rays emanating downward from the "sun" pivot.
    final pivot = Offset(size.width / 2, size.height * 0.34);
    final rayPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.07)
      ..strokeWidth = 40
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < 16; i++) {
      final angle = (i / 16) * 2 * pi;
      canvas.save();
      canvas.translate(pivot.dx, pivot.dy);
      canvas.rotate(angle);
      canvas.drawLine(Offset.zero, const Offset(0, -460), rayPaint);
      canvas.restore();
    }

    // Center sun glow.
    final sunRect = Rect.fromCircle(center: pivot, radius: 60);
    canvas.drawCircle(
      pivot,
      60,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.8),
            primaryColor.withValues(alpha: 0.8),
            primaryColor.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.3, 0.7],
        ).createShader(sunRect),
    );

    // Horizon hairline at 38%.
    canvas.drawLine(
      Offset(0, size.height * 0.38),
      Offset(size.width, size.height * 0.38),
      Paint()..color = Colors.white.withValues(alpha: 0.25),
    );
  }

  @override
  bool shouldRepaint(covariant ApertureBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
