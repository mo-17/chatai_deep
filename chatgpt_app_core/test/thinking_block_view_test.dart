import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/thinking_block_view.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('anime 思考块在窄屏大字体下标题触控至少 44dp', (tester) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 400),
            textScaler: TextScaler.linear(1.8),
          ),
          child: Scaffold(
            body: ThinkingBlockView(
              ThinkingBlock(
                id: 'thinking-1',
                messageId: 'message-1',
                createdAt: 1,
                status: MessageBlockStatus.success,
                content: '先分析约束，再给出答案。',
                thinkingMillsec: 1200,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final header = find.byType(InkWell);
    expect(tester.getSize(header).height, greaterThanOrEqualTo(44));
    await tester.tap(find.textContaining('已深度思考'));
    await tester.pump();
    expect(find.text('先分析约束，再给出答案。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
