import 'package:flutter/material.dart';
import '../widget/chat_animated_frame_image.dart';
import 'chat_paired_asset_geometry.dart';

/// 名称用于持久化与包内素材路径，新增款式不改变已有配置。
enum ChatIllustratedTheme {
  adventure('像素冒险', '宝石剑刃 · 森林像素', Color(0xFF44724C)),
  neon('霓虹信号', '紫青光轨 · 全息信号', Color(0xFF8864D4)),
  crystal('海盐水晶', '晶莹海蓝 · 贝壳珍珠', Color(0xFF459CAD)),
  ink('墨染山河', '水墨竹影 · 朱砂落款', Color(0xFF777267)),
  plush('绒绒伙伴', '绒毛耳朵 · 软软爪印', Color(0xFFC18465)),
  brass('黄铜航行', '黄铜齿轮 · 远航罗盘', Color(0xFFAB823D)),
  butterflyGlass('蝶影琉璃', '蝶翼轻舞 · 琉璃微光', Color(0xFF9478CF),
      animated: true, avatarInset: .18),
  dragonEmber('龙焰赤金', '龙焰流动 · 赤金宝珠', Color(0xFFC65A35),
      animated: true, avatarInset: .22),
  midnightRose('暗夜蔷薇', '蔷薇花雨 · 暗红宝石', Color(0xFF9C4366),
      animated: true, avatarInset: .245),
  cloudFeather('云羽圣歌', '羽翼轻摆 · 云端星辉', Color(0xFFB3955D),
      animated: true, avatarInset: .275),
  moonRabbit('月兔绮梦', '月兔桂香 · 玉穗轻摇', Color(0xFF829B77),
      animated: true, avatarInset: .23),
  abyssGlow('深海荧光', '水母浮游 · 深海流光', Color(0xFF657ECD),
      animated: true, avatarInset: .225),
  foxCharm('狐火御守', '狐火闪烁 · 铃结轻摇', Color(0xFFBC5E53),
      animated: true, avatarInset: .25),
  creamBakery('奶油烘焙', '奶油甜梦 · 草莓心语', Color(0xFFC38758),
      animated: true, avatarInset: .25),
  streetGraffiti('街头涂鸦', '街头笔触 · 闪电节拍', Color(0xFF4269C7),
      animated: true, avatarInset: .26),
  vinylJazz('黑胶爵士', '黑胶转动 · 黄铜爵士', Color(0xFFAB823D),
      animated: true, avatarInset: .23),
  crimsonPhoenix('赤曜凤凰', '火羽流动 · 赤金流光', Color(0xFFC24B36),
      animated: true, animatedBubble: true),
  frostPalace('霜月雪境', '冰晶闪耀 · 霜光环绕', Color(0xFF629BC8),
      animated: true, animatedBubble: true),
  fireflyGrove('萤森秘语', '萤火轻舞 · 绿藤秘境', Color(0xFF658C47),
      animated: true, animatedBubble: true),
  cherrySoda('樱桃汽水', '樱桃气泡 · 清甜闪光', Color(0xFFCC5971),
      animated: true, animatedBubble: true),
  honeyGarden('蜜蜂花园', '蜜光流淌 · 花间振翅', Color(0xFFB78A35),
      animated: true, animatedBubble: true),
  pandaBamboo('竹影熊猫', '竹叶轻摇 · 熊猫眨眼', Color(0xFF5F9270),
      animated: true, animatedBubble: true),
  shibaPost('柴犬邮局', '柴犬来信 · 邮笺飞舞', Color(0xFFB17A51),
      animated: true, animatedBubble: true),
  catMagic('猫咪魔法', '星月流转 · 猫咪施法', Color(0xFF7C61B5),
      animated: true, animatedBubble: true),
  orbitalVoyage('星际航行', '星轨巡游 · 火箭启航', Color(0xFF526FBB),
      animated: true, animatedBubble: true),
  circuitMatrix('电路矩阵', '电流脉冲 · 机械萌宠', Color(0xFF398B64),
      animated: true, animatedBubble: true),
  jadeFiligree('翡翠玲珑', '玉光流转 · 莲瓣轻舞', Color(0xFF589C8C),
      animated: true, animatedBubble: true),
  dunhuangRibbons('敦煌飞天', '彩带飞扬 · 金铃流光', Color(0xFFBF8243),
      animated: true, animatedBubble: true),
  imperialPeony('牡丹国色', '花瓣飘落 · 国色生香', Color(0xFFB34D58),
      animated: true, animatedBubble: true),
  bluePorcelain('青花瓷韵', '青花流光 · 瓷珠轻摇', Color(0xFF507EBA),
      animated: true, animatedBubble: true),
  koiLotus('锦鲤荷塘', '锦鲤游弋 · 荷塘涟漪', Color(0xFF4D9DAB),
      animated: true, animatedBubble: true),
  ginkgoLetter('银杏秋信', '金叶飞舞 · 秋日来信', Color(0xFFB18C3D),
      animated: true, animatedBubble: true),
  mushroomFable('蘑菇童话', '蘑菇暖灯 · 森林魔法', Color(0xFF8B8147),
      animated: true, animatedBubble: true),
  carnivalDream('游乐绮梦', '彩球轻摇 · 木马星光', Color(0xFFBA7FAD),
      animated: true, animatedBubble: true),
  orangeSummer('甜橙夏日', '橙香流光 · 夏日花雨', Color(0xFFCE8935),
      animated: true, animatedBubble: true),
  royalChess('皇家棋局', '王冠闪耀 · 黑金棋语', Color(0xFF94773E),
      animated: true, animatedBubble: true);

