import 'package:flutter/material.dart';

class RibbonBgPainter extends CustomPainter {
  final Color primaryColor;

  const RibbonBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.white,
    );

    // Helpers — scale design coords (380x760) → real size
    Offset p(double x, double y) =>
        Offset(x / 380 * size.width, y / 760 * size.height);

    // Top floating circles
    canvas.drawCircle(
      p(320, 120),
      48,
      Paint()..color = primaryColor.withValues(alpha: 0.12),
    );
    canvas.drawCircle(
      p(60, 80),
      28,
      Paint()..color = primaryColor.withValues(alpha: 0.20),
    );

    // Bottom ribbon waves
    void ribbon(double y1, double y2, double y3, double y4, double alpha) {
      final path = Path()
        ..moveTo(p(-20, y1).dx, p(-20, y1).dy)
        ..cubicTo(p(80, y2).dx, p(80, y2).dy, p(180, y3).dx, p(180, y3).dy,
            p(280, y4).dx, p(280, y4).dy)
        ..cubicTo(p(360, y3 - 30).dx, p(360, y3 - 30).dy, p(420, y1).dx,
            p(420, y1).dy, p(420, size.height).dx, p(420, size.height).dy)
        ..lineTo(p(420, size.height).dx, size.height)
        ..lineTo(p(-20, size.height).dx, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()..color = primaryColor.withValues(alpha: alpha),
      );
    }

    ribbon(520, 470, 600, 540, 0.15);
    ribbon(580, 540, 660, 600, 0.25);
    ribbon(650, 620, 720, 660, 0.40);
  }

  @override
  bool shouldRepaint(covariant RibbonBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
