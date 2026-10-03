import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/widget/agent_task_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('旧会话隐藏面板；停止后显示进度和继续入口，执行中隐藏继续', (tester) async {
    final task = AgentTaskSession(cid: 1, store: _Store());
    addTearDown(task.dispose);
    var resumed = 0;
    Widget app(bool busy) => MaterialApp(
          home: Scaffold(
            body: AgentTaskPanel(
              session: task,
              busy: busy,
              onOpen: () {},
              onResume: () => resumed++,
            ),
          ),
        );
    await tester.pumpWidget(app(false));
    expect(find.byType(ListTile), findsNothing);
    await task.setEnabled(true);
    await task.begin(userAt: 10, input: '比较资料');
    await task.todoTool.execute({
      'todos': [
        {'content': '读取资料', 'status': 'completed'},
        {'content': '比较差异', 'status': 'in_progress'},
      ],
    });
    await task.finish(complete: false);
    await tester.pump();
    expect(find.text('任务进度 1/2'), findsOneWidget);
    expect(find.text('任务已中断，可从保存的进度继续'), findsOneWidget);
    await tester.tap(find.text('继续任务'));
    expect(resumed, 1);
    await tester.pumpWidget(app(true));
    expect(find.text('继续任务'), findsNothing);
    expect(find.text('正在执行，可点击停止后稍后继续'), findsOneWidget);
  });

  testWidgets('未完成计划保留继续入口，全部完成后收起继续按钮', (tester) async {
    final task = AgentTaskSession(cid: 2, store: _Store());
    addTearDown(task.dispose);
    await task.setEnabled(true);
    await task.begin(userAt: 10, input: '完成任务');
    await task.todoTool.execute({
      'todos': [
        {'content': '核对结果', 'status': 'pending'},
      ],
    });
    await task.finish(complete: true);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AgentTaskPanel(
          session: task,
          busy: false,
          onOpen: () {},
          onResume: () {},
        ),
      ),
    ));
    expect(find.text('计划仍有未完成项，可继续执行'), findsOneWidget);
    expect(find.text('继续任务'), findsOneWidget);
    await task.todoTool.execute({
      'todos': [
        {'content': '核对结果', 'status': 'completed'},
      ],
    });
    await task.finish(complete: true);
    await tester.pump();
    expect(find.text('任务进度 1/1'), findsOneWidget);
    expect(find.text('继续任务'), findsNothing);
  });
}

class _Store implements IAgentTaskStore {
  Map<String, dynamic>? data;
  @override
  Future<Map<String, dynamic>?> read(int cid) async => data;
  @override
  Future<void> write(int cid, Map<String, dynamic> value) async => data = value;
}
