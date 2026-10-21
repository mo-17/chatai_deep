import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'chat_ornaments.dart';
import 'chat_illustrated_theme.dart';

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
  mecha('机甲', '棱角护甲 · 青色能量', Color(0xFF247E86)),
  adventure('像素冒险', '宝石剑刃 · 森林像素', Color(0xFF44724C)),
  neon('霓虹信号', '紫青光轨 · 全息信号', Color(0xFF8864D4)),
  crystal('海盐水晶', '晶莹海蓝 · 贝壳珍珠', Color(0xFF459CAD)),
  ink('墨染山河', '水墨竹影 · 朱砂落款', Color(0xFF777267)),
  plush('绒绒伙伴', '绒毛耳朵 · 软软爪印', Color(0xFFC18465)),
  brass('黄铜航行', '黄铜齿轮 · 远航罗盘', Color(0xFFAB823D)),
  butterflyGlass('蝶影琉璃', '蝶翼轻舞 · 琉璃微光', Color(0xFF9478CF)),
  dragonEmber('龙焰赤金', '龙焰流动 · 赤金宝珠', Color(0xFFC65A35)),
  midnightRose('暗夜蔷薇', '蔷薇花雨 · 暗红宝石', Color(0xFF9C4366)),
  cloudFeather('云羽圣歌', '羽翼轻摆 · 云端星辉', Color(0xFFB3955D)),
  moonRabbit('月兔绮梦', '月兔桂香 · 玉穗轻摇', Color(0xFF829B77)),
  abyssGlow('深海荧光', '水母浮游 · 深海流光', Color(0xFF657ECD)),
  foxCharm('狐火御守', '狐火闪烁 · 铃结轻摇', Color(0xFFBC5E53)),
  creamBakery('奶油烘焙', '奶油甜梦 · 草莓心语', Color(0xFFC38758)),
  streetGraffiti('街头涂鸦', '街头笔触 · 闪电节拍', Color(0xFF4269C7)),
  vinylJazz('黑胶爵士', '黑胶转动 · 黄铜爵士', Color(0xFFAB823D)),
  crimsonPhoenix('赤曜凤凰', '火羽流动 · 赤金流光', Color(0xFFC24B36)),
  frostPalace('霜月雪境', '冰晶闪耀 · 霜光环绕', Color(0xFF629BC8)),
  fireflyGrove('萤森秘语', '萤火轻舞 · 绿藤秘境', Color(0xFF658C47)),
  cherrySoda('樱桃汽水', '樱桃气泡 · 清甜闪光', Color(0xFFCC5971)),
  honeyGarden('蜜蜂花园', '蜜光流淌 · 花间振翅', Color(0xFFB78A35)),
  pandaBamboo('竹影熊猫', '竹叶轻摇 · 熊猫眨眼', Color(0xFF5F9270)),
  shibaPost('柴犬邮局', '柴犬来信 · 邮笺飞舞', Color(0xFFB17A51)),
  catMagic('猫咪魔法', '星月流转 · 猫咪施法', Color(0xFF7C61B5)),
  orbitalVoyage('星际航行', '星轨巡游 · 火箭启航', Color(0xFF526FBB)),
  circuitMatrix('电路矩阵', '电流脉冲 · 机械萌宠', Color(0xFF398B64)),
  jadeFiligree('翡翠玲珑', '玉光流转 · 莲瓣轻舞', Color(0xFF589C8C)),
  dunhuangRibbons('敦煌飞天', '彩带飞扬 · 金铃流光', Color(0xFFBF8243)),
  imperialPeony('牡丹国色', '花瓣飘落 · 国色生香', Color(0xFFB34D58)),
  bluePorcelain('青花瓷韵', '青花流光 · 瓷珠轻摇', Color(0xFF507EBA)),
  koiLotus('锦鲤荷塘', '锦鲤游弋 · 荷塘涟漪', Color(0xFF4D9DAB)),
  ginkgoLetter('银杏秋信', '金叶飞舞 · 秋日来信', Color(0xFFB18C3D)),
  mushroomFable('蘑菇童话', '蘑菇暖灯 · 森林魔法', Color(0xFF8B8147)),
  carnivalDream('游乐绮梦', '彩球轻摇 · 木马星光', Color(0xFFBA7FAD)),
  orangeSummer('甜橙夏日', '橙香流光 · 夏日花雨', Color(0xFFCE8935)),
  royalChess('皇家棋局', '王冠闪耀 · 黑金棋语', Color(0xFF94773E));

  const ChatBubbleStyle(this.label, this.description, this.accent);
  final String label;
  final String description;
  final Color accent;

  ChatIllustratedTheme? get illustration => switch (this) {
        adventure => ChatIllustratedTheme.adventure,
        neon => ChatIllustratedTheme.neon,
        crystal => ChatIllustratedTheme.crystal,
        ink => ChatIllustratedTheme.ink,
        plush => ChatIllustratedTheme.plush,
        brass => ChatIllustratedTheme.brass,
        butterflyGlass => ChatIllustratedTheme.butterflyGlass,
        dragonEmber => ChatIllustratedTheme.dragonEmber,
        midnightRose => ChatIllustratedTheme.midnightRose,
        cloudFeather => ChatIllustratedTheme.cloudFeather,
        moonRabbit => ChatIllustratedTheme.moonRabbit,
        abyssGlow => ChatIllustratedTheme.abyssGlow,
        foxCharm => ChatIllustratedTheme.foxCharm,
        creamBakery => ChatIllustratedTheme.creamBakery,
        streetGraffiti => ChatIllustratedTheme.streetGraffiti,
        vinylJazz => ChatIllustratedTheme.vinylJazz,
        crimsonPhoenix => ChatIllustratedTheme.crimsonPhoenix,
        frostPalace => ChatIllustratedTheme.frostPalace,
        fireflyGrove => ChatIllustratedTheme.fireflyGrove,
        cherrySoda => ChatIllustratedTheme.cherrySoda,
        honeyGarden => ChatIllustratedTheme.honeyGarden,
        pandaBamboo => ChatIllustratedTheme.pandaBamboo,
        shibaPost => ChatIllustratedTheme.shibaPost,
        catMagic => ChatIllustratedTheme.catMagic,
        orbitalVoyage => ChatIllustratedTheme.orbitalVoyage,
        circuitMatrix => ChatIllustratedTheme.circuitMatrix,
        jadeFiligree => ChatIllustratedTheme.jadeFiligree,
        dunhuangRibbons => ChatIllustratedTheme.dunhuangRibbons,
        imperialPeony => ChatIllustratedTheme.imperialPeony,
        bluePorcelain => ChatIllustratedTheme.bluePorcelain,
        koiLotus => ChatIllustratedTheme.koiLotus,
        ginkgoLetter => ChatIllustratedTheme.ginkgoLetter,
        mushroomFable => ChatIllustratedTheme.mushroomFable,
        carnivalDream => ChatIllustratedTheme.carnivalDream,
        orangeSummer => ChatIllustratedTheme.orangeSummer,
        royalChess => ChatIllustratedTheme.royalChess,
        _ => null,
      };

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
    if (illustration case final illustrated?) {
      return illustrated.bubbleColor(dark: dark, isUser: isUser);
    }
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
      _ => theme.colorScheme.primaryContainer,
    };
    return dark
        ? Color.lerp(const Color(0xFF111827), accent, isUser ? .32 : .20)!
        : seed;
  }

  /// 渐层向同一对比度方向变化，保证整块气泡都能使用同一种正文颜色。
  List<Color> backgroundColors(Color base) =>
      (this == aurora || ornament != null || illustration != null)
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
  mecha('机甲', '六角徽章 · 能量护翼'),
  adventure('像素冒险', '宝石剑刃 · 森林像素'),
  neon('霓虹信号', '紫青光轨 · 全息信号'),
  crystal('海盐水晶', '晶莹海蓝 · 贝壳珍珠'),
  ink('墨染山河', '水墨竹影 · 朱砂落款'),
  plush('绒绒伙伴', '绒毛耳朵 · 软软爪印'),
  brass('黄铜航行', '黄铜齿轮 · 远航罗盘'),
  butterflyGlass('蝶影琉璃', '蝶翼轻舞 · 琉璃微光'),
  dragonEmber('龙焰赤金', '龙焰流动 · 赤金宝珠'),
  midnightRose('暗夜蔷薇', '蔷薇花雨 · 暗红宝石'),
  cloudFeather('云羽圣歌', '羽翼轻摆 · 云端星辉'),
  moonRabbit('月兔绮梦', '月兔桂香 · 玉穗轻摇'),
  abyssGlow('深海荧光', '水母浮游 · 深海流光'),
  foxCharm('狐火御守', '狐火闪烁 · 铃结轻摇'),
  creamBakery('奶油烘焙', '奶油甜梦 · 草莓心语'),
  streetGraffiti('街头涂鸦', '街头笔触 · 闪电节拍'),
  vinylJazz('黑胶爵士', '黑胶转动 · 黄铜爵士'),
  crimsonPhoenix('赤曜凤凰', '火羽流动 · 赤金流光'),
  frostPalace('霜月雪境', '冰晶闪耀 · 霜光环绕'),
  fireflyGrove('萤森秘语', '萤火轻舞 · 绿藤秘境'),
  cherrySoda('樱桃汽水', '樱桃气泡 · 清甜闪光'),
  honeyGarden('蜜蜂花园', '蜜光流淌 · 花间振翅'),
  pandaBamboo('竹影熊猫', '竹叶轻摇 · 熊猫眨眼'),
  shibaPost('柴犬邮局', '柴犬来信 · 邮笺飞舞'),
  catMagic('猫咪魔法', '星月流转 · 猫咪施法'),
  orbitalVoyage('星际航行', '星轨巡游 · 火箭启航'),
  circuitMatrix('电路矩阵', '电流脉冲 · 机械萌宠'),
  jadeFiligree('翡翠玲珑', '玉光流转 · 莲瓣轻舞'),
  dunhuangRibbons('敦煌飞天', '彩带飞扬 · 金铃流光'),
  imperialPeony('牡丹国色', '花瓣飘落 · 国色生香'),
  bluePorcelain('青花瓷韵', '青花流光 · 瓷珠轻摇'),
  koiLotus('锦鲤荷塘', '锦鲤游弋 · 荷塘涟漪'),
  ginkgoLetter('银杏秋信', '金叶飞舞 · 秋日来信'),
  mushroomFable('蘑菇童话', '蘑菇暖灯 · 森林魔法'),
  carnivalDream('游乐绮梦', '彩球轻摇 · 木马星光'),
  orangeSummer('甜橙夏日', '橙香流光 · 夏日花雨'),
  royalChess('皇家棋局', '王冠闪耀 · 黑金棋语');

  const ChatAvatarFrameStyle(this.label, this.description);
  final String label;
  final String description;

  ChatIllustratedTheme? get illustration => switch (this) {
        adventure => ChatIllustratedTheme.adventure,
        neon => ChatIllustratedTheme.neon,
        crystal => ChatIllustratedTheme.crystal,
        ink => ChatIllustratedTheme.ink,
        plush => ChatIllustratedTheme.plush,
        brass => ChatIllustratedTheme.brass,
        butterflyGlass => ChatIllustratedTheme.butterflyGlass,
        dragonEmber => ChatIllustratedTheme.dragonEmber,
        midnightRose => ChatIllustratedTheme.midnightRose,
        cloudFeather => ChatIllustratedTheme.cloudFeather,
        moonRabbit => ChatIllustratedTheme.moonRabbit,
        abyssGlow => ChatIllustratedTheme.abyssGlow,
        foxCharm => ChatIllustratedTheme.foxCharm,
        creamBakery => ChatIllustratedTheme.creamBakery,
        streetGraffiti => ChatIllustratedTheme.streetGraffiti,
        vinylJazz => ChatIllustratedTheme.vinylJazz,
        crimsonPhoenix => ChatIllustratedTheme.crimsonPhoenix,
        frostPalace => ChatIllustratedTheme.frostPalace,
        fireflyGrove => ChatIllustratedTheme.fireflyGrove,
        cherrySoda => ChatIllustratedTheme.cherrySoda,
        honeyGarden => ChatIllustratedTheme.honeyGarden,
        pandaBamboo => ChatIllustratedTheme.pandaBamboo,
        shibaPost => ChatIllustratedTheme.shibaPost,
        catMagic => ChatIllustratedTheme.catMagic,
        orbitalVoyage => ChatIllustratedTheme.orbitalVoyage,
        circuitMatrix => ChatIllustratedTheme.circuitMatrix,
        jadeFiligree => ChatIllustratedTheme.jadeFiligree,
        dunhuangRibbons => ChatIllustratedTheme.dunhuangRibbons,
        imperialPeony => ChatIllustratedTheme.imperialPeony,
        bluePorcelain => ChatIllustratedTheme.bluePorcelain,
        koiLotus => ChatIllustratedTheme.koiLotus,
        ginkgoLetter => ChatIllustratedTheme.ginkgoLetter,
        mushroomFable => ChatIllustratedTheme.mushroomFable,
        carnivalDream => ChatIllustratedTheme.carnivalDream,
        orangeSummer => ChatIllustratedTheme.orangeSummer,
        royalChess => ChatIllustratedTheme.royalChess,
        _ => null,
      };

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

