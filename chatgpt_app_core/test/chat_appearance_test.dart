import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/pages/appearance_settings_page.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  test('外观独立持久化、重建恢复且不覆盖强调色', () async {
    final provider = ThemeProvider();
    expect(provider.showMessageAvatars, isTrue);
    expect(provider.userBubbleColor, isNull);
    expect(provider.aiBubbleColor, isNull);
    provider.setTheme(colorName: 'teal');
    provider.setShowMessageAvatars(false);
    provider.setBubbleColor(isUser: true, color: const Color(0xFF123456));
    provider.setBubbleColor(isUser: false, color: const Color(0xFFFEDCBA));
    provider.setVisualStyle(AppVisualStyle.anime);
    await HiCache.getInstance().prefs!.reload();
    final reopened = ThemeProvider();
    expect(reopened.showMessageAvatars, isFalse);
    expect(reopened.userBubbleColor, const Color(0xFF123456));
    expect(reopened.aiBubbleColor, const Color(0xFFFEDCBA));
    expect(reopened.themeColorName, 'teal');
    reopened.setBubbleColor(isUser: true, color: null);
    final reset = ThemeProvider();
    expect(reset.userBubbleColor, isNull);
    expect(reset.aiBubbleColor, const Color(0xFFFEDCBA));
  });

  testWidgets('设置开关与两侧颜色独立修改，支持校验、取消和恢复主题', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(home: AppearanceSettingsPage()),
    ));
    Future<void> reveal(String key) async {
      await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    await reveal('show_message_avatars');
    await tester.tap(find.byKey(const ValueKey('show_message_avatars')));
    await tester.pumpAndSettle();
    expect(provider.showMessageAvatars, isFalse);
    for (final entry in {
      'user_bubble_color': '#123456',
      'ai_bubble_color': '#FEDCBA'
    }.entries) {
      await reveal(entry.key);
      await tester.tap(find.byKey(ValueKey(entry.key)));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('bubble_color_hex')), 'oops');
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的 6 位颜色'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('bubble_color_hex')), entry.value);
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
    }
    expect(provider.userBubbleColor, const Color(0xFF123456));
    expect(provider.aiBubbleColor, const Color(0xFFFEDCBA));
    await tester.tap(find.byKey(const ValueKey('user_bubble_color')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('bubble_color_hex')), '#000000');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(provider.userBubbleColor, const Color(0xFF123456));
    await tester.tap(find.byKey(const ValueKey('user_bubble_color')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随主题').last);
    await tester.pumpAndSettle();
    expect(provider.userBubbleColor, isNull);
    expect(provider.aiBubbleColor, const Color(0xFFFEDCBA));
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('明暗主题 $dark：富文本引用、代码块可选并保留链接操作', (tester) async {
      String? copied;
      final launched = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(launcher, (call) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map)['url'] as String);
        }
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(launcher, null);
      });
      const messageKey = 'selection';
      final store = ChatBlockStore()
        ..seedMessage(messageKey, const [
          MainTextBlock(
              id: 'main',
              messageId: messageKey,
              createdAt: 1,
              status: MessageBlockStatus.success,
              content: 'Rich text reference[1] and **Markdown**.'),
          CodeBlock(
              id: 'code',
              messageId: messageKey,
              createdAt: 1,
              status: MessageBlockStatus.success,
              content: 'print("hello");'),
          CitationBlock(
              id: 'citation',
              messageId: messageKey,
              createdAt: 1,
              status: MessageBlockStatus.success,
              webResults: [
                WebSearchResult(title: 'Source', url: 'https://example.com')
              ]),
        ])
        ..commitSeed();
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(
              body: DefaultMessageWidget(
            key: GlobalKey(),
            showAvatars: false,
            receiverBackgroundColor:
                dark ? const Color(0xFF102030) : const Color(0xFFFEDCBA),
            message: MessageModel(
                ownerType: OwnerType.receiver, content: '', createdAt: 1),
            contentBuilder: (_, __) =>
                const BlockMessageContent(messageKey: messageKey),
          )),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('print("hello");'), findsOneWidget);
      final textContext = tester.element(find.byType(BlockMessageContent));
      expect(Theme.of(textContext).colorScheme.onSurface,
          dark ? Colors.white : Colors.black);
      final region =
          tester.state<SelectableRegionState>(find.byType(SelectableRegion));
      region.selectAll();
      await tester.pumpAndSettle();
      region.contextMenuButtonItems
          .firstWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(copied, contains('Rich text reference'));
      expect(copied, contains('[1]'));
      expect(copied, contains('**Markdown**'));
      expect(copied, contains('print("hello");'));
      await tester.tap(find.text('[1]').first);
      await tester.pump();
      expect(launched, ['https://example.com']);
      expect(tester.takeException(), isNull);
    });
  }
}
