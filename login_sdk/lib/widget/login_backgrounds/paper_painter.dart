import 'dart:math';

import 'package:flutter/material.dart';

class PaperBgPainter extends CustomPainter {
  const PaperBgPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFFF4EDE0));

    // Fiber noise: short rotated dashes
    final fiber = Paint()
      ..color = const Color(0xFF8A6D3B).withValues(alpha: 0.18)
      ..strokeWidth = 0.4
      ..style = PaintingStyle.stroke;
    final w = size.width.toInt();
    final h = size.height.toInt();
    for (var i = 0; i < 200; i++) {
      final x = (i * 47) % w;
      final y = (i * 91) % h;
      final len = 4 + (i % 6) * 2.0;
      final rot = ((i * 17) % 180) * pi / 180.0;
      canvas.save();
      canvas.translate(x.toDouble(), y.toDouble());
      canvas.rotate(rot);
      canvas.drawLine(Offset.zero, Offset(len, 0), fiber);
      canvas.restore();
    }

    // Horizontal rule
    canvas.drawLine(
      Offset(24, size.height * 0.27),
      Offset(size.width - 24, size.height * 0.27),
      Paint()..color = const Color(0xFF8A6D3B).withValues(alpha: 0.2),
    );

    // Red stamp circle in top-right, rotated -15°
    final stampCenter = Offset(size.width - 76, size.height * 0.09);
    canvas.save();
    canvas.translate(stampCenter.dx, stampCenter.dy);
    canvas.rotate(-15 * pi / 180);
    final stampOuter = Paint()
      ..color = const Color(0xFFB03030).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final stampInner = Paint()
      ..color = const Color(0xFFB03030).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(Offset.zero, 54, stampOuter);
    canvas.drawCircle(Offset.zero, 42, stampInner);
    _drawStampText(canvas, 'VERIFIED', 11, -10, FontWeight.w700);
    _drawStampText(canvas, 'SECURE · 2025', 9, 18, FontWeight.w500);
    canvas.restore();

    // Corner fold (bottom-left)
    final foldPath = Path()
      ..moveTo(0, size.height)
      ..lineTo(80, size.height)
      ..lineTo(0, size.height - 80)
      ..close();
    canvas.drawPath(foldPath, Paint()..color = const Color(0xFFE5DCC7));
    canvas.drawLine(
      Offset(0, size.height - 80),
      Offset(80, size.height),
      Paint()
        ..color = const Color(0xFFBFAE8C)
        ..strokeWidth = 0.6,
    );
  }

  void _drawStampText(Canvas canvas, String txt, double size, double dy,
      FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(
        text: txt,
        style: TextStyle(
          color: const Color(0xFFB03030).withValues(alpha: 0.6),
          fontSize: size,
          fontWeight: weight,
          letterSpacing: txt.length > 8 ? 2.0 : 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant PaperBgPainter oldDelegate) => false;
}
