import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/chat_illustrated_theme.dart';
import 'chat_animated_frame_image.dart';

/// 正文是真实组件，边框按尺寸重绘；短句、长文、代码和流式内容共用。
class ChatIllustratedBubble extends StatelessWidget {
  final ChatIllustratedTheme theme;
  final Color color;
  final List<Color> colors;
  final bool isUser;
  final Widget child;

  const ChatIllustratedBubble(
      {super.key,
      required this.theme,
      required this.color,
      required this.colors,
      required this.isUser,
      required this.child});

  // 装饰只占用边缘留白，绘制与布局使用同一份尺寸。
  static const padding = EdgeInsets.fromLTRB(28, 34, 28, 34);

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter:
            ChatIllustratedBubblePainter(theme, color, colors, isUser: isUser),
        child: Stack(children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 112, minHeight: 86),
            child: Padding(padding: padding, child: child),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: ClipPath(
                  clipper: const ChatBubbleBorderClipper(),
                  child: Transform.flip(
                    flipX: !isUser,
                    child: ChatAnimatedFrameImage(
                        asset: theme.bubbleAsset,
                        posterAsset: theme.bubblePosterAsset,
                        animated: theme.animatedBubble,
                        scale: theme.bubbleScale,
                        centerSlice: theme.centerSlice,
                        fit: BoxFit.fill,
                        filterQuality: theme == ChatIllustratedTheme.adventure
                            ? FilterQuality.none
                            : FilterQuality.medium,
                        fallback: CustomPaint(
                            painter: ChatIllustratedBubblePainter(
                                theme, color, colors,
                                isUser: true, ornamentsOnly: true))),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
}

/// 材质边框中的零星半透明像素也不能进入正文/代码的实际内容区域。
class ChatBubbleBorderClipper extends CustomClipper<Path> {
  const ChatBubbleBorderClipper();

  @override
  Path getClip(Size size) => Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()
        ..addRect(
            ChatIllustratedBubble.padding.deflateRect(Offset.zero & size)));

  @override
  bool shouldReclip(ChatBubbleBorderClipper oldClipper) => false;
}

class ChatIllustratedBubblePainter extends CustomPainter {
  final ChatIllustratedTheme theme;
  final Color color;
  final List<Color> colors;
  final bool isUser;
  final bool ornamentsOnly;

