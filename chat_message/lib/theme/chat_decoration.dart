import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 使用稳定的名字保存配置；新增款式不改变已有用户的选择。
enum ChatBubbleStyle {
  classic('经典', '熟悉的对话气泡', Color(0xFF7665C8)),
  cloud('云朵', '柔软圆角 · 轻盈浮起', Color(0xFF5683C5)),
  aurora('极光', '微光渐层 · 通透色彩', Color(0xFF7C65D5)),
  outline('描边', '纤细线条 · 清爽留白', Color(0xFF2B9385)),
  paper('手札', '纸感卡片 · 温暖一角', Color(0xFFAC7A3F)),
  pixel('像素', '利落折角 · 复古趣味', Color(0xFF6173BD));

  const ChatBubbleStyle(this.label, this.description, this.accent);
  final String label;
  final String description;
  final Color accent;

  static ChatBubbleStyle fromStorage(String? value) => values.firstWhere(
        (style) => style.name == value,
        orElse: () => classic,
      );

  Color defaultColor(ThemeData theme, {required bool isUser}) {
    final dark = theme.brightness == Brightness.dark;
    final seed = switch (this) {
      cloud => isUser ? const Color(0xFFDCECFB) : const Color(0xFFE8EEF7),
      aurora => isUser ? const Color(0xFFE3DDFB) : const Color(0xFFD9F1EC),
      outline => isUser ? const Color(0xFFE1F2ED) : const Color(0xFFEEF4F2),
      paper => isUser ? const Color(0xFFF7E9CE) : const Color(0xFFFFF6E6),
      pixel => isUser ? const Color(0xFFE0E5FF) : const Color(0xFFE8EBF7),
      classic => theme.colorScheme.primaryContainer,
    };
    return dark
        ? Color.lerp(const Color(0xFF111827), accent, isUser ? .32 : .20)!
        : seed;
  }

  /// 渐层向同一对比度方向变化，保证整块气泡都能使用同一种正文颜色。
  List<Color> backgroundColors(Color base) => this == aurora
      ? [
          base,
          Color.lerp(
              base,
              base.computeLuminance() > .179 ? Colors.white : Colors.black,
              .16)!
        ]
      : [base];
}

enum ChatAvatarFrameStyle {
  none('原生', '保留头像原貌'),
  aurora('流光', '紫蓝渐变环'),
  mint('薄荷', '清透双线环'),
  gold('星芒', '香槟金星角'),
  orbit('星轨', '环绕行星轨道'),
  pixel('像素', '复古方形边框');

  const ChatAvatarFrameStyle(this.label, this.description);
  final String label;
  final String description;

  static ChatAvatarFrameStyle fromStorage(String? value) => values.firstWhere(
        (frame) => frame.name == value,
        orElse: () => none,
      );
}

/// 框在原头像尺寸内绘制，避免装扮改变聊天排版与点击区域。
class ChatAvatarFrame extends StatelessWidget {
  final ChatAvatarFrameStyle style;
  final double size;
  final Widget child;

  const ChatAvatarFrame(
      {super.key,
      required this.style,
      required this.size,
      required this.child});

  @override
  Widget build(BuildContext context) {
    if (style == ChatAvatarFrameStyle.none) return child;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        foregroundPainter: _FramePainter(style, Theme.of(context).brightness),
        child: Padding(
          padding: EdgeInsets.all(size * .105),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
                style == ChatAvatarFrameStyle.pixel ? size * .12 : size),
            child: SizedBox.expand(
                child: FittedBox(fit: BoxFit.cover, child: child)),
          ),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  final ChatAvatarFrameStyle style;
  final Brightness brightness;
  const _FramePainter(this.style, this.brightness);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final unit = size.shortestSide;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = unit * .035;
    switch (style) {
      case ChatAvatarFrameStyle.none:
        return;
      case ChatAvatarFrameStyle.aurora:
        paint
          ..strokeWidth = unit * .06
          ..shader = const SweepGradient(colors: [
            Color(0xFF9173EA),
            Color(0xFF5DADE0),
            Color(0xFF70CBB7),
            Color(0xFF9173EA)
          ]).createShader(rect);
        canvas.drawCircle(center, unit * .46, paint);
      case ChatAvatarFrameStyle.mint:
        paint.color = brightness == Brightness.dark
            ? const Color(0xFF7DDFC6)
            : const Color(0xFF318D7A);
        canvas.drawCircle(center, unit * .47, paint);
        paint
          ..strokeWidth = unit * .015
          ..color = paint.color.withValues(alpha: .6);
        canvas.drawCircle(center, unit * .415, paint);
      case ChatAvatarFrameStyle.gold:
        paint.color = brightness == Brightness.dark
            ? const Color(0xFFEEC982)
            : const Color(0xFFAB782F);
        canvas.drawCircle(center, unit * .44, paint);
        for (final angle in [-math.pi / 4, math.pi * 3 / 4]) {
          final p =
              center + Offset(math.cos(angle), math.sin(angle)) * unit * .43;
          final star = Path()
            ..moveTo(p.dx, p.dy - unit * .105)
            ..lineTo(p.dx + unit * .045, p.dy)
            ..lineTo(p.dx, p.dy + unit * .105)
            ..lineTo(p.dx - unit * .045, p.dy)
            ..close();
          canvas.drawPath(star, Paint()..color = paint.color);
        }
      case ChatAvatarFrameStyle.orbit:
        paint.color = brightness == Brightness.dark
            ? const Color(0xFFB3ACFF)
            : const Color(0xFF7665C8);
        canvas.drawCircle(center, unit * .425, paint);
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-math.pi / 5);
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset.zero, width: unit * .98, height: unit * .63),
            paint);
        canvas.restore();
        canvas.drawCircle(center + Offset(unit * .35, -unit * .31), unit * .055,
            Paint()..color = const Color(0xFF5BB9AE));
      case ChatAvatarFrameStyle.pixel:
        paint
          ..color = brightness == Brightness.dark
              ? const Color(0xFFADBFFD)
              : const Color(0xFF6378B8)
          ..strokeJoin = StrokeJoin.miter;
        final r = rect.deflate(unit * .035);
        final s = unit * .13;
        final path = Path()
          ..moveTo(r.left + s, r.top)
          ..lineTo(r.right - s, r.top)
          ..lineTo(r.right - s, r.top + s)
          ..lineTo(r.right, r.top + s)
          ..lineTo(r.right, r.bottom - s)
          ..lineTo(r.right - s, r.bottom - s)
          ..lineTo(r.right - s, r.bottom)
          ..lineTo(r.left + s, r.bottom)
          ..lineTo(r.left + s, r.bottom - s)
          ..lineTo(r.left, r.bottom - s)
          ..lineTo(r.left, r.top + s)
          ..lineTo(r.left + s, r.top + s)
          ..close();
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.brightness != brightness;
}
