import 'package:flutter/material.dart';

/// 概念图落地的六组装扮；名称用于持久化与包内素材路径。
enum ChatIllustratedTheme {
  adventure('像素冒险', '宝石剑刃 · 森林像素', Color(0xFF44724C)),
  neon('霓虹信号', '紫青光轨 · 全息信号', Color(0xFF8864D4)),
  crystal('海盐水晶', '晶莹海蓝 · 贝壳珍珠', Color(0xFF459CAD)),
  ink('墨染山河', '水墨竹影 · 朱砂落款', Color(0xFF777267)),
  plush('绒绒伙伴', '绒毛耳朵 · 软软爪印', Color(0xFFC18465)),
  brass('黄铜航行', '黄铜齿轮 · 远航罗盘', Color(0xFFAB823D));

  const ChatIllustratedTheme(this.label, this.description, this.accent);
  final String label;
  final String description;
  final Color accent;

  String get frameAsset => 'assets/decoration/${name}_frame.webp';
  String get bubbleAsset => 'assets/decoration/${name}_bubble.webp';

  // 生成素材统一为 1774×887，九宫格中间仅伸缩空白与连续边缘。
  static const bubbleAssetSize = Size(1774, 887);
  static const bubbleAssetScale = 887 / 64;
  // Flutter centerSlice 使用除以 ImageInfo.scale 后的逻辑坐标。
  static const bubbleCenterSlice = Rect.fromLTRB(444 / bubbleAssetScale,
      426 / bubbleAssetScale, 1330 / bubbleAssetScale, 461 / bubbleAssetScale);

  Color bubbleColor({required bool dark, required bool isUser}) {
    if (dark) {
      return Color.lerp(const Color(0xFF111827), accent, isUser ? .30 : .18)!;
    }
    return switch (this) {
      adventure => isUser ? const Color(0xFFF4E8C9) : const Color(0xFFEEF1DB),
      neon => isUser ? const Color(0xFF252046) : const Color(0xFF162C41),
      crystal => isUser ? const Color(0xFFDFF3FB) : const Color(0xFFEDF9F7),
      ink => isUser ? const Color(0xFFF2EDE1) : const Color(0xFFFAF7EF),
      plush => isUser ? const Color(0xFFFFE9DF) : const Color(0xFFFFF2DF),
      brass => isUser ? const Color(0xFF203D40) : const Color(0xFFF7EACF),
    };
  }

  Color edgeColor(Color background) => Color.lerp(
      accent,
      background.computeLuminance() > .179 ? Colors.black : Colors.white,
      background.computeLuminance() > .179 ? .12 : .38)!;
}

/// 头像原图保持独立，透明插画只叠加边框。按实际显示尺寸解码，避免
/// 聊天列表为每个小头像解码整张原尺寸素材；所有装扮均无需网络。
class ChatIllustratedAvatarFrame extends StatelessWidget {
  final ChatIllustratedTheme theme;
  final double size;
  final Widget child;

  const ChatIllustratedAvatarFrame(
      {super.key,
      required this.theme,
      required this.size,
      required this.child});

  @override
  Widget build(BuildContext context) {
    final pixels =
        (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 512);
    return SizedBox.square(
      dimension: size,
      child: Stack(fit: StackFit.expand, children: [
        Padding(
          padding: EdgeInsets.all(size * .16),
          child: ClipOval(child: FittedBox(fit: BoxFit.cover, child: child)),
        ),
        IgnorePointer(
          child: ExcludeSemantics(
            child: Image.asset(theme.frameAsset,
                package: 'chat_message',
                cacheWidth: pixels,
                cacheHeight: pixels,
                fit: BoxFit.contain,
                filterQuality: theme == ChatIllustratedTheme.adventure
                    ? FilterQuality.none
                    : FilterQuality.medium,
                errorBuilder: (_, __, ___) => DecoratedBox(
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: theme.accent, width: size * .06)))),
          ),
        ),
      ]),
    );
  }
}