  const ChatIllustratedBubblePainter(this.theme, this.color, this.colors,
      {required this.isUser, this.ornamentsOnly = false});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(rect);
    if (!ornamentsOnly) {
      // 素材上下带透明外沿；底色缩进至边框下方，避免露出整块矩形底板。
      final insets = theme.bubbleBackgroundInsets;
      final directed = isUser
          ? insets
          : EdgeInsets.fromLTRB(
              insets.right, insets.top, insets.left, insets.bottom);
      final path = _outline(directed.deflateRect(rect));
      canvas.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(
                    colors: colors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight)
                .createShader(rect));
    } else {
      // 双重裁剪保证即使窄气泡的装饰互相靠近，也不会进入正文区域。
      final inner = Rect.fromLTRB(0, ChatIllustratedBubble.padding.top,
          size.width, size.height - ChatIllustratedBubble.padding.bottom);
      canvas.clipPath(Path.combine(PathOperation.difference,
          Path()..addRect(rect), Path()..addRect(inner)));
      _ornaments(canvas, size);
    }
    canvas.restore();
  }

  Path _outline(Rect r) => switch (theme) {
        ChatIllustratedTheme.adventure => Path()
          ..moveTo(r.left + 12, r.top)
          ..lineTo(r.right - 12, r.top)
          ..lineTo(r.right - 12, r.top + 6)
          ..lineTo(r.right - 6, r.top + 6)
          ..lineTo(r.right - 6, r.top + 12)
          ..lineTo(r.right, r.top + 12)
          ..lineTo(r.right, r.bottom - 12)
          ..lineTo(r.right - 6, r.bottom - 12)
          ..lineTo(r.right - 6, r.bottom - 6)
          ..lineTo(r.right - 12, r.bottom - 6)
          ..lineTo(r.right - 12, r.bottom)
          ..lineTo(r.left + 12, r.bottom)
          ..lineTo(r.left + 12, r.bottom - 6)
          ..lineTo(r.left + 6, r.bottom - 6)
          ..lineTo(r.left + 6, r.bottom - 12)
          ..lineTo(r.left, r.bottom - 12)
          ..lineTo(r.left, r.top + 12)
          ..lineTo(r.left + 6, r.top + 12)
          ..lineTo(r.left + 6, r.top + 6)
          ..lineTo(r.left + 12, r.top + 6)
          ..close(),
        ChatIllustratedTheme.neon => const BeveledRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(13)))
            .getOuterPath(r),
        _ => Path()
          ..addRRect(RRect.fromRectAndRadius(
              r,
              Radius.circular(switch (theme) {
                ChatIllustratedTheme.ink => 9,
                ChatIllustratedTheme.brass => 13,
                _ => 24,
              }))),
      };

  void _ornaments(Canvas c, Size size) {
    final w = size.width;
    final h = size.height;
    final ink = theme.edgeColor(color);
    final dark = color.computeLuminance() <= .179;
    final line = Paint()
      ..color = ink
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // 两侧消息在装饰位置上呼应，避免整张气泡镜像时把正文也翻转。
    c.save();
    if (!isUser) {
      c.translate(w, 0);
      c.scale(-1, 1);
    }
    switch (theme) {
      case ChatIllustratedTheme.adventure:
        final gold = dark ? const Color(0xFFEACB82) : const Color(0xFFB4842F);
        c.drawLine(const Offset(20, 9), Offset(w - 22, 9), line..color = gold);
        c.drawLine(Offset(20, h - 9), Offset(w - 22, h - 9), line);
        _diamond(c, Offset(w - 23, 16), 7, ink);
        for (var i = 0; i < 3; i++) {
          c.drawRect(Rect.fromLTWH(14 + i * 6, h - 19, 4, 4),
              Paint()..color = i.isEven ? ink : gold);
        }
        c.drawPath(
            Path()
              ..moveTo(15, 14)
              ..lineTo(27, 22)
              ..lineTo(29, 19),
            line..strokeWidth = 3);
        c.drawLine(
            const Offset(22, 22),
            const Offset(27, 15),
            line
              ..color = ink
              ..strokeWidth = 2);
      case ChatIllustratedTheme.neon:
        final cyan = dark ? const Color(0xFF69EDF3) : const Color(0xFF087987);
        final purple = dark ? const Color(0xFFD8A7FF) : const Color(0xFF8452B6);
        c.drawPath(
            Path()
              ..moveTo(9, 23)
              ..lineTo(18, 10)
              ..lineTo(w * .58, 10),
            line
              ..color = cyan
              ..strokeWidth = 2);
        c.drawPath(
            Path()
              ..moveTo(w - 9, h - 23)
              ..lineTo(w - 18, h - 10)
              ..lineTo(w * .42, h - 10),
            line..color = purple);
        for (var i = 0; i < 6; i++) {
          c.drawLine(
              Offset(16 + i * 4, h - 13),
              Offset(16 + i * 4, h - 16 - i % 3 * 2),
              line
                ..color = cyan
                ..strokeWidth = 1.5);
        }
        _diamond(c, Offset(w - 18, 17), 5, purple);
      case ChatIllustratedTheme.crystal:
        c.drawArc(Rect.fromLTWH(10, 8, w - 20, 25), math.pi, math.pi, false,
            line..color = ink.withValues(alpha: .65));
        for (final point in [const Offset(18, 18), Offset(w - 15, h - 16)]) {
          c.drawCircle(
              point,
              4.5,
              Paint()
                ..shader = const RadialGradient(
                        colors: [Color(0xFFFFFFFF), Color(0xFFACD2DE)])
                    .createShader(Rect.fromCircle(center: point, radius: 5)));
        }
        _diamond(c, Offset(w - 20, 17), 9, ink.withValues(alpha: .65));
        final shell = Offset(29, h - 13);
        for (var i = 0; i < 5; i++) {
          final a = -math.pi + i * math.pi / 4;
          c.drawLine(
              shell,
              shell + Offset(math.cos(a), math.sin(a)) * 10,
              line
                ..color =
                    dark ? const Color(0xFFFFD7D5) : const Color(0xFFC28787));
        }
        c.drawArc(Rect.fromCircle(center: shell, radius: 10), math.pi, math.pi,
            false, line);
      case ChatIllustratedTheme.ink:
        // 笔触使用固定散点，不在重绘时随机抖动。
        for (var i = 0; i < 24; i++) {
          final x = 13 + (w - 26) * i / 23;
          c.drawLine(
              Offset(x, 8 + math.sin(i * 2.7) * 1.5),
              Offset(x + 3, 9 + math.sin(i * 2.7)),
              line
                ..color = ink.withValues(alpha: .55)
                ..strokeWidth = i % 3 == 0 ? 2 : .8);
        }
        c.drawLine(
            const Offset(14, 24),
            const Offset(40, 10),
            line
              ..color = ink
              ..strokeWidth = 1.2);
        for (var i = 0; i < 3; i++) {
          final p = Offset(22 + i * 7, 21 - i * 4);
          c.drawPath(
              Path()
                ..moveTo(p.dx, p.dy)
                ..quadraticBezierTo(p.dx - 7, p.dy - 10, p.dx + 3, p.dy - 4)
                ..close(),
              Paint()..color = ink);
        }
        final seal = Rect.fromLTWH(w - 29, h - 23, 15, 16);
        c.drawRRect(
            RRect.fromRectAndRadius(seal, const Radius.circular(2)),
            line
              ..color = const Color(0xFFBC4D3F)
              ..strokeWidth = 1.5);
        c.drawPath(
            Path()
              ..moveTo(w - 25, h - 19)
              ..lineTo(w - 18, h - 19)
              ..lineTo(w - 22, h - 13)
              ..lineTo(w - 17, h - 11),
            line..strokeWidth = 1);
        c.drawPath(
            Path()
              ..moveTo(13, h - 10)
              ..lineTo(23, h - 20)
              ..lineTo(32, h - 12)
              ..lineTo(41, h - 18)
              ..lineTo(52, h - 9),
            line..color = ink.withValues(alpha: .55));
      case ChatIllustratedTheme.plush:
        final warm = dark ? const Color(0xFFF0C29A) : const Color(0xFFC08C6C);
        for (double x = 22; x < w - 20; x += 7) {
          c.drawLine(
              Offset(x, 10),
              Offset(x + 3, 12),
              line
                ..color = warm
                ..strokeWidth = 1.2);
          c.drawLine(Offset(x, h - 11), Offset(x + 3, h - 13), line);
        }
        for (final x in [18.0, 36.0]) {
          c.drawCircle(Offset(x, 18), 6.5, Paint()..color = warm);
          c.drawCircle(Offset(x, 18), 3.5, Paint()..color = color);
        }
        _paw(c, Offset(w - 24, h - 15),
            dark ? const Color(0xFFFFB5A4) : const Color(0xFFCD8575));
        final button = Offset(w - 19, 17);
        c.drawCircle(button, 6, Paint()..color = warm);
        for (final dx in [-1.8, 1.8]) {
          c.drawCircle(button + Offset(dx, 0), 1, Paint()..color = color);
        }
      case ChatIllustratedTheme.brass:
        final gold = dark ? const Color(0xFFF0CA79) : const Color(0xFFA67E37);
        final bronze = dark ? const Color(0xFF9D7339) : const Color(0xFFDCBF80);
        c.drawLine(const Offset(22, 9), Offset(w - 23, 9), line..color = gold);
        c.drawLine(Offset(37, h - 10), Offset(w - 29, h - 10), line);
        _gear(c, Offset(20, h - 16), 10, gold, color);
        _gear(c, Offset(34, h - 20), 5, bronze, color);
        final compass = Offset(w - 20, 17);
        c.drawCircle(
            compass,
            10,
            line
              ..color = gold
              ..strokeWidth = 1.3);
        _diamond(c, compass, 7, gold);
        for (final p in [const Offset(15, 16), Offset(w - 16, h - 15)]) {
          c.drawCircle(p, 2.5, Paint()..color = bronze);
          c.drawLine(
              p - const Offset(1.4, 0),
              p + const Offset(1.4, 0),
              line
                ..color = gold
                ..strokeWidth = .8);
        }
      default:
        // 素材无法解码时的轻量回退，仍避开正文区域。
        c.drawLine(const Offset(22, 10), Offset(w - 22, 10), line);
        c.drawLine(Offset(22, h - 10), Offset(w - 22, h - 10), line);
        _diamond(c, Offset(w - 18, 17), 6, ink);
    }
    c.restore();
  }

  static void _diamond(Canvas c, Offset p, double r, Color color) {
    final path = Path()
      ..moveTo(p.dx, p.dy - r)
      ..lineTo(p.dx + r * .6, p.dy)
      ..lineTo(p.dx, p.dy + r)
      ..lineTo(p.dx - r * .6, p.dy)
      ..close();
    c.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(colors: [
            Color.lerp(color, Colors.white, .6)!,
            color,
            Color.lerp(color, Colors.black, .25)!
          ]).createShader(Rect.fromCircle(center: p, radius: r)));
    c.drawLine(
        Offset(p.dx, p.dy - r * .5),
        Offset(p.dx, p.dy + r * .5),
        Paint()
          ..color = Colors.white.withValues(alpha: .7)
          ..strokeWidth = .8);
  }

  static void _paw(Canvas c, Offset p, Color color) {
    c.drawOval(
        Rect.fromCenter(center: p + const Offset(0, 2), width: 12, height: 9),
        Paint()..color = color);
    for (var i = 0; i < 3; i++) {
      c.drawOval(
          Rect.fromCenter(
              center: p + Offset((i - 1) * 5.5, -5 - (i == 1 ? 2 : 0)),
              width: 4.5,
              height: 6),
          Paint()..color = color);
    }
  }

  static void _gear(Canvas c, Offset p, double r, Color ink, Color background) {
    final path = Path();
    for (var i = 0; i < 40; i++) {
      final a = i * math.pi / 20;
      final v =
          p + Offset(math.cos(a), math.sin(a)) * r * (i % 4 < 2 ? 1 : .78);
      if (i == 0) {
        path.moveTo(v.dx, v.dy);
      } else {
        path.lineTo(v.dx, v.dy);
      }
    }
    c.drawPath(path..close(), Paint()..color = ink);
    c.drawCircle(p, r * .55, Paint()..color = background);
    c.drawCircle(p, r * .22, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(ChatIllustratedBubblePainter old) =>
      old.theme != theme ||
      old.color != color ||
      old.isUser != isUser ||
      old.ornamentsOnly != ornamentsOnly ||
      !listEquals(old.colors, colors);
}
