import 'dart:math';

import 'package:flutter/material.dart';

class DuotoneBgPainter extends CustomPainter {
  final Color primaryColor;

  const DuotoneBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = primaryColor);

    // Diagonal split — dark slab covers ~55% from upper-right downward.
    final diagonal = Path()
      ..moveTo(size.width * 0.45, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width * 0.45 + size.height * 0.6, size.height)
      ..close();
    canvas.drawPath(diagonal, Paint()..color = const Color(0xFF111315));

    // Big yellow circle (top-right).
    canvas.drawCircle(
      Offset(size.width * 0.95, size.height * 0.05),
      120,
      Paint()..color = const Color(0xFFFFE066),
    );
    // Small pink circle (mid-left).
    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.32),
      30,
      Paint()..color = const Color(0xFFFF6FA8),
    );

    // Diagonal stripes (bottom-left).
    canvas.save();
    canvas.translate(0, size.height * 0.78);
    canvas.rotate(-15 * pi / 180);
    canvas.drawRect(
      const Rect.fromLTWH(-20, 0, 220, 8),
      Paint()..color = const Color(0xFFFFE066),
    );
    canvas.drawRect(
      const Rect.fromLTWH(-20, 20, 220, 8),
      Paint()..color = const Color(0xFFFF6FA8),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DuotoneBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
