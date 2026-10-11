import 'dart:async';

import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/chat/ui/interactive_card_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'interactive_card_test.dart'
    show checklistJson, comparisonJson, cardFence;

void main() {
  Future<void> host(WidgetTester tester, ChatBlockStore store,
          {bool enabled = true,
          bool completed = true,
          bool writable = true,
          bool dark = false}) =>
      tester.pumpWidget(ChangeNotifierProvider.value(
          value: store,
          child: MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              home: Scaffold(
                  body: SingleChildScrollView(
                      child: BlockMessageContent(
                          messageKey: 'msg_1',
                          enableInteractiveCards: enabled,
                          cardReplyCompleted: completed,
                          cardsWritable: writable,
                          cardScopeCurrent: () => true))))));
  MainTextBlock mainText(String content, {String id = 'main'}) => MainTextBlock(
      id: id,
      messageId: 'msg_1',
      createdAt: 1,
      status: MessageBlockStatus.success,
      content: content);

  testWidgets('默认关闭，流式保持原文，最终无写绑定只读', (tester) async {
    final raw = cardFence(checklistJson());
    final store = ChatBlockStore()..seedMessage('msg_1', [mainText(raw)]);
    await host(tester, store, enabled: false);
    expect(find.byType(InteractiveCardView), findsNothing);
    expect(find.text(raw), findsOneWidget);
    await host(tester, store, completed: false);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text(raw), findsOneWidget);
    await host(tester, store, writable: false);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged,
        isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });
  testWidgets('翻译、思考、工具中的相同正文不成为卡片；错误回复只读', (tester) async {
    final raw = cardFence(checklistJson());
    final store = ChatBlockStore()
      ..seedMessage('msg_1', [
        TranslationBlock(
            id: 't',
            messageId: 'msg_1',
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: raw),
        ThinkingBlock(
            id: 'thinking',
            messageId: 'msg_1',
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: raw),
        ToolBlock(
            id: 'tool',
            messageId: 'msg_1',
            createdAt: 1,
            status: MessageBlockStatus.success,
            toolId: 'x',
            content: raw),
      ]);
    await host(tester, store);
    expect(find.byType(InteractiveCardView), findsNothing);
    store.seedMessage('msg_1', [
      mainText(raw),
      const ErrorBlock(
          id: 'e',
          messageId: 'msg_1',
          createdAt: 1,
          status: MessageBlockStatus.success,
          message: 'fixture')
    ]);
    store.commitSeed();
    await tester.pump();
    expect(find.byType(InteractiveCardView), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged,
        isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });
  testWidgets('分块共享四卡和正文扫描预算', (tester) async {
    final raw = cardFence(checklistJson());
    final store = ChatBlockStore()
      ..seedMessage(
          'msg_1', [mainText(raw * 3), mainText(raw * 2, id: 'second')]);
    await host(tester, store);
    expect(find.byType(InteractiveCardView), findsNWidgets(4));
    expect(find.text(raw), findsOneWidget);
    store.seedMessage(
        'msg_1', [mainText(raw), mainText('a' * (512 * 1024), id: 'second')]);
    store.commitSeed();
    await tester.pump();
    expect(find.byType(InteractiveCardView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });
  for (final dark in [false, true]) {
    testWidgets('320pt ${dark ? '暗色' : '浅色'} 对比纵向完整显示，长文本不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final comparison = comparisonJson();
      comparison['rows'][0]['values']['a'] =
          '长值 https://example.com <script>不可执行</script> ' * 6;
      final store = ChatBlockStore()
        ..seedMessage('msg_1', [
          mainText('${cardFence(checklistJson())}${cardFence(comparison)}')
        ]);
      await host(tester, store, dark: dark);
      expect(find.text('方案比较'), findsOneWidget);
      expect(find.text('方案 B：较高'), findsOneWidget);
      for (final element in find.byType(CheckboxListTile).evaluate()) {
        expect(tester.getSize(find.byWidget(element.widget)).height,
            greaterThanOrEqualTo(44));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });
  }
  testWidgets('保存成功之前不改变值，同一卡提交期间不能重复点击或导出', (tester) async {
    final projection = InteractiveCardParser.parse(cardFence(checklistJson()))
        .whereType<CardProjection>()
        .single;
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: InteractiveCardView(
                projection: projection,
                writable: true,
                insertEnabled: true,
                isCurrent: () => true,
                onCheck: (id, value) async {
                  calls++;
                  await pending.future;
                },
                onInsert: (_) {}))));
    final check = find.byType(CheckboxListTile).first;
    await tester.tap(check);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(check).value, isFalse);
    expect(tester.widget<CheckboxListTile>(check).onChanged, isNull);
    expect(
        tester
            .widget<TextButton>(find.ancestor(
                of: find.text('复制'),
                matching: find.byWidgetPredicate((w) => w is TextButton)))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.ancestor(
                of: find.text('插入输入框'),
                matching: find.byWidgetPredicate((w) => w is TextButton)))
            .onPressed,
        isNull);
    expect(calls, 1);
    pending.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(check).value, isFalse);
  });
}
