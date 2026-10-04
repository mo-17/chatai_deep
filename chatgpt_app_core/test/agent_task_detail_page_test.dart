import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_task_detail_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_task_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTaskDetail _detail(
        {bool resumable = true,
        List<AgentTaskOutputReference> outputs = const [],
        ChatFailureDiagnosis? diagnosis,
        String prompt = '请整理本轮资料'}) =>
    AgentTaskDetail(
        cid: 8,
        userCreatedAt: 1008,
        generation: 3,
        title: '资料整理任务',
        prompt: prompt,
        enabled: true,
        hasConversation: true,
        canResume: resumable,
        nextRound: 2,
        todos: const [
          AgentTodo('已经整理的内容', 'completed'),
          AgentTodo('尚未完成的长清单条目保持完整显示', 'pending')
        ],
        pauseReason: '已保存断点，等待继续',
        pairedToolResultCount: 1,
        pairedTools: const [
          AgentTaskToolReference(toolId: 'read-1', name: 'read_file')
        ],
        uncertainTools: const [
          AgentTaskToolReference(toolId: 'write-2', name: 'write_file')
        ],
        outputs: outputs,
        failureDiagnosis: diagnosis,
        conversation: ConversationModel(cid: 8, icon: '🤖'),
        verificationReport: const AgentTaskVerificationReport(
            cid: 8,
            userCreatedAt: 1008,
            createdAt: 2008,
            checks: [
              AgentVerificationCheck(
                  label: '输出存在', passed: true, detail: '已保存版本'),
            ]),
        verificationIsCurrent: false);

Future<void> _show(WidgetTester tester, AgentTaskDetailPage page,
    {GlobalKey<NavigatorState>? navigatorKey}) async {
  await tester.pumpWidget(MaterialApp(navigatorKey: navigatorKey, home: page));
  await tester.pumpAndSettle();
}

