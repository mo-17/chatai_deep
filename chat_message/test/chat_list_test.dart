import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:bubble/bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatController _controller(List<MessageModel> msgs,
        {MessageContentBuilder? contentBuilder}) =>
    ChatController(
      initialMessageList: msgs,
      itemScrollController: ItemScrollController(),
      itemPositionsListener: ItemPositionsListener.create(),
      timePellet: 60,
      messageContentBuilder: contentBuilder,
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

  testWidgets('新建空会话发首条消息后不红屏，且消息可见（不滚到空白）', (tester) async {
    final c = _controller([]);
    await tester.pumpWidget(_host(c));
    await tester.pump();
    // 复刻 _doInit：对新会话 loadMoreData([])。
    c.loadMoreData([]);
    await tester.pump();
    // 复刻发送：先加用户气泡，再加 AI 气泡（各自触发 scrollToLastMessage）。
    c.addMessage(MessageModel(
        ownerType: OwnerType.sender, content: '第一条', createdAt: 2000));
    await tester.pump();
    c.addMessage(MessageModel(
        ownerType: OwnerType.receiver, content: '回复', createdAt: 2001));
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

  for (final delay in [Duration.zero, const Duration(milliseconds: 16)]) {
    testWidgets('首轮连续插入用户消息和流式占位后立即可见（$delay）', (tester) async {
      final c = _controller([]);
      await tester.pumpWidget(_host(c));
      await tester.pump();
      c.loadMoreData([]);
      await tester.pump();

      c.addMessage(MessageModel(
          ownerType: OwnerType.sender, content: '首轮提问', createdAt: 3000));
      if (delay != Duration.zero) await tester.pump(delay);
      final reply = MessageModel(
          ownerType: OwnerType.receiver, content: '', createdAt: 3001);
      c.addMessage(reply);
      await tester.pump();
      c.updateMessage(reply.copyWith(content: '首轮流式回复'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('首轮提问').hitTestable(), findsOneWidget);
      expect(find.text('首轮流式回复').hitTestable(), findsOneWidget);
      expect(c.itemPositionsListener.itemPositions.value.map((p) => p.index),
          contains(0));
    });
  }

  testWidgets('首轮回复独立流式更新时双方消息保持可见', (tester) async {
    final replyText = ValueNotifier('');
    final c = _controller([], contentBuilder: (_, message) {
      if (message.ownerType != OwnerType.receiver) return null;
      return ValueListenableBuilder<String>(
        valueListenable: replyText,
        builder: (_, text, __) => Text(text.isEmpty ? '正在回复' : text),
      );
    });
    await tester.pumpWidget(_host(c));
    await tester.pump();
    c.loadMoreData([]);
    await tester.pump();

    c.addMessage(MessageModel(
        ownerType: OwnerType.sender, content: '流式提问', createdAt: 4000));
    await tester.pump(const Duration(milliseconds: 16));
    final reply = MessageModel(
        ownerType: OwnerType.receiver, content: '', createdAt: 4001);
    c.addMessage(reply);
    await tester.pump();
    for (final text in ['第一段', '第一段\n第二段', '第一段\n第二段\n第三段']) {
      // 复刻块渲染：token 只刷新气泡内部，列表消息仍为空占位。
      replyText.value = text;
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text(text).hitTestable(), findsOneWidget);
      expect(find.text('流式提问').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    c.updateMessage(reply.copyWith(content: replyText.value));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(replyText.value).hitTestable(), findsOneWidget);
    expect(find.text('流式提问').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    replyText.dispose();
  });

  testWidgets('删空消息后再次发送首轮无需重进页面', (tester) async {
    final old = MessageModel(
        ownerType: OwnerType.sender, content: '待删除', createdAt: 5000);
    final c = _controller([old]);
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();
    c.deleteMessage(old);
    await tester.pump();
    await tester.pump();
    expect(find.text('待删除'), findsNothing);

    c.addMessage(MessageModel(
        ownerType: OwnerType.sender, content: '重新提问', createdAt: 5001));
    c.addMessage(MessageModel(
        ownerType: OwnerType.receiver, content: '重新回复', createdAt: 5002));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('重新提问').hitTestable(), findsOneWidget);
    expect(find.text('重新回复').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义风格参数会传递到双方气泡与头像', (tester) async {
    const receiverBubble = Color(0xFFEDE9FE);
    const senderBubble = Color(0xFFFCE7F3);
    const receiverAvatar = Color(0xFF6D28D9);
    const senderAvatar = Color(0xFFBE185D);
    final controller = _controller([
      MessageModel(
        ownerType: OwnerType.sender,
        ownerName: 'U',
        content: '你好',
        createdAt: 1000,
      ),
      MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: 'A',
        content: '在的',
        createdAt: 1001,
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatList(
            chatController: controller,
            receiverBackgroundColor: receiverBubble,
            senderBackgroundColor: senderBubble,
            receiverAvatarBackgroundColor: receiverAvatar,
            senderAvatarBackgroundColor: senderAvatar,
            textColor: const Color(0xFF1E1B2E),
            bubbleRadius: const Radius.circular(18),
          ),
        ),
      ),
    );
    await tester.pump();

    final bubbleColors =
        tester.widgetList<Bubble>(find.byType(Bubble)).map((b) => b.color);
    final avatarColors = tester
        .widgetList<CircleAvatar>(find.byType(CircleAvatar))
        .map((avatar) => avatar.backgroundColor);
    final radii = tester
        .widgetList<Bubble>(find.byType(Bubble))
        .map((bubble) => bubble.bubbleClipper.radius);
    expect(bubbleColors, containsAll([receiverBubble, senderBubble]));
    expect(avatarColors, containsAll([receiverAvatar, senderAvatar]));
    expect(radii, everyElement(const Radius.circular(18)));
    expect(tester.takeException(), isNull);
  });
}
