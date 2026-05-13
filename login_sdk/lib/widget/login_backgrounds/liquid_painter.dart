import 'package:flutter/material.dart';

class LiquidBgPainter extends CustomPainter {
  final Color primaryColor;

  const LiquidBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Conic-ish gradient via SweepGradient centered slightly below middle
    final swirlCenter = Offset(size.width * 0.5, size.height * 0.6);
    final swirlRect = Rect.fromCircle(
      center: swirlCenter,
      radius: size.longestSide,
    );
    final swirlPaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30)
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: 0,
        endAngle: 6.2831853,
        transform: const GradientRotation(3.14159), // start from bottom
        colors: [
          primaryColor,
          const Color(0xFF4A3A8F),
          const Color(0xFF1A2540),
          primaryColor,
          const Color(0xFFC8B5FF),
          const Color(0xFF2A3560),
          primaryColor,
        ],
        stops: const [0.0, 0.17, 0.33, 0.50, 0.67, 0.83, 1.0],
      ).createShader(swirlRect);
    canvas.drawRect(rect, swirlPaint);

    // Highlight (top-right)
    final hl = Offset(size.width * 0.7, size.height * 0.2);
    canvas.drawCircle(
      hl,
      size.width * 0.45,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40)
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFFFFFF).withValues(alpha: 0.35),
            const Color(0xFFFFFFFF).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.6],
        ).createShader(Rect.fromCircle(center: hl, radius: size.width * 0.45)),
    );

    // Shadow pocket (bottom-left)
    final sh = Offset(size.width * 0.2, size.height * 0.82);
    canvas.drawCircle(
      sh,
      size.width * 0.5,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40)
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF000000).withValues(alpha: 0.40),
            const Color(0xFF000000).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.7],
        ).createShader(Rect.fromCircle(center: sh, radius: size.width * 0.5)),
    );

    // Overall dim to keep glass cards readable
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x26000000), Color(0x59000000)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant LiquidBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
