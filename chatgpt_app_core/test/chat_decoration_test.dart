import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:chatgpt_app_core/pages/appearance_settings_page.dart';
import 'package:chatgpt_app_core/pages/chat_decoration_page.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
  });

  test('两侧装扮分别持久化，旧配置和未知款式安全回退', () async {
    final provider = ThemeProvider();
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.classic);
    expect(provider.avatarFrame(isUser: false), ChatAvatarFrameStyle.none);
    provider.setBubbleStyle(isUser: true, style: ChatBubbleStyle.aurora);
    provider.setBubbleStyle(isUser: false, style: ChatBubbleStyle.paper);
    provider.setAvatarFrame(isUser: true, style: ChatAvatarFrameStyle.orbit);
    provider.setAvatarFrame(isUser: false, style: ChatAvatarFrameStyle.gold);
    provider.setBubbleColor(isUser: false, color: const Color(0xFF123456));
    await HiCache.getInstance().prefs!.reload();
    final restored = ThemeProvider();
    expect(restored.bubbleStyle(isUser: true), ChatBubbleStyle.aurora);
    expect(restored.bubbleStyle(isUser: false), ChatBubbleStyle.paper);
    expect(restored.avatarFrame(isUser: true), ChatAvatarFrameStyle.orbit);
    expect(restored.avatarFrame(isUser: false), ChatAvatarFrameStyle.gold);
    expect(restored.bubbleColor(ThemeData(), isUser: false),
        const Color(0xFF123456));
    HiCache.getInstance().setString(ThemeProvider.keyUserBubbleStyle, 'future');
    HiCache.getInstance().setString(ThemeProvider.keyAiAvatarFrame, 'future');
    final future = ThemeProvider();
    expect(future.bubbleStyle(isUser: true), ChatBubbleStyle.classic);
    expect(future.avatarFrame(isUser: false), ChatAvatarFrameStyle.none);
    expect(future.bubbleStyle(isUser: false), ChatBubbleStyle.paper);
  });

  test('恢复装扮同时清除自定义颜色，保留主题和头像开关', () {
    final provider = ThemeProvider()
      ..setTheme(colorName: 'teal')
      ..setVisualStyle(AppVisualStyle.anime)
      ..setShowMessageAvatars(false)
      ..setBubbleStyle(isUser: true, style: ChatBubbleStyle.pixel)
      ..setAvatarFrame(isUser: false, style: ChatAvatarFrameStyle.mint)
      ..setBubbleColor(isUser: true, color: Colors.black);
    provider.resetChatDecoration();
    final restored = ThemeProvider();
    for (final isUser in [true, false]) {
      expect(restored.bubbleStyle(isUser: isUser), ChatBubbleStyle.classic);
      expect(restored.avatarFrame(isUser: isUser), ChatAvatarFrameStyle.none);
    }
    expect(restored.userBubbleColor, isNull);
    expect(restored.themeColorName, 'teal');
    expect(restored.visualStyle, AppVisualStyle.anime);
    expect(restored.showMessageAvatars, isFalse);
  });

  Widget host(ThemeProvider provider,
          {Widget page = const ChatDecorationPage(),
          Brightness brightness = Brightness.light,
          double scale = 1}) =>
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF6558E8), brightness: brightness)),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true),
              child: child!),
          home: page,
        ),
      );

  Future<void> reveal(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  testWidgets('正式外观入口可进入装扮页并返回', (tester) async {
    await tester.pumpWidget(
        host(ThemeProvider(), page: const AppearanceSettingsPage()));
    await reveal(tester, 'open_chat_decoration');
    await tester.tap(find.byKey(const ValueKey('open_chat_decoration')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatDecorationPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceSettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击选择后预览与存储同步，两侧独立，隐藏头像有恢复入口', (tester) async {
    final provider = ThemeProvider()..setShowMessageAvatars(false);
    await tester.pumpWidget(host(provider));
    await reveal(tester, 'bubble_style_constellation');
    await tester.tap(find.byKey(const ValueKey('bubble_style_constellation')));
    await tester.pump();
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.constellation);
    await reveal(tester, 'avatar_frame_ribbon');
    await tester.tap(find.byKey(const ValueKey('avatar_frame_ribbon')));
    await tester.pump();
    expect(provider.avatarFrame(isUser: true), ChatAvatarFrameStyle.ribbon);
    await tester.scrollUntilVisible(find.text('显示头像'), -180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('显示头像'));
    await tester.pump();
    expect(provider.showMessageAvatars, isTrue);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('decoration_target')), -180,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 回复'));
    await tester.pump();
    await reveal(tester, 'bubble_style_mecha');
    await tester.tap(find.byKey(const ValueKey('bubble_style_mecha')));
    await tester.pump();
    expect(provider.bubbleStyle(isUser: false), ChatBubbleStyle.mecha);
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.constellation);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('chat_appearance_preview')), -180,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
    final messages = tester
        .widgetList<DefaultMessageWidget>(find.byType(DefaultMessageWidget))
        .toList();
    expect(messages[0].bubbleStyle, ChatBubbleStyle.constellation);
    expect(messages[0].avatarFrameStyle, ChatAvatarFrameStyle.ribbon);
    expect(messages[1].bubbleStyle, ChatBubbleStyle.mecha);
    expect(ThemeProvider().bubbleStyle(isUser: false), ChatBubbleStyle.mecha);
    await tester.tap(find.byKey(const ValueKey('reset_chat_decoration')));
    await tester.pump();
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.classic);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(844, 390)]) {
      testWidgets('小屏/横屏、大文字与明暗模式无溢出 $brightness $size', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final provider = ThemeProvider()
          ..setBubbleStyle(isUser: true, style: ChatBubbleStyle.aurora)
          ..setAvatarFrame(isUser: true, style: ChatAvatarFrameStyle.orbit);
        await tester
            .pumpWidget(host(provider, brightness: brightness, scale: 2));
        await reveal(tester, 'avatar_frame_pixel');
        await tester.tap(find.byKey(const ValueKey('avatar_frame_pixel')));
        await tester.pump();
        expect(provider.avatarFrame(isUser: true), ChatAvatarFrameStyle.pixel);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
