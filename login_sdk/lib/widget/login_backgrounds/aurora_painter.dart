import 'dart:math';
import 'package:flutter/material.dart';

class AuroraBgPainter extends CustomPainter {
  final Color primaryColor;

  AuroraBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.srcOver);

    final colors = [
      primaryColor,
      const Color(0xFF7A5AE0),
      const Color(0xFF1F8A5B),
      const Color(0xFFD97757),
    ];

    final blurPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60);

    const angle = -22 * pi / 180;
    final bandWidth = size.height * 0.22;
    final spacing = size.height * 0.16;

    for (var i = 0; i < colors.length; i++) {
      final startY = size.height * 0.05 + i * (bandWidth + spacing);
      final rect = Rect.fromLTWH(-size.width * 0.3, startY,
          size.width * 1.6, bandWidth);

      canvas.save();
      canvas.translate(size.width / 2, startY + bandWidth / 2);
      canvas.rotate(angle);
      canvas.translate(-size.width / 2, -(startY + bandWidth / 2));

      blurPaint.color = colors[i].withValues(alpha: 0.30);
      canvas.drawRect(rect, blurPaint);

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant AuroraBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
