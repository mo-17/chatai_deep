import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/pages/agent_task_output_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgentWorkspaceRevision _version(
        {int revision = 1, String content = '生成时的成果 v1'}) =>
    AgentWorkspaceRevision(
        fileId: 4,
        revision: revision,
        content: content,
        note: '',
        createdAt: 1000);

AgentTaskOutputPage _page(
        {required Future<AgentWorkspaceRevision> Function() load,
        String Function()? account,
        Listenable? changes}) =>
    AgentTaskOutputPage(
        cid: 8,
        fileId: 4,
        revision: 1,
        name: 'result.md',
        currentRevision: 2,
        expectedAccountHash: 'guest',
        accountHash: account ?? () => 'guest',
        accountChanges: changes,
        loadRevision: load);

void main() {
  testWidgets('只显示绑定v1并标注当前v2，不随最新内容替换', (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: _page(load: () async => _version())));
    await tester.pumpAndSettle();
    expect(find.text('生成时的成果 v1'), findsOneWidget);
    expect(find.textContaining('当前文件已更新到 v2'), findsOneWidget);
    expect(find.text('导入文件'), findsNothing);
    expect(find.text('编辑'), findsNothing);
  });

  testWidgets('错版本和缺失版本只显示安全不可用说明', (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: _page(load: () async => _version(revision: 2))));
    await tester.pumpAndSettle();
    expect(find.textContaining('这个成果版本暂时不可用'), findsOneWidget);
    expect(find.text('生成时的成果 v1'), findsNothing);
  });

  testWidgets('异步读取切换账号后不显示迟到正文', (tester) async {
    var account = 'guest';
    final changes = ValueNotifier(0);
    final pending = Completer<AgentWorkspaceRevision>();
    await tester.pumpWidget(MaterialApp(
        home: _page(
            load: () => pending.future,
            account: () => account,
            changes: changes)));
    await tester.pump();
    account = 'other';
    changes.value++;
    pending.complete(_version(content: '旧账号正文'));
    await tester.pumpAndSettle();
    expect(find.text('账号已切换，请返回当前账号的任务'), findsOneWidget);
    expect(find.text('旧账号正文'), findsNothing);
    expect(find.text('result.md'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    changes.dispose();
  });

  testWidgets('已显示成果切账号及时隐藏且正文分段不切代理对', (tester) async {
    var account = 'guest';
    final changes = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
        home: _page(
            load: () async => _version(content: '${'a' * 11999}😀${'b' * 20}'),
            account: () => account,
            changes: changes)));
    await tester.pumpAndSettle();
    final text = tester.widget<SelectableText>(
        find.byKey(const ValueKey('task_output_content')));
    expect(text.data, endsWith('😀'));
    account = 'other';
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    await tester.pumpWidget(const SizedBox());
    changes.dispose();
  });
}
