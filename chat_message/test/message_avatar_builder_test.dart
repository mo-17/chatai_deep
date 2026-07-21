import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final message = MessageModel(
    ownerType: OwnerType.receiver,
    ownerName: '艾琳',
    avatar: 'asset:starcore_explorer',
    content: '你好',
    createdAt: 1000,
  );

  test('asset avatar protocol survives MessageModel JSON round-trip', () {
    final restored = MessageModel.fromJson(message.toJson());
    expect(restored.avatar, 'asset:starcore_explorer');
  });

  testWidgets('DefaultMessageWidget uses a non-null avatar override',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DefaultMessageWidget(
          key: GlobalKey(),
          message: message,
          avatarBuilder: (_, __, size) => SizedBox.square(
            key: const ValueKey('custom-message-avatar'),
            dimension: size,
          ),
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('custom-message-avatar')), findsOneWidget);
    expect(find.text('艾'), findsNothing);
  });

  testWidgets('null override preserves the existing emoji protocol',
      (tester) async {
    final emojiMessage = MessageModel(
      ownerType: OwnerType.receiver,
      ownerName: '艾琳',
      avatar: 'emoji:${Uri.encodeComponent('🎭')}',
      content: '你好',
      createdAt: 1001,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DefaultMessageWidget(
          key: GlobalKey(),
          message: emojiMessage,
          avatarBuilder: (_, __, ___) => null,
        ),
      ),
    ));
    expect(find.text('🎭'), findsOneWidget);
  });

  testWidgets('ChatList forwards avatarBuilder', (tester) async {
    final controller = ChatController(
      initialMessageList: [message],
      itemScrollController: ItemScrollController(),
      itemPositionsListener: ItemPositionsListener.create(),
      timePellet: 60,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatList(
          chatController: controller,
          avatarBuilder: (_, __, size) => SizedBox.square(
            key: const ValueKey('forwarded-message-avatar'),
            dimension: size,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('forwarded-message-avatar')), findsOneWidget);
  });
}
