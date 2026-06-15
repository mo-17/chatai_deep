import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatController _controller(List<MessageModel> msgs) => ChatController(
      initialMessageList: msgs,
      itemScrollController: ItemScrollController(),
      itemPositionsListener: ItemPositionsListener.create(),
      timePellet: 60,
    );

Widget _host(ChatController c) => MaterialApp(
      home: Scaffold(
        // 复刻 conversation_page._chatList 的外层：Expanded > Stack > ChatList
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [ChatList(chatController: c)],
              ),
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('空会话（新建对话）渲染不红屏', (tester) async {
    await tester.pumpWidget(_host(_controller([])));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('有消息时渲染不红屏', (tester) async {
    await tester.pumpWidget(_host(_controller([
      MessageModel(ownerType: OwnerType.sender, content: '你好', createdAt: 1000),
      MessageModel(
          ownerType: OwnerType.receiver, content: '在的', createdAt: 1001),
    ])));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建空会话发首条消息后不红屏，且消息可见（不滚到空白）',
      (tester) async {
    final c = _controller([]);
    await tester.pumpWidget(_host(c));
    await tester.pump();
    // 复刻 _doInit：对新会话 loadMoreData([])。
    c.loadMoreData([]);
    await tester.pump();
    // 复刻发送：先加用户气泡，再加 AI 气泡（各自触发 scrollToLastMessage）。
    c.addMessage(
        MessageModel(ownerType: OwnerType.sender, content: '第一条', createdAt: 2000));
    await tester.pump();
    c.addMessage(
        MessageModel(ownerType: OwnerType.receiver, content: '回复', createdAt: 2001));
    await tester.pump();
    // 跑过滚动动画到稳态（对应真机滚完后的状态）。注意：不能用 pumpAndSettle —
    // 它会多跑若干帧把空白掩盖掉；这里固定步进到动画结束的那一帧。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    // 关键断言：消息真的渲染出来了。修复前锚点 positionedIndex=-1 只建中段
    // 空 sliver，首条消息不渲染 -> 滚到空白，这两个断言会 findsNothing。
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('回复'), findsOneWidget);
    // 最新消息（index 0）应在可见项里，而不是滚到空白处。
    final visible =
        c.itemPositionsListener.itemPositions.value.map((p) => p.index);
    expect(visible, contains(0));
  });
}
