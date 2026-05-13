import 'package:flutter/material.dart';

class TopoBgPainter extends CustomPainter {
  final Color primaryColor;

  const TopoBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.white,
    );

    Offset p(double x, double y) =>
        Offset(x / 380 * size.width, y / 760 * size.height);

    void contour({
      required double y0,
      required double y1,
      required double y2,
      required double y3,
      required bool emphasized,
    }) {
      final path = Path()
        ..moveTo(p(-20, y0).dx, p(-20, y0).dy)
        ..cubicTo(
          p(60, y1).dx, p(60, y1).dy,
          p(140, y2).dx, p(140, y2).dy,
          p(220, y3).dx, p(220, y3).dy,
        )
        ..cubicTo(
          p(300, y1).dx, p(300, y1).dy,
          p(380, y0 - 30).dx, p(380, y0 - 30).dy,
          p(420, y0 + 10).dx, p(420, y0 + 10).dy,
        );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = primaryColor.withValues(alpha: emphasized ? 0.55 : 0.30)
        ..strokeWidth = emphasized ? 1.0 : 0.5;
      canvas.drawPath(path, paint);
    }

    // Upper cluster
    for (var i = 0; i < 18; i++) {
      final off = i * 12.0;
      contour(
        y0: 140 + off,
        y1: 100 + off,
        y2: 180 + off,
        y3: 130 + off,
        emphasized: i % 5 == 0,
      );
    }

    // Lower cluster
    for (var i = 0; i < 12; i++) {
      final off = i * 14.0;
      contour(
        y0: 480 + off,
        y1: 440 + off,
        y2: 520 + off,
        y3: 470 + off,
        emphasized: i % 4 == 0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TopoBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
