import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_illustrated_theme.dart';
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

  test('整套选择只清除当前侧的自定义色，另一侧及头像开关保持不变', () {
    final provider = ThemeProvider()
      ..setShowMessageAvatars(false)
      ..setBubbleStyle(isUser: false, style: ChatBubbleStyle.paper)
      ..setAvatarFrame(isUser: false, style: ChatAvatarFrameStyle.mint)
      ..setBubbleColor(isUser: false, color: Colors.green)
      ..setBubbleColor(isUser: true, color: Colors.black);
    var updates = 0;
    provider.addListener(() => updates++);
    provider.applyDecorationSet(
        isUser: true, theme: ChatIllustratedTheme.foxCharm);
    expect(updates, 1);
    final restored = ThemeProvider();
    expect(restored.bubbleStyle(isUser: true), ChatBubbleStyle.foxCharm);
    expect(restored.avatarFrame(isUser: true), ChatAvatarFrameStyle.foxCharm);
    expect(restored.userBubbleColor, isNull);
    expect(restored.bubbleStyle(isUser: false), ChatBubbleStyle.paper);
    expect(restored.avatarFrame(isUser: false), ChatAvatarFrameStyle.mint);
    expect(restored.aiBubbleColor, const Color(0xFF4CAF50));
    expect(restored.showMessageAvatars, isFalse);
    provider.dispose();
    restored.dispose();
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
        maxScrolls: 100, scrollable: find.byType(Scrollable).first);
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

  testWidgets('三十套动态装扮都可整套选择并传入真实消息预览', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(host(provider));
    for (final theme in ChatIllustratedTheme.animatedSets) {
      final key = 'decoration_set_${theme.name}';
      await reveal(tester, key);
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      expect(provider.bubbleStyle(isUser: true).illustration, theme);
      expect(provider.avatarFrame(isUser: true).illustration, theme);
      expect(ThemeProvider().avatarFrame(isUser: true).illustration, theme);
    }
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('decoration_target')), -180,
        maxScrolls: 100, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('AI 回复'));
    await tester.pump();
    await reveal(tester, 'decoration_set_moonRabbit');
    await tester.tap(find.byKey(const ValueKey('decoration_set_moonRabbit')));
    await tester.pump();
    expect(provider.bubbleStyle(isUser: false), ChatBubbleStyle.moonRabbit);
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.vinylJazz);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('chat_appearance_preview')), -180,
        maxScrolls: 100, scrollable: find.byType(Scrollable).first);
    final messages = tester
        .widgetList<DefaultMessageWidget>(find.byType(DefaultMessageWidget))
        .toList();
    expect(messages[0].bubbleStyle, ChatBubbleStyle.vinylJazz);
    expect(messages[0].avatarFrameStyle, ChatAvatarFrameStyle.vinylJazz);
    expect(messages[1].bubbleStyle, ChatBubbleStyle.moonRabbit);
    expect(messages[1].avatarFrameStyle, ChatAvatarFrameStyle.moonRabbit);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });

  testWidgets('点击选择后预览与存储同步，两侧独立，隐藏头像有恢复入口', (tester) async {
    final provider = ThemeProvider()..setShowMessageAvatars(false);
    await tester.pumpWidget(host(provider));
    await reveal(tester, 'bubble_style_neon');
    await tester.tap(find.byKey(const ValueKey('bubble_style_neon')));
    await tester.pump();
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.neon);
    await reveal(tester, 'avatar_frame_plush');
    await tester.tap(find.byKey(const ValueKey('avatar_frame_plush')));
    await tester.pump();
    expect(provider.avatarFrame(isUser: true), ChatAvatarFrameStyle.plush);
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
    await reveal(tester, 'bubble_style_ink');
    await tester.tap(find.byKey(const ValueKey('bubble_style_ink')));
    await tester.pump();
    expect(provider.bubbleStyle(isUser: false), ChatBubbleStyle.ink);
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.neon);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('chat_appearance_preview')), -180,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
    final messages = tester
        .widgetList<DefaultMessageWidget>(find.byType(DefaultMessageWidget))
        .toList();
    expect(messages[0].bubbleStyle, ChatBubbleStyle.neon);
    expect(messages[0].avatarFrameStyle, ChatAvatarFrameStyle.plush);
    expect(messages[1].bubbleStyle, ChatBubbleStyle.ink);
    expect(ThemeProvider().bubbleStyle(isUser: false), ChatBubbleStyle.ink);
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
          ..setBubbleStyle(isUser: true, style: ChatBubbleStyle.neon)
          ..setAvatarFrame(isUser: true, style: ChatAvatarFrameStyle.plush);
        await tester
            .pumpWidget(host(provider, brightness: brightness, scale: 2));
        await tester.enterText(
            find.byKey(const ValueKey('decoration_search')), '像素');
        tester.testTextInput.hide();
        await tester.pump();
        await reveal(tester, 'avatar_frame_pixel');
        await tester.tap(find.byKey(const ValueKey('avatar_frame_pixel')));
        await tester.pump();
        expect(provider.avatarFrame(isUser: true), ChatAvatarFrameStyle.pixel);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
