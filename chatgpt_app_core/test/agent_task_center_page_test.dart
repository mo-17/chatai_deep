import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_task_center_service.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_task_center_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTaskCenterEntry _task(int cid,
        {String status = 'paused',
        bool canResume = true,
        bool hasConversation = true}) =>
    AgentTaskCenterEntry(
        cid: cid,
        title: '任务 $cid',
        preview: '任务摘要 $cid',
        status: status,
        canResume: canResume,
        hasConversation: hasConversation,
        interrupted: status == 'paused',
        updatedAt: 1000 + cid,
        userCreatedAt: 2000 + cid,
        completedTodos: 1,
        totalTodos: 3,
        pauseReason: status == 'paused' ? '应用中断，已保存断点' : null);

Future<void> _show(WidgetTester tester, AgentTaskCenterPage page) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('详情入口独立于卡片查看与继续，固定账号传入路由', (tester) async {
    final opened = <(int, String)>[];
    var conversationLoads = 0;
    await _show(
        tester,
        AgentTaskCenterPage(
            accountHash: () => 'guest',
            loadTasks: ({required offset, required limit}) async =>
                AgentTaskCenterBatch(entries: [_task(7)]),
            loadConversation: (cid, {required requireResumable}) async {
              conversationLoads++;
              return ConversationModel(cid: cid, icon: '🤖');
            },
            openDetails: (cid, {required accountHash}) async =>
                opened.add((cid, accountHash))));
    await tester.tap(find.byKey(const ValueKey('detail_agent_task_7')));
    await tester.pumpAndSettle();
    expect(opened, [(7, 'guest')]);
    expect(conversationLoads, 0);
    expect(find.byKey(const ValueKey('resume_agent_task_7')), findsOneWidget);
  });

  testWidgets('筛选跨原始空页前进，明确继续与查看传递不同导航意图', (tester) async {
    final offsets = <int>[];
    final resolutions = <bool>[];
    final navigation = <({int cid, bool resume, int? target})>[];
    await _show(
        tester,
        AgentTaskCenterPage(
          accountHash: () => 'guest',
          loadTasks: ({required offset, required limit}) async {
            offsets.add(offset);
            return switch (offset) {
              0 => AgentTaskCenterBatch(
                  entries: [_task(1, status: 'complete', canResume: false)],
                  nextOffset: 30),
              30 => const AgentTaskCenterBatch(entries: [], nextOffset: 60),
              _ => AgentTaskCenterBatch(entries: [_task(2)]),
            };
          },
          loadConversation: (cid, {required requireResumable}) async {
            resolutions.add(requireResumable);
            return ConversationModel(cid: cid, icon: '🤖');
          },
          openConversation: (conversation,
              {required resume, targetCreatedAt}) async {
            navigation.add((
              cid: conversation.cid,
              resume: resume,
              target: targetCreatedAt
            ));
          },
        ));
    expect(offsets, [0]);
    expect(navigation, isEmpty);
    await tester.tap(find.widgetWithText(ChoiceChip, '可继续'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 30, 60]);
    expect(find.text('任务 1'), findsNothing);
    expect(find.text('任务 2'), findsOneWidget);
    expect(find.text('清单 1/3 已完成'), findsOneWidget);
    expect(find.text('应用中断，已保存断点'), findsOneWidget);
    await tester.tap(find.text('任务 2'));
    await tester.pumpAndSettle();
    expect(resolutions.single, isFalse);
    expect(navigation.single, (cid: 2, resume: false, target: 2002));
    await tester.tap(find.byKey(const ValueKey('resume_agent_task_2')));
    await tester.pumpAndSettle();
    expect(resolutions.last, isTrue);
    expect(navigation.last, (cid: 2, resume: true, target: 2002));
    expect(tester.takeException(), isNull);
  });

  testWidgets('完成和孤立任务无继续入口，孤立任务不能打开', (tester) async {
    var opened = 0;
    await _show(
        tester,
        AgentTaskCenterPage(
          accountHash: () => 'guest',
          loadTasks: ({required offset, required limit}) async =>
              AgentTaskCenterBatch(entries: [
            _task(1, status: 'complete', canResume: false),
            _task(2, canResume: false, hasConversation: false),
          ]),
          loadConversation: (cid, {required requireResumable}) async {
            opened++;
            return ConversationModel(cid: cid, icon: '🤖');
          },
        ));
    expect(find.text('继续任务'), findsNothing);
    expect(find.text('原对话已不存在，无法打开或继续'), findsOneWidget);
    await tester.tap(find.text('任务 2'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    await tester.tap(find.widgetWithText(ChoiceChip, '已完成'));
    await tester.pumpAndSettle();
    expect(find.text('任务 1'), findsOneWidget);
    expect(find.text('任务 2'), findsNothing);
  });

  testWidgets('加载失败可以重试，正常空态不创建会话', (tester) async {
    var attempts = 0;
    await _show(
        tester,
        AgentTaskCenterPage(
          accountHash: () => 'guest',
          loadTasks: ({required offset, required limit}) async {
            if (++attempts == 1) throw StateError('test failure');
            return const AgentTaskCenterBatch(entries: []);
          },
        ));
    expect(find.text('任务加载失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining('暂无任务。'), findsOneWidget);
    expect(find.text('继续任务'), findsNothing);
  });

  testWidgets('打开查询期间切换账号，不导航且清除旧账号任务', (tester) async {
    var account = 'guest';
    var opened = 0;
    final resolved = Completer<ConversationModel?>();
    await _show(
        tester,
        AgentTaskCenterPage(
          accountHash: () => account,
          loadTasks: ({required offset, required limit}) async =>
              AgentTaskCenterBatch(entries: [_task(1)]),
          loadConversation: (cid, {required requireResumable}) =>
              resolved.future,
          openConversation: (conversation,
                  {required resume, targetCreatedAt}) async =>
              opened++,
        ));
    await tester.tap(find.byKey(const ValueKey('resume_agent_task_1')));
    await tester.pump();
    account = 'another-account';
    resolved.complete(ConversationModel(cid: 1, icon: '🤖'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('账号已切换，请返回后重新打开任务中心'), findsOneWidget);
    expect(find.text('任务 1'), findsNothing);
    expect(find.text('继续任务'), findsNothing);
  });

  testWidgets('加载期间账号切换，迟到数据不显示', (tester) async {
    var account = 'guest';
    final loaded = Completer<AgentTaskCenterBatch>();
    await tester.pumpWidget(MaterialApp(
        home: AgentTaskCenterPage(
      accountHash: () => account,
      loadTasks: ({required offset, required limit}) => loaded.future,
    )));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    account = 'another-account';
    loaded.complete(AgentTaskCenterBatch(entries: [_task(1)]));
    await tester.pumpAndSettle();
    expect(find.text('任务 1'), findsNothing);
    expect(find.text('账号已切换，请返回后重新打开任务中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('继续前发现任务已变化时仅刷新，不打开模型请求', (tester) async {
    var loads = 0;
    var opened = 0;
    await _show(
        tester,
        AgentTaskCenterPage(
          accountHash: () => 'guest',
          loadTasks: ({required offset, required limit}) async =>
              AgentTaskCenterBatch(entries: [
            if (++loads == 1)
              _task(1)
            else
              _task(1, status: 'complete', canResume: false),
          ]),
          loadConversation: (cid, {required requireResumable}) async => null,
          openConversation: (conversation,
                  {required resume, targetCreatedAt}) async =>
              opened++,
        ));
    await tester.tap(find.byKey(const ValueKey('resume_agent_task_1')));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(loads, 2);
    expect(find.text('任务已变化或无法恢复，请刷新后查看'), findsOneWidget);
    expect(find.text('继续任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
