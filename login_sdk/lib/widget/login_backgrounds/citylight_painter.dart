import 'package:flutter/material.dart';

class CityLightBgPainter extends CustomPainter {
  final Color primaryColor;

  const CityLightBgPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Deep night sky gradient
    final sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.0, 0.4, 1.0],
        colors: [
          Color(0xFF1A0F25),
          Color(0xFF2A1535),
          Color(0xFF1A0A1F),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    // Glow halos
    final glow1Center = Offset(size.width * 0.08, size.height * 0.06);
    final glow1Rect = Rect.fromCircle(center: glow1Center, radius: 160);
    canvas.drawCircle(
      glow1Center,
      160,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24)
        ..shader = RadialGradient(
          colors: [
            primaryColor.withValues(alpha: 0.40),
            primaryColor.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.7],
        ).createShader(glow1Rect),
    );
    final glow2Center = Offset(size.width * 0.95, size.height * 0.18);
    final glow2Rect = Rect.fromCircle(center: glow2Center, radius: 160);
    canvas.drawCircle(
      glow2Center,
      160,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28)
        ..shader = const RadialGradient(
          colors: [Color(0x66FF6FA8), Color(0x00FF6FA8)],
          stops: [0.0, 0.7],
        ).createShader(glow2Rect),
    );

    // City skyline silhouette
    final skylineTop = size.height * 0.55;
    final skyline = Path()..moveTo(0, size.height);
    final stops = <List<double>>[
      [0.00, 0.78],
      [0.05, 0.78],
      [0.05, 0.73],
      [0.11, 0.73],
      [0.11, 0.75],
      [0.16, 0.75],
      [0.16, 0.68],
      [0.21, 0.68],
      [0.21, 0.72],
      [0.26, 0.72],
      [0.26, 0.62],
      [0.34, 0.62],
      [0.34, 0.68],
      [0.39, 0.68],
      [0.39, 0.65],
      [0.47, 0.65],
      [0.47, 0.60],
      [0.55, 0.60],
      [0.55, 0.66],
      [0.63, 0.66],
      [0.63, 0.62],
      [0.71, 0.62],
      [0.71, 0.70],
      [0.79, 0.70],
      [0.79, 0.66],
      [0.87, 0.66],
      [0.87, 0.72],
      [0.95, 0.72],
      [0.95, 0.68],
      [1.00, 0.68],
    ];
    skyline.lineTo(0, skylineTop);
    for (final s in stops) {
      skyline.lineTo(size.width * s[0], size.height * s[1]);
    }
    skyline.lineTo(size.width, size.height);
    skyline.close();
    canvas.drawPath(
      skyline,
      Paint()..color = const Color(0xFF0A0414).withValues(alpha: 0.9),
    );

    // Windows
    final windowPaint = Paint()..color = const Color(0xFFFFD080);
    for (var i = 0; i < 60; i++) {
      final x = (i * 23) % size.width.toInt();
      final y = size.height * 0.62 + ((i * 17) % 180);
      final opacity = 0.4 + (i % 4) * 0.15;
      windowPaint.color = const Color(0xFFFFD080).withValues(alpha: opacity);
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), y, 2, 3),
        windowPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CityLightBgPainter oldDelegate) =>
      oldDelegate.primaryColor != primaryColor;
}
