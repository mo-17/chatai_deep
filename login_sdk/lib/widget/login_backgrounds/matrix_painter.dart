import 'package:flutter/material.dart';

class MatrixBgPainter extends CustomPainter {
  const MatrixBgPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFF020A06));

    const chars = '01アカサタナハマヤラワ\$#%&';
    final cols = (size.width / 24).floor();
    final rowH = size.height / 30; // 30 rows visible

    for (var col = 0; col < cols; col++) {
      final x = col * 24.0 + 6;
      final len = 8 + (col * 7) % 14;
      final startRow = -((col * 53) % 200) / 22.0;
      for (var i = 0; i < len; i++) {
        final y = (startRow + i) * 22.0 + rowH;
        if (y < -22 || y > size.height + 22) continue;
        final ch = chars[(col * 3 + i) % chars.length];
        final isHead = i == len - 1;
        final opacity =
            isHead ? 1.0 : (0.7 - i * 0.05).clamp(0.1, 1.0);
        final color = isHead
            ? const Color(0xFFD6FFE6)
            : const Color(0xFF00FF66);
        final tp = TextPainter(
          text: TextSpan(
            text: ch,
            style: TextStyle(
              color: color.withValues(alpha: opacity),
              fontSize: 14,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w500,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x, y));
      }
    }

    // Vignette.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.95,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
          stops: const [0.3, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant MatrixBgPainter oldDelegate) => false;
}
