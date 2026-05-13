import 'package:flutter/material.dart';

class BandBgPainter extends CustomPainter {
  final Color primaryColor;

  const BandBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Colors.white);

    // Top colored band — full primary at top, fades to 80% at the bottom edge.
    final bandHeight = size.height * 0.42;
    final bandRect = Rect.fromLTWH(0, 0, size.width, bandHeight);
    canvas.drawRect(
      bandRect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.5, -1),
          end: const Alignment(0.5, 1),
          colors: [primaryColor, primaryColor.withValues(alpha: 0.80)],
        ).createShader(bandRect),
    );

    // Arc cutout below the band — convex curve into the white area so the
    // band edge feels like a printed badge.
    final arcTop = bandHeight - 16;
    final arc = Path()
      ..moveTo(0, arcTop)
      ..quadraticBezierTo(
          size.width * 0.25, arcTop - 60, size.width / 2, arcTop + 16)
      ..quadraticBezierTo(
          size.width * 0.75, arcTop + 70, size.width, arcTop)
      ..lineTo(size.width, bandHeight + 80)
      ..lineTo(0, bandHeight + 80)
      ..close();
    canvas.drawPath(arc, Paint()..color = Colors.white);

    // Outline rings on the right of the band.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(
      Offset(size.width - 40 + 80, size.height * 0.12 + 80),
      80,
      ringPaint..color = Colors.white.withValues(alpha: 0.25),
    );
    canvas.drawCircle(
      Offset(size.width - 80 + 110, size.height * 0.07 + 110),
      110,
      ringPaint..color = Colors.white.withValues(alpha: 0.15),
    );
  }

  @override
  bool shouldRepaint(covariant BandBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
