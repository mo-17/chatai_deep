import 'package:flutter/material.dart';

class DotMapBgPainter extends CustomPainter {
  final Color primaryColor;

  const DotMapBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);

    // Center-weighted radial fade — dots fully colored near (50%, 40%) and
    // fade to transparent toward the edges.
    final fadeCenter = Offset(size.width * 0.5, size.height * 0.4);
    final fadeRadius = size.shortestSide * 0.85;

    const cols = 11;
    const rows = 19;
    final colStep = size.width / cols;
    final rowStep = size.height / rows;

    final paint = Paint();
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final cx = col * colStep + colStep / 2;
        final cy = row * rowStep + rowStep / 2;
        final r = 1.5 + ((row * 7 + col * 3) % 5) * 0.4;
        final dist = (Offset(cx, cy) - fadeCenter).distance;
        final t = (1 - dist / fadeRadius).clamp(0.0, 1.0);
        if (t == 0) continue;
        paint.color = primaryColor.withValues(alpha: 0.55 * t);
        canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant DotMapBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
