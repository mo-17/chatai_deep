import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:flutter/material.dart';

class AgentTaskPanel extends StatelessWidget {
  final AgentTaskSession session;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onResume;
  const AgentTaskPanel(
      {super.key,
      required this.session,
      required this.busy,
      required this.onOpen,
      required this.onResume});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: session,
        builder: (context, _) {
          if (!session.enabled) return const SizedBox.shrink();
          final completed =
              session.todos.where((t) => t.status == 'completed').length;
          return ListTile(
            dense: true,
            leading: const Icon(Icons.checklist_rounded),
            title: Text(session.todos.isEmpty
                ? '任务模式已开启'
                : '任务进度 $completed/${session.todos.length}'),
            subtitle: Text(busy
                ? '正在执行，可点击停止后稍后继续'
                : session.canResume
                    ? session.needsContinuation
                        ? '计划仍有未完成项，可继续执行'
                        : '任务已中断，可从保存的进度继续'
                    : '计划、技能和历史摘要按需使用'),
            onTap: onOpen,
            trailing: !busy && session.canResume
                ? TextButton(onPressed: onResume, child: const Text('继续任务'))
                : null,
          );
        },
      );
}
