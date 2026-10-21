import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/conversation_decoration_theme.dart';
import 'package:chatgpt_app_core/pages/chat_decoration_page.dart';
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

  test('整页跟随最近应用套装，开关持久化且两侧消息、全局风格各自保留', () {
    final provider = ThemeProvider()
      ..setTheme(colorName: 'teal')
      ..setVisualStyle(AppVisualStyle.anime);
    provider.applyDecorationSet(
        isUser: true, theme: ChatIllustratedTheme.crimsonPhoenix);
    provider.applyDecorationSet(
        isUser: false, theme: ChatIllustratedTheme.frostPalace);
    expect(provider.conversationDecoration, ChatIllustratedTheme.frostPalace);
    provider.setFollowConversationDecoration(false);
    final restored = ThemeProvider();
    expect(restored.followConversationDecoration, isFalse);
    expect(restored.conversationDecoration, isNull);
    expect(restored.bubbleStyle(isUser: true), ChatBubbleStyle.crimsonPhoenix);
    expect(restored.bubbleStyle(isUser: false), ChatBubbleStyle.frostPalace);
    expect(restored.visualStyle, AppVisualStyle.anime);
    expect(restored.themeColorName, 'teal');
    restored.setFollowConversationDecoration(true);
    expect(ThemeProvider().conversationDecoration,
        ChatIllustratedTheme.frostPalace);
    restored.resetChatDecoration();
    expect(ThemeProvider().conversationDecoration, isNull);
    expect(ThemeProvider().followConversationDecoration, isTrue);
    provider.dispose();
    restored.dispose();
  });

  test('旧消息装扮可迁移为对话界面，未知配置安全回退', () {
    HiCache.getInstance()
      ..setString(ThemeProvider.keyUserBubbleStyle, 'bluePorcelain')
      ..setString(ThemeProvider.keyConversationDecoration, 'future-theme');
    final provider = ThemeProvider();
    expect(provider.conversationDecoration, ChatIllustratedTheme.bluePorcelain);
    provider.dispose();
  });

  test('全部插画套装的明暗界面正文、输入文字及按钮对比度合格', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
    }

    for (final decoration in ChatIllustratedTheme.values) {
      for (final brightness in Brightness.values) {
        final base =
            ThemeData(brightness: brightness, fontFamily: 'FixtureFont');
        final themed = ConversationDecorationTheme.apply(base, decoration);
        final skin = themed.extension<ConversationDecorationTheme>()!;
        expect(themed.textTheme.bodyLarge?.fontFamily,
            base.textTheme.bodyLarge?.fontFamily);
        for (final surface in [skin.background, skin.panel, skin.input]) {
          expect(contrast(themed.colorScheme.onSurface, surface),
              greaterThanOrEqualTo(4.5),
              reason: '${decoration.name} $brightness');
        }
        expect(
            contrast(themed.colorScheme.onPrimary, themed.colorScheme.primary),
            greaterThanOrEqualTo(4.5));
        expect(base.extension<ConversationDecorationTheme>(), isNull);
      }
    }
  });

  testWidgets('装扮页同步预览顶部栏和输入区，关闭整页联动保留消息装扮', (tester) async {
    final provider = ThemeProvider()
      ..applyDecorationSet(
          isUser: true, theme: ChatIllustratedTheme.crimsonPhoenix);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!),
            home: const ChatDecorationPage())));
    expect(find.byKey(const ValueKey('conversation_composer_preview')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('conversation_decoration_backdrop')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('follow_conversation_decoration')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation_composer_preview')),
        findsNothing);
    expect(provider.bubbleStyle(isUser: true), ChatBubbleStyle.crimsonPhoenix);
    expect(ThemeProvider().followConversationDecoration, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });
}
