import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:chat_message/widget/chat_animated_frame_image.dart';
import 'package:chat_message/widget/chat_illustrated_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('动态气泡离屏、后台、减少动态和 TickerMode 关闭时暂停', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    const theme = ChatIllustratedTheme.crimsonPhoenix;
    Widget host({bool reduced = false, bool ticker = true}) => MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!),
          home: TickerMode(
              enabled: ticker,
              child: Scaffold(
                  body: SingleChildScrollView(
                controller: controller,
                child: const Column(children: [
                  SizedBox(height: 1000),
                  SizedBox(
                      width: 240,
                      child: ChatIllustratedBubble(
                          theme: theme,
                          color: Colors.white,
                          colors: [Colors.white, Colors.white],
                          isUser: true,
                          child: Text('气泡独立播放，不改变正文。'))),
                  SizedBox(height: 1000),
                ]),
              ))),
        );
    String asset() => (tester
            .widget<Image>(find.descendant(
                of: find.byType(ChatAnimatedFrameImage),
                matching: find.byType(Image)))
            .image as ExactAssetImage)
        .assetName;
    Future<void> flush() async {
      await tester.pump();
      await tester.pump();
    }

    await tester.pumpWidget(host());
    await flush();
    expect(asset(), theme.bubblePosterAsset);
    controller.jumpTo(850);
    await flush();
    expect(asset(), theme.bubbleAsset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await flush();
    expect(asset(), theme.bubblePosterAsset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush();
    expect(asset(), theme.bubbleAsset);
    await tester.pumpWidget(host(reduced: true));
    await flush();
    expect(asset(), theme.bubblePosterAsset);
    await tester.pumpWidget(host(ticker: false));
    await flush();
    expect(asset(), theme.bubblePosterAsset);
    await tester.pumpWidget(host());
    await flush();
    expect(asset(), theme.bubbleAsset);
    controller.jumpTo(0);
    await flush();
    expect(asset(), theme.bubblePosterAsset);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('滚动离屏、系统减少动态、TickerMode 和后台均使用静态封面', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    const theme = ChatIllustratedTheme.dragonEmber;
    Widget host({bool reduced = false, bool ticker = true}) => MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!),
          home: TickerMode(
              enabled: ticker,
              child: Scaffold(
                body: SingleChildScrollView(
                    controller: controller,
                    child: const Column(children: [
                      SizedBox(height: 1000),
                      ChatIllustratedAvatarFrame(
                          theme: theme, size: 76, child: CircleAvatar()),
                      SizedBox(height: 1000),
                    ])),
              )),
        );
    String asset() {
      final image = tester.widget<Image>(find.descendant(
          of: find.byType(ChatAnimatedFrameImage),
          matching: find.byType(Image)));
      return ((image.image as ResizeImage).imageProvider as AssetImage)
          .assetName;
    }

    Future<void> flush() async {
      await tester.pump();
      await tester.pump();
    }

    await tester.pumpWidget(host());
    await flush();
    expect(asset(), theme.framePosterAsset);
    controller.jumpTo(850);
    await flush();
    expect(asset(), theme.frameAsset);
    // 真实生命周期先 inactive 再 paused；paused 后 Flutter 停止调度帧。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await flush();
    expect(asset(), theme.framePosterAsset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(asset(), theme.framePosterAsset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush();
    expect(asset(), theme.frameAsset);
    await tester.pumpWidget(host(reduced: true));
    await flush();
    expect(asset(), theme.framePosterAsset);
    await tester.pumpWidget(host(ticker: false));
    await flush();
    expect(asset(), theme.framePosterAsset);
    await tester.pumpWidget(host());
    await flush();
    expect(asset(), theme.frameAsset);
    controller.jumpTo(0);
    await flush();
    expect(asset(), theme.framePosterAsset);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
