import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/widget/chat_failure_action_button.dart';
import 'package:flutter/material.dart';

class AgentTaskPanel extends StatelessWidget {
  final AgentTaskSession session;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onResume;
  final String? verificationSummary;
  final String? backgroundNotice;
  final bool queued;
  final int queuePosition;
  final VoidCallback? onCancelQueued;
  final VoidCallback? onDetails;
  final VoidCallback? onResolveFailure;
  const AgentTaskPanel(
      {super.key,
      required this.session,
      required this.busy,
      required this.onOpen,
      required this.onResume,
      this.backgroundNotice,
      this.queued = false,
      this.queuePosition = 0,
      this.onCancelQueued,
      this.onDetails,
      this.onResolveFailure,
      this.verificationSummary});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: session,
        builder: (context, _) {
          if (!session.enabled) return const SizedBox.shrink();
          final completed =
              session.todos.where((t) => t.status == 'completed').length;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.checklist_rounded),
              title: Text(session.todos.isEmpty
                  ? '任务模式已开启'
                  : '任务进度 $completed/${session.todos.length}'),
              subtitle: Text(queued
                  ? '等待执行（队列第 $queuePosition 位），可取消排队'
                  : busy
                      ? backgroundNotice ?? '正在执行，可点击停止后稍后继续'
                      : (session.canResume ? session.pauseReason : null) ??
                          verificationSummary ??
                          (session.canResume
                              ? session.needsContinuation
                                  ? '计划仍有未完成项，可继续执行'
                                  : '任务已中断，可从保存的进度继续'
                              : '文件按需阅读，成果可预览、导出与验收')),
              onTap: onOpen,
              trailing: queued
                  ? TextButton(
                      onPressed: onCancelQueued, child: const Text('取消排队'))
                  : !busy && session.canResume
                      ? TextButton(
                          onPressed: onResume, child: const Text('继续任务'))
                      : null,
            ),
            if ((session.userCreatedAt != null && onDetails != null) ||
                (!busy &&
                    session.failureDiagnosis != null &&
                    session.failureDiagnosis!.action !=
                        ChatFailureAction.retry &&
                    session.failureDiagnosis!.action != ChatFailureAction.none))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (session.userCreatedAt != null && onDetails != null)
                          TextButton.icon(
                            onPressed: onDetails,
                            icon: const Icon(Icons.article_outlined),
                            label: const Text('任务详情'),
                          ),
                        if (!busy &&
                            session.failureDiagnosis != null &&
                            session.failureDiagnosis!.action !=
                                ChatFailureAction.retry &&
                            session.failureDiagnosis!.action !=
                                ChatFailureAction.none)
                          ChatFailureActionButton(
                            diagnosis: session.failureDiagnosis!,
                            onPressed: onResolveFailure,
                          ),
                      ],
                    )),
              ),
          ]);
        },
      );
}
