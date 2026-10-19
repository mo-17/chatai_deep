import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/voice/voice_conversation_controller.dart';
import 'package:chatgpt_app_core/voice/voice_conversation_panel.dart';
import 'support/fake_voice_input.dart';

void main() {
  testWidgets(
      'opening panel does not start mic; large text on narrow screen scrolls without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final speech = FakeVoiceInput();
    final controller = VoiceConversationController(
        speech: speech,
        voice: FakeVoiceOutput(),
        send: (_, __) async => '回答',
        cancelReply: () async {},
        isCurrent: () => true);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 480), textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
                body: Align(
                    alignment: Alignment.bottomCenter,
                    child: VoiceConversationPanel(
                        controller: controller, onClose: () {}))))));
    expect(speech.results, isEmpty);
    await tester.ensureVisible(find.text('开始语音对话'));
    await tester.tap(find.text('开始语音对话'));
    await tester.pump();
    expect(speech.results.length, 1);
    expect(find.text('暂停'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await controller.end();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
