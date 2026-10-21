import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';

import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:chat_message/widget/chat_illustrated_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('完整头像框组件在头像外侧真实绘制素材像素', (tester) async {
    final key = GlobalKey();
    const theme = ChatIllustratedTheme.dragonEmber;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Center(
            child: RepaintBoundary(
          key: key,
          child: const ChatIllustratedAvatarFrame(
              theme: theme, size: 256, child: ColoredBox(color: Colors.blue)),
        )),
      ),
    ));
    await tester.runAsync(() => precacheImage(
        const ResizeImage(
            AssetImage('assets/decoration/dragonEmber_frame_poster.webp',
                package: 'chat_message'),
            width: 256,
            height: 256),
        key.currentContext!));
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final rgba =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      var pixels = 0;
      for (var y = 0; y < 256; y++) {
        for (var x = 0; x < 256; x++) {
          if (x >= 56 && x < 200 && y >= 56 && y < 200) continue;
          if (rgba.getUint8((y * 256 + x) * 4 + 3) > 100) pixels++;
        }
      }
      expect(pixels, greaterThan(1000));
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全部气泡边框可解码，九宫格尺寸匹配且正文裁剪区域完整', (tester) async {
    await tester.runAsync(() async {
      for (final theme in ChatIllustratedTheme.values) {
        final logicalImage =
            Offset.zero & (theme.bubbleSize / theme.bubbleScale);
        expect(logicalImage.contains(theme.centerSlice.topLeft), isTrue);
        expect(logicalImage.contains(theme.centerSlice.bottomRight), isTrue);
        final bytes =
            await rootBundle.load('packages/chat_message/${theme.bubbleAsset}');
        final codec =
            await ui.instantiateImageCodec(bytes.buffer.asUint8List());
        final image = (await codec.getNextFrame()).image;
        expect(Size(image.width.toDouble(), image.height.toDouble()),
            theme.bubbleSize);
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        Future<ByteData> paintBorder(Size size) async {
          final recorder = ui.PictureRecorder();
          paintImage(
              canvas: Canvas(recorder),
              rect: Offset.zero & size,
              image: image,
              scale: theme.bubbleScale,
              centerSlice: theme.centerSlice,
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

  testWidgets('全部插画头像框可真实解码，中心和外角保持透明', (tester) async {
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
        if (!theme.animated) {
          expect(alpha(.5, .15), greaterThan(100),
              reason: '${theme.name} visible ring');
        }
        image.dispose();
        codec.dispose();
      }
    });
  });

  testWidgets('三十套动态头像框均有独立画面、正确时长、透明头像孔与封面', (tester) async {
    final animated = ChatIllustratedTheme.values.where((t) => t.animated);
    expect(animated.length, 30);
    await tester.runAsync(() async {
      for (final theme in animated) {
        final data =
            await rootBundle.load('packages/chat_message/${theme.frameAsset}');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frames = theme.animatedBubble ? 6 : 9;
        expect(codec.frameCount, frames);
        final hashes = <String>{};
        for (var frame = 0; frame < codec.frameCount; frame++) {
          final info = await codec.getNextFrame();
          expect(info.duration,
              Duration(milliseconds: theme.animatedBubble ? 180 : 120));
          final image = info.image;
          expect(Size(image.width.toDouble(), image.height.toDouble()),
              const Size(256, 256));
          final rgba =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          expect(rgba.getUint8((128 * 256 + 128) * 4 + 3), 0);
          hashes.add(sha256.convert(rgba.buffer.asUint8List()).toString());
          image.dispose();
        }
        expect(hashes.length, frames, reason: theme.name);
        codec.dispose();
        final poster = await rootBundle
            .load('packages/chat_message/${theme.framePosterAsset}');
        final posterCodec =
            await ui.instantiateImageCodec(poster.buffer.asUint8List());
        expect(posterCodec.frameCount, 1);
        (await posterCodec.getNextFrame()).image.dispose();
        posterCodec.dispose();
      }
    });
  });

  testWidgets('新增二十套气泡均有六帧、透明中心、配套封面和正确时长', (tester) async {
    final paired =
        ChatIllustratedTheme.values.where((theme) => theme.animatedBubble);
    expect(paired.length, 20);
    await tester.runAsync(() async {
      for (final theme in paired) {
        final bytes =
            await rootBundle.load('packages/chat_message/${theme.bubbleAsset}');
        final codec =
            await ui.instantiateImageCodec(bytes.buffer.asUint8List());
        expect(codec.frameCount, 6, reason: theme.name);
        final hashes = <String>{};
        for (var i = 0; i < codec.frameCount; i++) {
          final info = await codec.getNextFrame();
          expect(info.duration, const Duration(milliseconds: 180));
          final rgba = (await info.image
              .toByteData(format: ui.ImageByteFormat.rawRgba))!;
          expect(rgba.getUint8((160 * 512 + 256) * 4 + 3), 0,
              reason: theme.name);
          hashes.add(sha256.convert(rgba.buffer.asUint8List()).toString());
          info.image.dispose();
        }
        expect(hashes.length, 6, reason: theme.name);
        codec.dispose();
        final poster = await rootBundle
            .load('packages/chat_message/${theme.bubblePosterAsset}');
        final still =
            await ui.instantiateImageCodec(poster.buffer.asUint8List());
        expect(still.frameCount, 1);
        (await still.getNextFrame()).image.dispose();
        still.dispose();
      }
    });
  });

  test('全部插画装扮可跨 Provider 重建保存，两侧和原有自定义颜色互不覆盖', () async {
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