/// 样卡默认按外框尺寸绘制；消息开启 preserveAvatarSize 时保留头像原尺寸，
/// 让布局为外围装饰预留空间，避免头像缩小或装饰挤入气泡。
class ChatAvatarFrame extends StatelessWidget {
  final ChatAvatarFrameStyle style;
  final double size;
  final Widget child;
  final bool preserveAvatarSize;

  const ChatAvatarFrame(
      {super.key,
      required this.style,
      required this.size,
      this.preserveAvatarSize = false,
      required this.child});

  double get _frameSize {
    if (!preserveAvatarSize || style == ChatAvatarFrameStyle.none) return size;
    final inset = style.illustration?.avatarInset ??
        (style.ornament == null ? .105 : .17);
    return size / (1 - 2 * inset);
  }

  @override
  Widget build(BuildContext context) {
    if (style == ChatAvatarFrameStyle.none) return child;
    final frameSize = _frameSize;
    if (style.illustration case final illustrated?) {
      return ChatIllustratedAvatarFrame(
          theme: illustrated, size: frameSize, child: child);
    }
    return SizedBox.square(
      dimension: frameSize,
      child: CustomPaint(
        foregroundPainter: _FramePainter(style, Theme.of(context).brightness),
        child: Padding(
          padding:
              EdgeInsets.all(frameSize * (style.ornament == null ? .105 : .17)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
                style == ChatAvatarFrameStyle.pixel
                    ? frameSize * .12
                    : frameSize),
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
      case ChatAvatarFrameStyle.adventure:
      case ChatAvatarFrameStyle.neon:
      case ChatAvatarFrameStyle.crystal:
      case ChatAvatarFrameStyle.ink:
      case ChatAvatarFrameStyle.plush:
      case ChatAvatarFrameStyle.brass:
      case ChatAvatarFrameStyle.butterflyGlass:
      case ChatAvatarFrameStyle.dragonEmber:
      case ChatAvatarFrameStyle.midnightRose:
      case ChatAvatarFrameStyle.cloudFeather:
      case ChatAvatarFrameStyle.moonRabbit:
      case ChatAvatarFrameStyle.abyssGlow:
      case ChatAvatarFrameStyle.foxCharm:
      case ChatAvatarFrameStyle.creamBakery:
      case ChatAvatarFrameStyle.streetGraffiti:
      case ChatAvatarFrameStyle.vinylJazz:
      case ChatAvatarFrameStyle.crimsonPhoenix:
      case ChatAvatarFrameStyle.frostPalace:
      case ChatAvatarFrameStyle.fireflyGrove:
      case ChatAvatarFrameStyle.cherrySoda:
      case ChatAvatarFrameStyle.honeyGarden:
      case ChatAvatarFrameStyle.pandaBamboo:
      case ChatAvatarFrameStyle.shibaPost:
      case ChatAvatarFrameStyle.catMagic:
      case ChatAvatarFrameStyle.orbitalVoyage:
      case ChatAvatarFrameStyle.circuitMatrix:
      case ChatAvatarFrameStyle.jadeFiligree:
      case ChatAvatarFrameStyle.dunhuangRibbons:
      case ChatAvatarFrameStyle.imperialPeony:
      case ChatAvatarFrameStyle.bluePorcelain:
      case ChatAvatarFrameStyle.koiLotus:
      case ChatAvatarFrameStyle.ginkgoLetter:
      case ChatAvatarFrameStyle.mushroomFable:
      case ChatAvatarFrameStyle.carnivalDream:
      case ChatAvatarFrameStyle.orangeSummer:
      case ChatAvatarFrameStyle.royalChess:
        return; // 插画头像框由独立的透明素材层绘制。
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
