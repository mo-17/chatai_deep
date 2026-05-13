import 'package:flutter/material.dart';

class MarbleBgPainter extends CustomPainter {
  final Color primaryColor;

  const MarbleBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8F6F1), Color(0xFFECE5D8), Color(0xFFF0EBE0)],
          stops: [0.0, 0.5, 1.0],
        ).createShader(rect),
    );

    Offset p(double x, double y) =>
        Offset(x / 380 * size.width, y / 760 * size.height);

    void vein({
      required List<Offset> ctrl,
      required Color color,
      required double width,
      required double alpha,
    }) {
      // ctrl: list of (anchor, cp1, cp2, anchor, ...) for cubics.
      assert((ctrl.length - 1) % 3 == 0);
      final path = Path()..moveTo(ctrl.first.dx, ctrl.first.dy);
      for (var i = 1; i < ctrl.length; i += 3) {
        path.cubicTo(
          ctrl[i].dx, ctrl[i].dy,
          ctrl[i + 1].dx, ctrl[i + 1].dy,
          ctrl[i + 2].dx, ctrl[i + 2].dy,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = color.withValues(alpha: alpha),
      );
    }

    vein(
      ctrl: [p(-20, 120), p(80, 80), p(180, 140), p(280, 110), p(380, 90),
        p(440, 130), p(480, 150)],
      color: primaryColor,
      width: 0.8,
      alpha: 0.45,
    );
    vein(
      ctrl: [p(-20, 180), p(70, 200), p(160, 160), p(240, 200),
        p(320, 200), p(380, 170), p(420, 170)],
      color: primaryColor,
      width: 0.5,
      alpha: 0.30,
    );
    vein(
      ctrl: [p(-20, 380), p(100, 340), p(200, 420), p(300, 400),
        p(380, 380), p(400, 380), p(400, 380)],
      color: const Color(0xFF8A7060),
      width: 0.9,
      alpha: 0.40,
    );
    vein(
      ctrl: [p(-20, 600), p(120, 560), p(220, 620), p(320, 610),
        p(420, 600), p(420, 600), p(420, 600)],
      color: primaryColor,
      width: 0.7,
      alpha: 0.35,
    );
    vein(
      ctrl: [p(-20, 80), p(100, 60), p(200, 90), p(300, 80),
        p(400, 75), p(400, 75), p(400, 75)],
      color: const Color(0xFFA08070),
      width: 0.4,
      alpha: 0.30,
    );

    // Soft halos in corners.
    final hlPaint = Paint()..maskFilter =
        const MaskFilter.blur(BlurStyle.normal, 20);
    canvas.drawCircle(
      Offset(size.width * 0.9, size.height * 0.05),
      110,
      hlPaint..color = primaryColor.withValues(alpha: 0.12),
    );
    canvas.drawCircle(
      Offset(size.width * 0.05, size.height * 0.95),
      120,
      hlPaint..color = const Color(0xFFD4B896).withValues(alpha: 0.13),
    );
  }

  @override
  bool shouldRepaint(covariant MarbleBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
