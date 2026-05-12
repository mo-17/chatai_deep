import 'package:flutter/material.dart';

class BlueprintBgPainter extends CustomPainter {
  final Color primaryColor;

  BlueprintBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFFF4F7FC), BlendMode.srcOver);

    const gridSpacing = 24.0;
    final minorPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.16)
      ..strokeWidth = 1.2;

    // Vertical lines
    for (double x = 0; x <= size.width; x += gridSpacing) {
      final isMajor = (x / gridSpacing).round() % 5 == 0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          isMajor ? majorPaint : minorPaint);
    }

    // Horizontal lines
    for (double y = 0; y <= size.height; y += gridSpacing) {
      final isMajor = (y / gridSpacing).round() % 5 == 0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y),
          isMajor ? majorPaint : minorPaint);
    }

    // Circular blueprint scale at bottom-right
    final center = Offset(size.width * 0.85, size.height * 0.78);
    const scaleRadius = 140.0;
    final scalePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Concentric circles
    for (var r = 30.0; r <= scaleRadius; r += 30) {
      canvas.drawCircle(center, r, scalePaint);
    }

    // Crosshair lines
    canvas.drawLine(
      Offset(center.dx - scaleRadius, center.dy),
      Offset(center.dx + scaleRadius, center.dy),
      scalePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - scaleRadius),
      Offset(center.dx, center.dy + scaleRadius),
      scalePaint,
    );
  }

  @override
  bool shouldRepaint(covariant BlueprintBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
