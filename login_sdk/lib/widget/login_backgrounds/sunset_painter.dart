import 'package:flutter/material.dart';

class SunsetBgPainter extends CustomPainter {
  const SunsetBgPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    final sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.0, 0.25, 0.45, 0.70, 1.0],
        colors: [
          Color(0xFFFFB088),
          Color(0xFFFFCAA0),
          Color(0xFFFFE0B5),
          Color(0xFFF5C5D5),
          Color(0xFFC9A8D9),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    // Sun glow
    final sunCenter = Offset(size.width / 2, size.height * 0.18);
    final sunRect = Rect.fromCircle(center: sunCenter, radius: 60);
    final sunPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      ..shader = const RadialGradient(
        colors: [Color(0xFFFFF5C0), Color(0xFFFFC880), Color(0x00FFC880)],
        stops: [0.0, 0.6, 1.0],
      ).createShader(sunRect);
    canvas.drawCircle(sunCenter, 60, sunPaint);

    // Distant ridge
    final farRidgeHeight = size.height * 0.32;
    final farTop = size.height - farRidgeHeight;
    final farRidge = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, farTop + 40)
      ..lineTo(size.width * 0.10, farTop)
      ..lineTo(size.width * 0.21, farTop + 20)
      ..lineTo(size.width * 0.34, farTop - 40)
      ..lineTo(size.width * 0.45, farTop - 5)
      ..lineTo(size.width * 0.58, farTop - 55)
      ..lineTo(size.width * 0.71, farTop - 20)
      ..lineTo(size.width * 0.82, farTop - 60)
      ..lineTo(size.width * 0.92, farTop - 20)
      ..lineTo(size.width, farTop - 38)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
      farRidge,
      Paint()..color = const Color(0xFFA87FA5).withValues(alpha: 0.60),
    );

    // Near ridge
    final nearRidgeHeight = size.height * 0.20;
    final nearTop = size.height - nearRidgeHeight;
    final nearRidge = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, nearTop + 20)
      ..lineTo(size.width * 0.13, nearTop)
      ..lineTo(size.width * 0.26, nearTop + 20)
      ..lineTo(size.width * 0.39, nearTop - 10)
      ..lineTo(size.width * 0.52, nearTop + 15)
      ..lineTo(size.width * 0.66, nearTop - 12)
      ..lineTo(size.width * 0.79, nearTop + 12)
      ..lineTo(size.width * 0.92, nearTop - 10)
      ..lineTo(size.width, nearTop + 12)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
      nearRidge,
      Paint()..color = const Color(0xFF8A6090).withValues(alpha: 0.85),
    );

    // Birds
    final birdPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF5A3050).withValues(alpha: 0.5);
    _drawBird(canvas, Offset(size.width * 0.22, size.height * 0.12), 24, birdPaint);
    _drawBird(canvas, Offset(size.width * 0.65, size.height * 0.085), 20, birdPaint);
  }

  void _drawBird(Canvas canvas, Offset c, double w, Paint p) {
    final h = w * 0.4;
    final path = Path()
      ..moveTo(c.dx - w / 2, c.dy)
      ..quadraticBezierTo(c.dx - w / 4, c.dy - h, c.dx, c.dy)
      ..quadraticBezierTo(c.dx + w / 4, c.dy - h, c.dx + w / 2, c.dy);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant SunsetBgPainter oldDelegate) => false;
}
