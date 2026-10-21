import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 主题套装的原创矢量装饰；几何按尺寸重绘，正文和头像始终有独立留白。
enum ChatOrnament { constellation, blossom, ribbon, mecha }

abstract final class ChatOrnaments {
  static Color accent(ChatOrnament theme, {bool dark = false}) =>
      switch (theme) {
        ChatOrnament.constellation =>
          dark ? const Color(0xFFBDB0FF) : const Color(0xFF8670CD),
        ChatOrnament.blossom =>
          dark ? const Color(0xFFFFB3CC) : const Color(0xFFD26B93),
        ChatOrnament.ribbon =>
          dark ? const Color(0xFFFFD299) : const Color(0xFFC38A50),
        ChatOrnament.mecha =>
          dark ? const Color(0xFF75E2D6) : const Color(0xFF247E86),
      };

  static void frame(
      Canvas canvas, Size size, ChatOrnament theme, Brightness brightness) {
    final unit = size.shortestSide;
    final center = size.center(Offset.zero);
    final ink = accent(theme, dark: brightness == Brightness.dark);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(center.dx - unit / 2, center.dy - unit / 2);
    canvas.scale(unit);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .035;
    final colors = switch (theme) {
      ChatOrnament.constellation => const [
          Color(0xFFC7ADFF),
          Color(0xFF7B96DD),
          Color(0xFFF1D59F)
        ],
      ChatOrnament.blossom => const [
          Color(0xFFF7BAD0),
          Color(0xFFD684AC),
          Color(0xFFF5D8DD)
        ],
      ChatOrnament.ribbon => const [
          Color(0xFFF8DBA7),
          Color(0xFFE7A0A7),
          Color(0xFFFFE7BD)
        ],
      ChatOrnament.mecha => const [
          Color(0xFF87F3E2),
          Color(0xFF5995C8),
          Color(0xFFC7FFFF)
        ],
    };
    paint
      ..strokeWidth = .065
      ..shader = LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight)
          .createShader(const Rect.fromLTWH(0, 0, 1, 1));
    if (theme == ChatOrnament.mecha) {
      final outer = _polygon(const Offset(.5, .5), .405, 6, -math.pi / 2);
      canvas.drawPath(
          outer,
          Paint()
            ..color = const Color(0xFF223449)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .12);
      canvas.drawPath(outer, paint..strokeWidth = .035);
      canvas.drawPath(
          _polygon(const Offset(.5, .5), .355, 6, -math.pi / 2),
          Paint()
            ..color = const Color(0xFF9BEDE0)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .012);
      for (final flip in [false, true]) {
        canvas.save();
        if (flip) {
          canvas.translate(1, 0);
          canvas.scale(-1, 1);
        }
        final wing = Path()
          ..moveTo(.035, .36)
          ..lineTo(.16, .40)
          ..lineTo(.18, .62)
          ..lineTo(.065, .70)
          ..lineTo(.09, .53)
          ..close();
        canvas.drawPath(wing, Paint()..color = const Color(0xFF579AAB));
        canvas.drawLine(
            const Offset(.07, .42),
            const Offset(.115, .59),
            Paint()
              ..color = const Color(0xFFB3FFF1)
              ..strokeWidth = .018);
        canvas.restore();
      }
      _gem(canvas, const Offset(.5, .10), .09, const Color(0xFF91F1DD));
      _gem(canvas, const Offset(.5, .90), .075, const Color(0xFF75B8F2));
    } else {
      canvas.drawCircle(const Offset(.5, .5), .39, paint);
      canvas.drawCircle(
          const Offset(.5, .5),
          .34,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = .012
            ..color = ink.withValues(alpha: .65));
      switch (theme) {
        case ChatOrnament.constellation:
          for (final flip in [false, true]) {
            canvas.save();
            if (flip) {
              canvas.translate(1, 0);
              canvas.scale(-1, 1);
            }
            final wing = Path()
              ..moveTo(.07, .60)
              ..quadraticBezierTo(.18, .62, .26, .76)
              ..quadraticBezierTo(.12, .77, .045, .67)
              ..lineTo(.13, .69)
              ..close();
            canvas.drawPath(wing, Paint()..color = const Color(0xFFB6A8E5));
            canvas.drawLine(
                const Offset(.08, .66),
                const Offset(.20, .73),
                Paint()
                  ..color = const Color(0xFFF9E3AF)
                  ..strokeWidth = .012);
            canvas.restore();
          }
          _star(canvas, const Offset(.75, .17), .13, const Color(0xFFF4D293));
          _star(canvas, const Offset(.18, .28), .075, const Color(0xFFBEA4F3));
          _gem(canvas, const Offset(.5, .88), .095, const Color(0xFFC0AFF1));
          _spark(canvas, const Offset(.87, .41), .055, Colors.white);
        case ChatOrnament.blossom:
          _leaf(canvas, const Offset(.80, .28), .13, -.7);
          _leaf(canvas, const Offset(.20, .73), .12, 1.9);
          _flower(canvas, const Offset(.77, .21), .13);
          _flower(canvas, const Offset(.88, .34), .075);
          _flower(canvas, const Offset(.21, .79), .12);
          _flower(canvas, const Offset(.10, .64), .065);
          _spark(canvas, const Offset(.34, .13), .045, const Color(0xFFFFE8A6));
        case ChatOrnament.ribbon:
          _bow(canvas, const Offset(.5, .14), .26);
          _heart(canvas, const Offset(.5, .86), .15, const Color(0xFFDEA2A2));
          _spark(canvas, const Offset(.17, .41), .05, const Color(0xFFFFE2A2));
          _spark(canvas, const Offset(.84, .61), .045, const Color(0xFFFFE2A2));
          for (final x in [.17, .83]) {
            canvas.drawCircle(
                Offset(x, .67), .025, Paint()..color = const Color(0xFFFDEBD0));
          }
        case ChatOrnament.mecha:
          break;
      }
    }
    canvas.restore();
  }

  static void bubble(Canvas canvas, Size size, ChatOrnament theme, bool isUser,
      Color background) {
    final w = size.width;
    final h = size.height;
    final ink = accent(theme, dark: background.computeLuminance() <= .179);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // 装饰只落在 26 / 22 像素的上下留白，不穿过正文。
    switch (theme) {
      case ChatOrnament.constellation:
        final line = Paint()
          ..color = ink.withValues(alpha: .45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8;
        final constellation = Path()
          ..moveTo(w - 52, 13)
          ..lineTo(w - 32, 8)
          ..lineTo(w - 14, 17);
        canvas.drawPath(constellation, line);
        _star(canvas, Offset(w - 32, 9), 7, const Color(0xFFDFC084));
        _star(canvas, Offset(w - 13, 16), 4, ink);
        _spark(canvas, const Offset(14, 14), 5, ink);
        canvas.drawOval(
            Rect.fromCenter(center: Offset(28, h - 9), width: 34, height: 7),
            line);
        canvas.drawCircle(Offset(14, h - 9), 2.5, Paint()..color = ink);
        _spark(canvas, Offset(w - 15, h - 10), 4, ink);
      case ChatOrnament.blossom:
        _leaf(canvas, Offset(w - 31, 12), 9, .4);
        _flower(canvas, Offset(w - 17, 13), 8);
        _flower(canvas, Offset(w - 34, 18), 4.5);
        _flower(canvas, Offset(16, h - 11), 6);
        _leaf(canvas, Offset(30, h - 10), 8, 2);
        canvas.drawLine(
            const Offset(12, 13),
            Offset(math.min(43, w * .4), 13),
            Paint()
              ..color = ink.withValues(alpha: .45)
              ..strokeWidth = .8);
      case ChatOrnament.ribbon:
        _bow(canvas, Offset(w - 25, 13), 13);
        _heart(canvas, const Offset(17, 13), 8, ink.withValues(alpha: .75));
        final ribbon = Path()
          ..moveTo(10, h - 13)
          ..quadraticBezierTo(27, h - 3, 48, h - 10)
          ..lineTo(44, h - 5)
          ..quadraticBezierTo(23, h, 10, h - 9)
          ..close();
        canvas.drawPath(ribbon, Paint()..color = ink.withValues(alpha: .35));
        _spark(canvas, Offset(w - 15, h - 10), 4, ink);
      case ChatOrnament.mecha:
        final paint = Paint()
          ..color = ink
          ..strokeWidth = 1.3
          ..style = PaintingStyle.stroke;
        canvas.drawPath(
            Path()
              ..moveTo(8, 21)
              ..lineTo(16, 8)
              ..lineTo(math.min(66, w * .55), 8)
              ..lineTo(math.min(72, w * .62), 13),
            paint);
        canvas.drawPath(
            Path()
              ..moveTo(w - 9, h - 20)
              ..lineTo(w - 16, h - 9)
              ..lineTo(w - math.min(53, w * .45), h - 9),
            paint);
        _gem(canvas, Offset(w - 17, 14), 6, ink);
        for (var i = 0; i < 3; i++) {
          canvas.drawLine(Offset(15 + i * 5, h - 11),
              Offset(18 + i * 5, h - 15), paint..strokeWidth = 1);
        }
    }
    canvas.restore();
  }

  static Path _polygon(
      Offset center, double radius, int points, double rotation) {
    final path = Path();
    for (var i = 0; i < points; i++) {
      final angle = rotation + i * math.pi * 2 / points;
      final p = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  static void _star(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final p = center +
          Offset(math.cos(angle), math.sin(angle)) *
              radius *
              (i.isEven ? 1 : .46);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  static void _spark(Canvas canvas, Offset p, double r, Color color) {
    canvas.drawPath(
        Path()
          ..moveTo(p.dx, p.dy - r)
          ..quadraticBezierTo(p.dx + r * .2, p.dy - r * .2, p.dx + r, p.dy)
          ..quadraticBezierTo(p.dx + r * .2, p.dy + r * .2, p.dx, p.dy + r)
          ..quadraticBezierTo(p.dx - r * .2, p.dy + r * .2, p.dx - r, p.dy)
          ..quadraticBezierTo(p.dx - r * .2, p.dy - r * .2, p.dx, p.dy - r)
          ..close(),
        Paint()..color = color);
  }

  static void _flower(Canvas canvas, Offset p, double r) {
    for (var i = 0; i < 5; i++) {
      final angle = i * math.pi * 2 / 5 - math.pi / 2;
      final petal = p + Offset(math.cos(angle), math.sin(angle)) * r * .48;
      canvas.drawCircle(
          petal,
          r * .48,
          Paint()
            ..shader = const RadialGradient(
                    colors: [Color(0xFFFFF2F5), Color(0xFFE8A0BA)])
                .createShader(Rect.fromCircle(center: petal, radius: r * .48)));
    }
    canvas.drawCircle(p, r * .20, Paint()..color = const Color(0xFFE7BD72));
  }

  static void _leaf(Canvas canvas, Offset p, double r, double rotation) {
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(rotation);
    final path = Path()
      ..moveTo(-r, 0)
      ..quadraticBezierTo(0, -r * .7, r, 0)
      ..quadraticBezierTo(0, r * .45, -r, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF7DAA98));
    canvas.drawLine(
        Offset(-r * .6, 0),
        Offset(r * .6, 0),
        Paint()
          ..color = const Color(0xFFD5E7CE)
          ..strokeWidth = r * .07);
    canvas.restore();
  }

  static void _heart(Canvas canvas, Offset p, double r, Color color) {
    final path = Path()
      ..moveTo(p.dx, p.dy + r * .7)
      ..cubicTo(
          p.dx - r * 1.2, p.dy, p.dx - r * .8, p.dy - r, p.dx, p.dy - r * .4)
      ..cubicTo(
          p.dx + r * .8, p.dy - r, p.dx + r * 1.2, p.dy, p.dx, p.dy + r * .7)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawLine(
        Offset(p.dx - r * .35, p.dy - r * .2),
        Offset(p.dx - r * .18, p.dy - r * .35),
        Paint()
          ..color = const Color(0xFFFFF0DE)
          ..strokeWidth = r * .12
          ..strokeCap = StrokeCap.round);
  }

  static void _gem(Canvas canvas, Offset p, double r, Color color) {
    final path = Path()
      ..moveTo(p.dx, p.dy - r)
      ..lineTo(p.dx + r * .7, p.dy)
      ..lineTo(p.dx, p.dy + r)
      ..lineTo(p.dx - r * .7, p.dy)
      ..close();
    canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(colors: [
            Color.lerp(color, Colors.white, .65)!,
            color,
            Color.lerp(color, Colors.black, .2)!
          ], begin: Alignment.topLeft, end: Alignment.bottomRight)
              .createShader(Rect.fromCircle(center: p, radius: r)));
    canvas.drawLine(
        Offset(p.dx, p.dy - r * .6),
        Offset(p.dx, p.dy + r * .6),
        Paint()
          ..color = Colors.white.withValues(alpha: .6)
          ..strokeWidth = r * .08);
  }

  static void _bow(Canvas canvas, Offset p, double r) {
    for (final flip in [false, true]) {
      canvas.save();
      canvas.translate(p.dx, p.dy);
      if (flip) canvas.scale(-1, 1);
      final path = Path()
        ..moveTo(0, 0)
        ..cubicTo(-r * 1.5, -r, -r * 1.3, r * .6, 0, r * .2)
        ..close();
      canvas.drawPath(
          path,
          Paint()
            ..shader = const LinearGradient(
                    colors: [Color(0xFFFFE0BF), Color(0xFFDC94A6)])
                .createShader(Rect.fromLTWH(-r, -r / 2, r, r)));
      canvas.drawLine(
          Offset(-r * .75, -r * .2),
          Offset(-r * .1, r * .1),
          Paint()
            ..color = const Color(0xFFFFF0DB)
            ..strokeWidth = r * .07);
      canvas.restore();
    }
    canvas.drawCircle(p, r * .2, Paint()..color = const Color(0xFFE8BE87));
  }
}

class ChatBubbleOrnamentPainter extends CustomPainter {
  final ChatOrnament theme;
  final bool isUser;
  final Color background;
  const ChatBubbleOrnamentPainter(this.theme, this.isUser, this.background);

  @override
  void paint(Canvas canvas, Size size) =>
      ChatOrnaments.bubble(canvas, size, theme, isUser, background);

  @override
  bool shouldRepaint(ChatBubbleOrnamentPainter oldDelegate) =>
      oldDelegate.theme != theme ||
      oldDelegate.isUser != isUser ||
      oldDelegate.background != background;
}
