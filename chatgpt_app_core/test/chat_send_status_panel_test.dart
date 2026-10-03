import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/widget/chat_send_status_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatContextPlan plan(
          {int omitted = 0, String? error, int estimated = 3000}) =>
      ChatContextPlan(
        history: const [],
        turns: const [],
        estimatedInputTokens: estimated,
        inputBudgetTokens: 4096,
        contextWindowTokens: 8192,
        reservedOutputTokens: 3072,
        includedHistoryMessages: 2,
        omittedHistoryMessages: omitted,
        includedHistoryTurns: 1,
        omittedHistoryTurns: omitted ~/ 2,
        summary: omitted == 0 ? '' : '原文摘录',
        warnings: const [],
        error: error,
        usesFallbackBudget: true,
      );

  Future<void> pump(WidgetTester tester, ChatSendStatusPanel panel,
      {double scale = 1}) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: SingleChildScrollView(child: panel),
        ),
      ),
    ));
  }

  testWidgets('没有状态时隐藏，不占用输入区域', (tester) async {
    await pump(tester, const ChatSendStatusPanel());
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('查看本轮上下文'), findsNothing);
    expect(tester.getSize(find.byType(ChatSendStatusPanel)).height, 0);
  });

  testWidgets('旧对话刚打开没有上下文估算时也能进入预览', (tester) async {
    var previews = 0;
    await pump(tester, ChatSendStatusPanel(onPreview: () => previews++));
    expect(find.text('查看本轮上下文'), findsOneWidget);
    expect(find.textContaining('本轮输入约'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat_context_preview')));
    expect(previews, 1);
  });

  testWidgets('预估没有包含待处理附件时明确提示，处理完成后隐藏', (tester) async {
    await pump(
        tester,
        ChatSendStatusPanel(
          contextPlan: plan(),
          attachmentsPending: true,
          onPreview: () {},
        ));
    expect(find.text('附件待处理，发送前会重新估算'), findsOneWidget);
    await pump(
        tester, ChatSendStatusPanel(contextPlan: plan(), onPreview: () {}));
    expect(find.text('附件待处理，发送前会重新估算'), findsNothing);
  });

  testWidgets('上传显示真实客户端字节比例；等待回答改为不确定进度', (tester) async {
    await pump(
        tester,
        const ChatSendStatusPanel(
          busy: true,
          progress: ChatSendProgress('上传图片',
              fileName: '图片.png',
              index: 1,
              total: 2,
              completedBytes: 1024,
              totalBytes: 2048),
        ));
    expect(find.text('上传图片（1/2）'), findsOneWidget);
    expect(find.text('图片.png'), findsOneWidget);
    expect(find.text('1.0 KiB / 2.0 KiB · 50%'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.5);
    await pump(
        tester,
        const ChatSendStatusPanel(
          busy: true,
          progress: ChatSendProgress('等待回答'),
        ));
    expect(find.text('等待回答'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        isNull);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('取消、上下文预览和关闭提示触发各自操作', (tester) async {
    var cancelled = 0;
    var previewed = 0;
    var dismissed = 0;
    await pump(
        tester,
        ChatSendStatusPanel(
          busy: true,
          draftNotice: '已恢复未发送草稿',
          contextPlan: plan(),
          onCancel: () => cancelled++,
          onPreview: () => previewed++,
          onDismissDraft: () => dismissed++,
        ));
    await tester.tap(find.byKey(const ValueKey('cancel_chat_send')));
    await tester.tap(find.byKey(const ValueKey('chat_context_preview')));
    await tester.tap(find.byKey(const ValueKey('dismiss_chat_draft_notice')));
    expect([cancelled, previewed, dismissed], [1, 1, 1]);
    expect(find.byTooltip('取消本次发送'), findsOneWidget);
    expect(find.byTooltip('关闭草稿提示'), findsOneWidget);
  });

  testWidgets('上下文明确标注估算与应用预算，显示省略消息和预警', (tester) async {
    await pump(tester,
        ChatSendStatusPanel(contextPlan: plan(omitted: 6, estimated: 3800)));
    expect(find.text('本轮输入约 3800 Token / 应用预算 4096 Token'), findsOneWidget);
    expect(find.text('本轮省略 6 条较早消息，附带原文摘录'), findsOneWidget);
    expect(find.text('接近输入预算'), findsOneWidget);
    expect(find.textContaining('8192'), findsNothing);
    await pump(
        tester, ChatSendStatusPanel(contextPlan: plan(error: '本轮内容超过输入预算')));
    expect(find.text('本轮内容超过输入预算'), findsOneWidget);
  });

  testWidgets('320px 与两倍字号下所有状态和操作不溢出', (tester) async {
    await pump(
        tester,
        ChatSendStatusPanel(
          busy: true,
          progress: const ChatSendProgress('正在上传待发送图片，请稍候',
              fileName: '特别长的文件名特别长的文件名特别长的文件名.png',
              index: 4,
              total: 4,
              completedBytes: 64 * 1024,
              totalBytes: 128 * 1024),
          contextPlan: plan(omitted: 100, estimated: 3900),
          draftNotice: '已恢复文字草稿，其中一个附件已不可用，请重新选择附件后继续发送。',
          onCancel: () {},
          onPreview: () {},
          onDismissDraft: () {},
        ),
        scale: 2);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const ValueKey('cancel_chat_send'))).width,
        greaterThanOrEqualTo(48));
    expect(
        tester
            .getSize(find.byKey(const ValueKey('chat_context_preview')))
            .height,
        greaterThanOrEqualTo(48));
  });

  testWidgets('收到越界字节进度时展示范围限制，未知总量不显示百分比', (tester) async {
    await pump(
        tester,
        const ChatSendStatusPanel(
          busy: true,
          progress:
              ChatSendProgress('上传图片', completedBytes: 500, totalBytes: 100),
        ));
    expect(find.text('100 B / 100 B · 100%'), findsOneWidget);
    await pump(
        tester,
        const ChatSendStatusPanel(
          busy: true,
          progress: ChatSendProgress('上传图片', completedBytes: 500),
        ));
    expect(find.textContaining('%'), findsNothing);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        isNull);
  });
}
