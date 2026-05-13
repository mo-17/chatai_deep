import 'package:flutter/material.dart';

class PhotoBgPainter extends CustomPainter {
  const PhotoBgPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Base linear gradient.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A1428), Color(0xFF1A1F3A)],
        ).createShader(rect),
    );

    // Soft radial glows (nebula-like).
    void glow(Offset center, Color color, double radius) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30)
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0.0, 0.55],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    glow(Offset(size.width * 0.20, size.height * 0.10),
        const Color(0xFF1A3358), size.width * 0.55);
    glow(Offset(size.width * 0.80, size.height * 0.30),
        const Color(0xFF3D2A5F), size.width * 0.60);
    glow(Offset(size.width * 0.60, size.height * 0.90),
        const Color(0xFF0D2540), size.width * 0.65);

    // Sprinkled stars.
    final starPaint = Paint()..color = Colors.white;
    for (var i = 0; i < 40; i++) {
      final x = (i * 37) % size.width.toInt();
      final y = (i * 73) % size.height.toInt();
      final r = ((i * 13) % 20) / 30 + 0.4;
      final opacity = 0.4 + (i % 5) * 0.12;
      starPaint.color = Colors.white.withValues(alpha: opacity);
      canvas.drawCircle(Offset(x.toDouble(), y.toDouble()), r, starPaint);
    }

    // Bottom darken overlay.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment(0, -0.4),
          end: Alignment.bottomCenter,
          colors: [Color(0x000A1428), Color(0x730A1428)],
          stops: [0.0, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant PhotoBgPainter oldDelegate) => false;
}
