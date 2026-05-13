import 'package:flutter/material.dart';

class RetrowaveBgPainter extends CustomPainter {
  const RetrowaveBgPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    final sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.00, 0.35, 0.55, 0.65, 0.70, 1.00],
        colors: [
          Color(0xFF1A0A3A),
          Color(0xFF3D1259),
          Color(0xFF8B1A5F),
          Color(0xFFD63A85),
          Color(0xFF2A0A3F),
          Color(0xFF0A0420),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    // Stars in upper portion
    final starPaint = Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.8);
    for (var i = 0; i < 14; i++) {
      final x = (i * 31) % size.width.toInt();
      final y = (i * 53) % 120;
      canvas.drawCircle(Offset(x.toDouble(), y.toDouble()), 0.75, starPaint);
    }

    // Sun
    final sunSize = size.width * 0.50;
    final sunCenter = Offset(size.width / 2, size.height * 0.27);
    final sunRect = Rect.fromCircle(center: sunCenter, radius: sunSize / 2);
    canvas.drawCircle(
      sunCenter,
      sunSize / 2,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFD600), Color(0xFFFF6B9D), Color(0xFFC42B6F)],
          stops: [0.0, 0.5, 1.0],
        ).createShader(sunRect),
    );
    // Sun horizontal bars (darken lower half)
    final bar = Paint()..color = const Color(0xFF0A0420);
    final barLeft = sunCenter.dx - sunSize / 2;
    canvas.drawRect(Rect.fromLTWH(barLeft, sunCenter.dy + 6, sunSize, 4), bar);
    canvas.drawRect(Rect.fromLTWH(barLeft, sunCenter.dy + 24, sunSize, 3), bar);
    canvas.drawRect(Rect.fromLTWH(barLeft, sunCenter.dy + 38, sunSize, 2), bar);
    canvas.drawRect(Rect.fromLTWH(barLeft, sunCenter.dy + 50, sunSize, 2), bar);

    // Grid floor (bottom half perspective)
    final floorTop = size.height * 0.63;
    final gridPaint = Paint()
      ..color = const Color(0xFFFF6BFF)
      ..style = PaintingStyle.stroke;
    final horizonPaint = Paint()
      ..color = const Color(0xFFFF6BFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawLine(Offset(0, floorTop), Offset(size.width, floorTop), horizonPaint);
    final floorHeight = size.height - floorTop;
    const rows = 12;
    for (var i = 1; i <= rows; i++) {
      final tNorm = i / rows;
      // perspective: spacing grows quadratically
      final y = floorTop + floorHeight * (tNorm * tNorm);
      gridPaint
        ..strokeWidth = 0.6
        ..color = const Color(0xFFFF6BFF).withValues(alpha: (0.55 - i * 0.03).clamp(0.05, 1.0));
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final centerX = size.width / 2;
    for (var i = -7; i <= 7; i++) {
      final farX = centerX + i * 14;
      final nearX = centerX + i * 80;
      gridPaint
        ..strokeWidth = 0.6
        ..color = const Color(0xFFFF6BFF).withValues(alpha: 0.5);
      canvas.drawLine(Offset(farX, floorTop), Offset(nearX, size.height), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant RetrowaveBgPainter oldDelegate) => false;
}
