import 'dart:ui' show PointerDeviceKind;

import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final owner in OwnerType.values) {
    testWidgets('${owner.name} 隐藏头像释放空间，小屏大字无溢出', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final message = MessageModel(
        ownerType: owner,
        content: 'Long message for checking bubble width. ' * 5,
        ownerName: 'A',
        createdAt: 1,
      );
      Future<void> pump(bool show) => tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DefaultMessageWidget(
                  key: message.key,
                  message: message,
                  showAvatars: show,
                ),
              ),
            ),
          ));
      await pump(true);
      final before = tester.getSize(find.text(message.content)).width;
      expect(find.byType(CircleAvatar), findsOneWidget);
      await pump(false);
      final after = tester.getSize(find.text(message.content)).width;
      expect(find.byType(CircleAvatar), findsNothing);
      expect(after - before, greaterThanOrEqualTo(48));
      expect(after, greaterThan(350));
      tester.view.physicalSize = const Size(320, 600);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(false);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('深色自定义气泡的操作菜单仍使用页面主题', (tester) async {
    Brightness? menuBrightness;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: DefaultMessageWidget(
          key: GlobalKey(),
          receiverBackgroundColor: const Color(0xFF1E1B4B),
          message: MessageModel(
            ownerType: OwnerType.receiver,
            content: 'Dark bubble',
            createdAt: 1,
          ),
          onBubbleLongPress: (_, ancestor) {
            menuBrightness = Theme.of(ancestor).brightness;
          },
        ),
      ),
    ));
    final textContext = tester.element(find.text('Dark bubble'));
    expect(Theme.of(textContext).brightness, Brightness.dark);
    await tester.tap(find.byTooltip('消息操作'));
    expect(menuBrightness, Brightness.light);
  });

  testWidgets('鼠标拖选只复制所选正文，消息操作入口仍可用', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    var actions = 0;
    const content = 'Choose only this part of the message';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DefaultMessageWidget(
          key: GlobalKey(),
          message: MessageModel(
            ownerType: OwnerType.receiver,
            content: content,
            createdAt: 1,
          ),
          showAvatars: false,
          onBubbleLongPress: (_, __) => actions++,
        ),
      ),
    ));
    final rect = tester.getRect(find.text(content));
    final gesture = await tester.startGesture(
      rect.topLeft + const Offset(2, 8),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(95, 0));
    await gesture.up();
    await tester.pump();
    final region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.contextMenuButtonItems
          .firstWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
    await tester.pump();
    expect(copied, isNotEmpty);
    expect(copied, isNot(content));
    expect(content, contains(copied!));
    expect(actions, 0);
    await tester.longPress(find.text(content));
    await tester.pump();
    expect(actions, 0, reason: '长按正文应选词，不抢占消息菜单');
    await tester.tap(find.byTooltip('消息操作'));
    expect(actions, 1);
    expect(tester.takeException(), isNull);
  });
}
