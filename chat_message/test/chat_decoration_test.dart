import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_tail_shape.dart';
import 'package:chat_message/widget/chat_bubble_surface.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('两种尾角在长短气泡下边界稳定，双侧镜像且可关闭', () {
    for (final pointed in [true, false]) {
      for (final size in [
        const Size(1, 1),
        const Size(52, 36),
        const Size(210, 500)
      ]) {
        final rect = const Offset(11, 17) & size;
        final right =
            ChatTailShape(isUser: true, pointed: pointed).getOuterPath(rect);
        final left =
            ChatTailShape(isUser: false, pointed: pointed).getOuterPath(rect);
        for (final path in [right, left]) {
          final bounds = path.getBounds();
          expect(bounds.left, greaterThanOrEqualTo(rect.left - .001));
          expect(bounds.right, lessThanOrEqualTo(rect.right + .001));
          expect(bounds.top, greaterThanOrEqualTo(rect.top - .001));
          expect(bounds.bottom, lessThanOrEqualTo(rect.bottom + .001));
          expect(path.contains(rect.center), isTrue);
        }
        for (var x = .1; x < 1; x += .1) {
          for (var y = .1; y < 1; y += .1) {
            expect(
                right.contains(Offset(
                    rect.left + size.width * x, rect.top + size.height * y)),
                left.contains(Offset(
                    rect.right - size.width * x, rect.top + size.height * y)));
          }
        }
        final noTail =
            ChatTailShape(isUser: true, pointed: pointed, showTail: false)
                .getOuterPath(rect);
        expect(noTail.contains(rect.center), isTrue);
        expect(
            ChatTailShape(isUser: false, pointed: pointed, showTail: false)
                .getOuterPath(rect)
                .getBounds(),
            noTail.getBounds());
      }
    }
  });

  test('预设与任意自定义配色的所有渐层端点均保留正文对比度', () {
    for (final brightness in Brightness.values) {
      final theme = ThemeData(brightness: brightness);
      for (final style in ChatBubbleStyle.values) {
        for (final base in [
          style.defaultColor(theme, isUser: true),
          style.defaultColor(theme, isUser: false),
          Colors.black,
          Colors.white,
          const Color(0xFF757575),
          const Color(0xFF00A04C)
        ]) {
          final foreground =
              base.computeLuminance() > .179 ? Colors.black : Colors.white;
          for (final stop in style.backgroundColors(base)) {
            final light = stop.computeLuminance();
            final contrast = foreground == Colors.black
                ? (light + .05) / .05
                : 1.05 / (light + .05);
            expect(contrast, greaterThanOrEqualTo(4.5),
                reason: '${style.name} $brightness $base');
          }
        }
      }
    }
  });

  testWidgets('实际列表传递两侧装扮，保留块更新、选择、消息操作与头像回退', (tester) async {
    final streamed = ValueNotifier('流式正文');
    addTearDown(streamed.dispose);
    final sender = MessageModel(
        ownerType: OwnerType.sender,
        ownerName: '我',
        content: '提问',
        createdAt: 1);
    final receiver = MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: '',
        avatar: 'invalid-avatar',
        content: '',
        createdAt: 2);
    var actions = 0;
    final controller = ChatController(
      initialMessageList: [sender, receiver],
      timePellet: 60,
      itemScrollController: ItemScrollController(),
      itemPositionsListener: ItemPositionsListener.create(),
      messageContentBuilder: (_, message) =>
          message.ownerType == OwnerType.receiver
              ? ValueListenableBuilder<String>(
                  valueListenable: streamed,
                  builder: (_, value, __) => Text(value))
              : null,
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatList(
      chatController: controller,
      senderBubbleStyle: ChatBubbleStyle.messenger,
      receiverBubbleStyle: ChatBubbleStyle.telegram,
      senderAvatarFrame: ChatAvatarFrameStyle.halo,
      receiverAvatarFrame: ChatAvatarFrameStyle.dashed,
      onBubbleLongPress: (_, __) => actions++,
    ))));
    await tester.pumpAndSettle();
    expect(
        tester.widget<DefaultMessageWidget>(find.byKey(sender.key)).bubbleStyle,
        ChatBubbleStyle.messenger);
    expect(
        tester
            .widget<DefaultMessageWidget>(find.byKey(receiver.key))
            .avatarFrameStyle,
        ChatAvatarFrameStyle.dashed);
    expect(find.byType(ChatBubbleSurface), findsNWidgets(2));
    expect(find.byType(SelectionArea), findsNWidgets(2));
    expect(find.byType(ChatAvatarFrame), findsNWidgets(2));
    streamed.value = '新的流式正文';
    await tester.pump();
    expect(find.text('新的流式正文'), findsOneWidget);
    await tester.tap(find.byTooltip('消息操作').first);
    expect(actions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('所有款式在有无头像、明暗模式下可渲染长文本', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      final theme = ThemeData(brightness: brightness);
      for (final showAvatars in [true, false]) {
        for (var i = 0; i < ChatBubbleStyle.values.length; i++) {
          await tester.pumpWidget(MaterialApp(
              theme: theme,
              home: Scaffold(
                  body: SingleChildScrollView(
                      child: DefaultMessageWidget(
                key: GlobalKey(),
                message: MessageModel(
                    ownerType: OwnerType.sender,
                    ownerName: '我',
                    content: '用于验证多行文本的真实消息。' * 12,
                    createdAt: 0),
                showAvatars: showAvatars,
                bubbleStyle: ChatBubbleStyle.values[i],
                avatarFrameStyle: ChatAvatarFrameStyle
                    .values[i % ChatAvatarFrameStyle.values.length],
                senderBackgroundColor:
                    ChatBubbleStyle.values[i].defaultColor(theme, isUser: true),
              )))));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(ChatAvatarFrame),
              showAvatars ? findsOneWidget : findsNothing);
        }
      }
    }
  });
}