Future<void> _scroll(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 350,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('完整清单工具元数据与旧报告提示可查看，浏览不会发送请求', (tester) async {
    var resumes = 0;
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async => _detail(),
            loadConversationForResume: (cid,
                {required userCreatedAt, required generation}) async {
              resumes++;
              return ConversationModel(cid: cid, icon: '🤖');
            }));
    expect(find.text('待继续 · 第 3 轮 · 任务版本 3'), findsOneWidget);
    expect(find.text('尚未完成的长清单条目保持完整显示'), findsOneWidget);
    await _scroll(tester, find.text('read_file · read-1'));
    expect(find.text('write_file · write-2'), findsOneWidget);
    await _scroll(tester, find.text('成果版本已变化或不可用，此报告不能代表当前文件'));
    expect(find.text('输出存在'), findsOneWidget);
    expect(resumes, 0);
  });

  testWidgets('恢复概览单次点击传固定轮次与generation，无二次审批', (tester) async {
    final validated = <(int, int, int)>[];
    final opened = <(int, bool, int?)>[];
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async => _detail(),
            loadConversationForResume: (cid,
                {required userCreatedAt, required generation}) async {
              validated.add((cid, userCreatedAt, generation));
              return ConversationModel(cid: cid, icon: '🤖');
            },
            openConversation: (conversation,
                {required resume, targetCreatedAt}) async {
              opened.add((conversation.cid, resume, targetCreatedAt));
            }));
    final button = find.byKey(const ValueKey('resume_task_from_detail'));
    await _scroll(tester, button);
    expect(find.text('继续会再次向 AI 服务发送请求，可能产生费用。'), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(validated, [(8, 1008, 3)]);
    expect(opened, [(8, true, 1008)]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('过期恢复身份不导航并刷新最新状态', (tester) async {
    var loads = 0;
    var opens = 0;
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async => _detail(resumable: ++loads == 1),
            loadConversationForResume: (cid,
                    {required userCreatedAt, required generation}) async =>
                null,
            openConversation: (conversation,
                    {required resume, targetCreatedAt}) async =>
                opens++));
    final button = find.byKey(const ValueKey('resume_task_from_detail'));
    await _scroll(tester, button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(find.text('任务已变化或无法恢复，请查看最新详情'), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('加载期间账号切换隐藏旧详情与迟到结果', (tester) async {
    var account = 'guest';
    final changes = ValueNotifier(0);
    final pending = Completer<AgentTaskDetail?>();
    await tester.pumpWidget(MaterialApp(
        home: AgentTaskDetailPage(
            cid: 8,
            accountHash: () => account,
            accountChanges: changes,
            loadDetail: (_) => pending.future)));
    await tester.pump();
    account = 'other';
    changes.value++;
    pending.complete(_detail());
    await tester.pumpAndSettle();
    expect(find.text('账号已切换，请返回当前账号的任务'), findsOneWidget);
    expect(find.text('资料整理任务'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    changes.dispose();
  });

  testWidgets('等待恢复时离开路由，迟到许可不触发导航', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final pending = Completer<ConversationModel?>();
    var opens = 0;
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async => _detail(),
            loadConversationForResume: (cid,
                    {required userCreatedAt, required generation}) =>
                pending.future,
            openConversation: (conversation,
                    {required resume, targetCreatedAt}) async =>
                opens++),
        navigatorKey: navigator);
    final button = find.byKey(const ValueKey('resume_task_from_detail'));
    await _scroll(tester, button);
    await tester.tap(button);
    await tester.pump();
    unawaited(navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一页')))));
    await tester.pumpAndSettle();
    pending.complete(ConversationModel(cid: 8, icon: '🤖'));
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(find.text('另一页'), findsOneWidget);
  });

  testWidgets('安全诊断显示HTTP和修复动作，返回不自动恢复', (tester) async {
    var fixes = 0;
    var resumes = 0;
    const diagnosis = ChatFailureDiagnosis(
        'model_not_found', '模型不存在', '请选择可用模型', ChatFailureAction.chooseModel,
        statusCode: 404);
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async => _detail(diagnosis: diagnosis),
            onResolveDiagnosis: (_) async => fixes++,
            loadConversationForResume: (cid,
                {required userCreatedAt, required generation}) async {
              resumes++;
              return null;
            }));
    final action =
        find.byKey(const ValueKey('chat_failure_action_chooseModel'));
    await _scroll(tester, action);
    expect(find.text('HTTP 404'), findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(fixes, 1);
    expect(resumes, 0);
  });

  testWidgets('成果打开前重新核对本轮绑定版本，失效不跳转', (tester) async {
    const output = AgentTaskOutputReference(
        fileId: 4,
        name: 'result.md',
        revision: 1,
        currentRevision: 2,
        available: true);
    var loads = 0;
    var opened = 0;
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async =>
                _detail(outputs: ++loads == 1 ? [output] : []),
            openOutput: (_, __) async => opened++));
    final card = find.byKey(const ValueKey('task_output_4_1'));
    await _scroll(tester, card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('任务或成果已变化，请刷新后查看'), findsOneWidget);
  });

  testWidgets('旧普通对话空详情与加载失败可重试，长输入有界展开', (tester) async {
    var loads = 0;
    await _show(
        tester,
        AgentTaskDetailPage(
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async {
              if (++loads == 1) throw StateError('私有响应不得展示');
              return null;
            }));
    expect(find.text('任务详情加载失败，请重试'), findsOneWidget);
    expect(find.textContaining('私有响应'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('这个对话没有可查看的任务记录'), findsOneWidget);
    await _show(
        tester,
        AgentTaskDetailPage(
            key: const ValueKey('long'),
            cid: 8,
            accountHash: () => 'guest',
            loadDetail: (_) async => _detail(prompt: '${'a' * 1999}😀尾部')));
    final input =
        tester.widget<SelectableText>(find.byType(SelectableText).first);
    expect(input.data!.endsWith('😀'), isTrue);
    expect(input.data!.contains('尾部'), isFalse);
    final expand = find.byKey(const ValueKey('expand_task_prompt'));
    await _scroll(tester, expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(
        tester.widget<SelectableText>(find.byType(SelectableText).first).data,
        endsWith('😀尾部'));
  });
}
