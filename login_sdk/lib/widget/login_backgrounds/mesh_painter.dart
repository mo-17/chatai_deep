import 'package:flutter/material.dart';

class MeshBgPainter extends CustomPainter {
  final Color primaryColor;

  MeshBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.white, BlendMode.srcOver);

    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 90);

    // Circle 1: top-left
    paint.color = primaryColor.withValues(alpha: 0.45);
    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.20),
      size.width * 0.55,
      paint,
    );

    // Circle 2: top-right (warm yellow)
    paint.color = const Color(0xFFFFC857).withValues(alpha: 0.38);
    canvas.drawCircle(
      Offset(size.width * 0.85, size.height * 0.10),
      size.width * 0.45,
      paint,
    );

    // Circle 3: bottom (pink)
    paint.color = const Color(0xFFFF6B9D).withValues(alpha: 0.32);
    canvas.drawCircle(
      Offset(size.width * 0.50, size.height * 0.85),
      size.width * 0.65,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant MeshBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
