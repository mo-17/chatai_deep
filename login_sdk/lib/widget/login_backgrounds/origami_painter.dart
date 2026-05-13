import 'package:flutter/material.dart';

class OrigamiBgPainter extends CustomPainter {
  final Color primaryColor;

  const OrigamiBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);

    Offset p(double x, double y) =>
        Offset(x / 380 * size.width, y / 760 * size.height);

    Paint fill(double alpha) =>
        Paint()..color = primaryColor.withValues(alpha: alpha);

    Path poly(List<Offset> pts) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      path.close();
      return path;
    }

    // Top cluster
    canvas.drawPath(poly([p(0, 0), p(200, 0), p(0, 260)]), fill(0.20));
    canvas.drawPath(poly([p(0, 0), p(200, 0), p(80, 180)]), fill(0.13));
    canvas.drawPath(
        poly([p(200, 0), p(380, 0), p(380, 200), p(280, 80)]), fill(0.27));
    canvas.drawPath(poly([p(380, 200), p(280, 80), p(380, 0)]), fill(0.12));

    // Bottom cluster
    canvas.drawPath(
        poly([p(0, 760), p(380, 760), p(380, 580), p(200, 640), p(0, 520)]),
        fill(0.12));
    canvas.drawPath(poly([p(0, 760), p(0, 640), p(200, 720)]), fill(0.20));
    canvas.drawPath(
        poly([p(380, 580), p(380, 760), p(200, 720), p(200, 640)]),
        fill(0.07));

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = primaryColor.withValues(alpha: 0.33);
    canvas.drawLine(p(0, 0), p(200, 0), line);
    canvas.drawLine(p(200, 0), p(0, 260), line);
    canvas.drawLine(p(200, 0), p(80, 180), line..strokeWidth = 0.5);
    canvas.drawLine(p(280, 80), p(380, 200), line);
    canvas.drawLine(p(200, 640), p(380, 580), line);
    canvas.drawLine(p(0, 640), p(200, 720), line);
  }

  @override
  bool shouldRepaint(covariant OrigamiBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
