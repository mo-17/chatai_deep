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

  testWidgets('新建空会话后发首条消息（addMessage 触发 scrollTo）不红屏',
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
        MessageModel(ownerType: OwnerType.receiver, content: '', createdAt: 2001));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
