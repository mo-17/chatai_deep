import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'chat_ornaments.dart';

/// 使用稳定的名字保存配置；新增款式不改变已有用户的选择。
enum ChatBubbleStyle {
  classic('经典', '熟悉的对话气泡', Color(0xFF7665C8)),
  cloud('云朵', '柔软圆角 · 轻盈浮起', Color(0xFF5683C5)),
  aurora('极光', '微光渐层 · 通透色彩', Color(0xFF7C65D5)),
  outline('描边', '纤细线条 · 清爽留白', Color(0xFF2B9385)),
  paper('手札', '纸感卡片 · 温暖一角', Color(0xFFAC7A3F)),
  pixel('像素', '利落折角 · 复古趣味', Color(0xFF6173BD)),
  messenger('弧尾', '流畅弧线 · 圆润尾角', Color(0xFF497ECC)),
  telegram('轻聊', '清新色彩 · 轻巧尖尾', Color(0xFF389A75)),
  constellation('星河', '星月角标 · 梦幻微光', Color(0xFF8670CD)),
  blossom('樱花', '花瓣来信 · 柔粉春意', Color(0xFFD26B93)),
  ribbon('甜心', '奶油丝带 · 心动角标', Color(0xFFC38A50)),
  mecha('机甲', '棱角护甲 · 青色能量', Color(0xFF247E86));

  const ChatBubbleStyle(this.label, this.description, this.accent);
  final String label;
  final String description;
  final Color accent;

  ChatOrnament? get ornament => switch (this) {
        constellation => ChatOrnament.constellation,
        blossom => ChatOrnament.blossom,
        ribbon => ChatOrnament.ribbon,
        mecha => ChatOrnament.mecha,
        _ => null,
      };

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
      messenger => isUser ? const Color(0xFFDDEBFF) : const Color(0xFFEEF1F5),
      telegram => isUser ? const Color(0xFFDAF2DD) : const Color(0xFFF1F7F3),
      constellation =>
        isUser ? const Color(0xFFE9E5FF) : const Color(0xFFE6EEFB),
      blossom => isUser ? const Color(0xFFFFE8F0) : const Color(0xFFFCEFF4),
      ribbon => isUser ? const Color(0xFFFFEBD4) : const Color(0xFFFFF2E4),
      mecha => isUser ? const Color(0xFF223449) : const Color(0xFF1E2D40),
      classic => theme.colorScheme.primaryContainer,
    };
    return dark
        ? Color.lerp(const Color(0xFF111827), accent, isUser ? .32 : .20)!
        : seed;
  }

  /// 渐层向同一对比度方向变化，保证整块气泡都能使用同一种正文颜色。
  List<Color> backgroundColors(Color base) =>
      (this == aurora || ornament != null)
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
  pixel('像素', '复古方形边框'),
  halo('晨光', '柔和光晕 · 温暖环绕'),
  dashed('星点', '渐变虚线 · 轻盈留白'),
  constellation('星河', '星月宝石 · 流翼环绕'),
  blossom('樱花', '花簇缠枝 · 轻盈花冠'),
  ribbon('甜心', '蝴蝶丝带 · 心形宝石'),
  mecha('机甲', '六角徽章 · 能量护翼');

  const ChatAvatarFrameStyle(this.label, this.description);
  final String label;
  final String description;

  ChatOrnament? get ornament => switch (this) {
        constellation => ChatOrnament.constellation,
        blossom => ChatOrnament.blossom,
        ribbon => ChatOrnament.ribbon,
        mecha => ChatOrnament.mecha,
        _ => null,
      };

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
          padding: EdgeInsets.all(size * (style.ornament == null ? .105 : .17)),
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
      case ChatAvatarFrameStyle.halo:
        final glow = brightness == Brightness.dark
            ? const Color(0xFFF6C28A)
            : const Color(0xFFAC703D);
        canvas.save();
        canvas.clipRect(rect);
        paint
          ..color = glow.withValues(alpha: .45)
          ..strokeWidth = unit * .085
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * .045);
        canvas.drawCircle(center, unit * .445, paint);
        paint
          ..maskFilter = null
          ..color = glow
          ..strokeWidth = unit * .027;
        canvas.drawCircle(center, unit * .43, paint);
        canvas.restore();
      case ChatAvatarFrameStyle.dashed:
        paint
          ..strokeWidth = unit * .047
          ..strokeCap = StrokeCap.round
          ..shader = const SweepGradient(colors: [
            Color(0xFF8870D6),
            Color(0xFF52B5B2),
            Color(0xFF8870D6)
          ]).createShader(rect);
        for (var index = 0; index < 14; index++) {
          canvas.drawArc(rect.deflate(unit * .055), index * math.pi / 7,
              math.pi / 10, false, paint);
        }
      case ChatAvatarFrameStyle.constellation:
      case ChatAvatarFrameStyle.blossom:
      case ChatAvatarFrameStyle.ribbon:
      case ChatAvatarFrameStyle.mecha:
        ChatOrnaments.frame(canvas, size, style.ornament!, brightness);
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