  const ChatIllustratedTheme(this.label, this.description, this.accent,
      {this.animated = false,
      this.animatedBubble = false,
      double avatarInset = .16})
      : _avatarInset = avatarInset;
  final String label;
  final String description;
  final Color accent;
  final bool animated;
  final bool animatedBubble;
  final double _avatarInset;
  double get avatarInset =>
      chatPairedAssetGeometry[name]?.avatarInset ?? _avatarInset;
  EdgeInsets get bubbleBackgroundInsets =>
      chatPairedAssetGeometry[name]?.bubbleInsets ??
      const EdgeInsets.fromLTRB(8, 14, 8, 14);
  static List<ChatIllustratedTheme> get animatedSets => [
        ...values.where((theme) => theme.animatedBubble),
        ...values.where((theme) => theme.animated && !theme.animatedBubble),
      ];

  String get frameAsset => 'assets/decoration/${name}_frame.webp';
  String get framePosterAsset =>
      animated ? 'assets/decoration/${name}_frame_poster.webp' : frameAsset;
  String get bubbleAsset => 'assets/decoration/${name}_bubble.webp';
  String get bubblePosterAsset => animatedBubble
      ? 'assets/decoration/${name}_bubble_poster.webp'
      : bubbleAsset;

  // 生成素材统一为 1774×887，九宫格中间仅伸缩空白与连续边缘。
  static const bubbleAssetSize = Size(1774, 887);
  static const bubbleAssetScale = 887 / 64;
  // Flutter centerSlice 使用除以 ImageInfo.scale 后的逻辑坐标。
  static const bubbleCenterSlice = Rect.fromLTRB(444 / bubbleAssetScale,
      426 / bubbleAssetScale, 1330 / bubbleAssetScale, 461 / bubbleAssetScale);

  // 新素材按同样的逻辑尺寸导出，降低解码内存；旧素材保持原样。
  Size get bubbleSize => animatedBubble
      ? const Size(512, 320)
      : animated
          ? const Size(1024, 512)
          : bubbleAssetSize;
  double get bubbleScale => animatedBubble
      ? 4
      : animated
          ? 8
          : bubbleAssetScale;
  Rect get centerSlice => animatedBubble
      ? const Rect.fromLTRB(50, 39, 78, 41)
      : animated
          ? const Rect.fromLTRB(32, 30.75, 96, 33.25)
          : bubbleCenterSlice;

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
      butterflyGlass =>
        isUser ? const Color(0xFFECE3FC) : const Color(0xFFE4EFFB),
      dragonEmber => isUser ? const Color(0xFF6D211B) : const Color(0xFFFFEBCB),
      midnightRose =>
        isUser ? const Color(0xFF321924) : const Color(0xFFF8EBE4),
      cloudFeather =>
        isUser ? const Color(0xFFFFF4DE) : const Color(0xFFE8F1FB),
      moonRabbit => isUser ? const Color(0xFFF9F0D8) : const Color(0xFFE5EEDC),
      abyssGlow => isUser ? const Color(0xFF172951) : const Color(0xFFE9E4FC),
      foxCharm => isUser ? const Color(0xFFFFEED7) : const Color(0xFF2B2238),
      creamBakery => isUser ? const Color(0xFFFFEACF) : const Color(0xFFFFE6E5),
      streetGraffiti =>
        isUser ? const Color(0xFFF7F5EA) : const Color(0xFF203EA2),
      vinylJazz => isUser ? const Color(0xFF242124) : const Color(0xFFF5E6C9),
      _ => Color.lerp(Colors.white, accent, isUser ? .20 : .10)!,
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
          padding: EdgeInsets.all(size * theme.avatarInset),
          child: ClipOval(child: FittedBox(fit: BoxFit.cover, child: child)),
        ),
        IgnorePointer(
          child: ExcludeSemantics(
            child: ChatAnimatedFrameImage(
                asset: theme.frameAsset,
                posterAsset: theme.framePosterAsset,
                animated: theme.animated,
                pixels: pixels,
                filterQuality: theme == ChatIllustratedTheme.adventure
                    ? FilterQuality.none
                    : FilterQuality.medium,
                fallback: DecoratedBox(
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
