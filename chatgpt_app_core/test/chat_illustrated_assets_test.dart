import 'dart:ui' as ui;

import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:chat_message/widget/chat_illustrated_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('六张气泡边框可解码，九宫格尺寸匹配且正文裁剪区域完整', (tester) async {
    final logicalImage = Offset.zero &
        (ChatIllustratedTheme.bubbleAssetSize /
            ChatIllustratedTheme.bubbleAssetScale);
    expect(
        logicalImage.contains(ChatIllustratedTheme.bubbleCenterSlice.topLeft),
        isTrue);
    expect(
        logicalImage
            .contains(ChatIllustratedTheme.bubbleCenterSlice.bottomRight),
        isTrue);
    await tester.runAsync(() async {
      for (final theme in ChatIllustratedTheme.values) {
        final bytes =
            await rootBundle.load('packages/chat_message/${theme.bubbleAsset}');
        final codec =
            await ui.instantiateImageCodec(bytes.buffer.asUint8List());
        final image = (await codec.getNextFrame()).image;
        expect(Size(image.width.toDouble(), image.height.toDouble()),
            ChatIllustratedTheme.bubbleAssetSize);
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        Future<ByteData> paintBorder(Size size) async {
          final recorder = ui.PictureRecorder();
          paintImage(
              canvas: Canvas(recorder),
              rect: Offset.zero & size,
              image: image,
              scale: ChatIllustratedTheme.bubbleAssetScale,
              centerSlice: ChatIllustratedTheme.bubbleCenterSlice,
              fit: BoxFit.fill);
          final picture = recorder.endRecording();
          final rendered =
              await picture.toImage(size.width.toInt(), size.height.toInt());
          final result =
              (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          rendered.dispose();
          picture.dispose();
          return result;
        }

        final short = await paintBorder(const Size(112, 86));
        final long = await paintBorder(const Size(320, 700));
        // 消息宽高变化时，左上角素材保持原比例；只伸缩中间边缘。
        for (var y = 0; y < 30; y++) {
          for (var x = 0; x < 30; x++) {
            expect(short.getUint32((y * 112 + x) * 4),
                long.getUint32((y * 320 + x) * 4),
                reason: '${theme.name} fixed corner $x,$y');
          }
        }
        expect(
            data.getUint8(
                ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4 + 3),
            lessThan(3),
            reason: '${theme.name} bubble center');
        image.dispose();
        codec.dispose();
      }
    });
    for (final size in [const Size(100, 86), const Size(320, 1000)]) {
      final clip = const ChatBubbleBorderClipper().getClip(size);
      final body =
          ChatIllustratedBubble.padding.deflateRect(Offset.zero & size);
      expect(clip.contains(body.center), isFalse);
      expect(clip.contains(body.topLeft + const Offset(.5, .5)), isFalse);
      expect(clip.contains(body.bottomRight - const Offset(.5, .5)), isFalse);
      expect(clip.contains(const Offset(3, 3)), isTrue);
    }
  });

  testWidgets('依赖包的六张插画素材可真实解码，中心和外角保持透明', (tester) async {
    await tester.runAsync(() async {
      for (final theme in ChatIllustratedTheme.values) {
        final bytes =
            await rootBundle.load('packages/chat_message/${theme.frameAsset}');
        final codec =
            await ui.instantiateImageCodec(bytes.buffer.asUint8List());
        final image = (await codec.getNextFrame()).image;
        expect(image.width, image.height);
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        int alpha(double x, double y) =>
            data.getUint8(((y * (image.height - 1)).round() * image.width +
                        (x * (image.width - 1)).round()) *
                    4 +
                3);
        for (final x in [.01, .99]) {
          for (final y in [.01, .99]) {
            expect(alpha(x, y), lessThan(3),
                reason: '${theme.name} outer corner');
          }
        }
        for (var x = .40; x <= .60; x += .04) {
          for (var y = .40; y <= .60; y += .04) {
            expect(alpha(x, y), lessThan(3),
                reason: '${theme.name} avatar hole');
          }
        }
        expect(alpha(.5, .15), greaterThan(100),
            reason: '${theme.name} visible ring');
        image.dispose();
        codec.dispose();
      }
    });
  });

  test('六组装扮可跨 Provider 重建保存，两侧和原有自定义颜色互不覆盖', () async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    for (final theme in ChatIllustratedTheme.values) {
      final bubble = ChatBubbleStyle.fromStorage(theme.name);
      final frame = ChatAvatarFrameStyle.fromStorage(theme.name);
      final provider = ThemeProvider()
        ..setBubbleStyle(isUser: true, style: bubble)
        ..setAvatarFrame(isUser: true, style: frame)
        ..setBubbleStyle(isUser: false, style: ChatBubbleStyle.paper)
        ..setAvatarFrame(isUser: false, style: ChatAvatarFrameStyle.mint)
        ..setBubbleColor(isUser: true, color: const Color(0xFF789ABC));
      await HiCache.getInstance().prefs!.reload();
      final restored = ThemeProvider();
      expect(restored.bubbleStyle(isUser: true).illustration, theme);
      expect(restored.avatarFrame(isUser: true).illustration, theme);
      expect(restored.bubbleStyle(isUser: false), ChatBubbleStyle.paper);
      expect(restored.avatarFrame(isUser: false), ChatAvatarFrameStyle.mint);
      expect(restored.bubbleColor(ThemeData(), isUser: true),
          const Color(0xFF789ABC));
      provider.dispose();
      restored.dispose();
    }
  });
}
