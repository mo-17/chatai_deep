import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:flutter/material.dart';

String? chatFailureActionLabel(ChatFailureAction action) => switch (action) {
      ChatFailureAction.retry => '继续任务',
      ChatFailureAction.configureProvider => '检查 AI 服务',
      ChatFailureAction.checkBalance => '查看服务商余额',
      ChatFailureAction.chooseModel => '选择模型',
      ChatFailureAction.checkInput => '检查输入设置',
      ChatFailureAction.none => null,
    };

/// 只导航或执行用户明确点击的操作；显示诊断本身不会重发请求。
class ChatFailureActionButton extends StatelessWidget {
  final ChatFailureDiagnosis diagnosis;
  final VoidCallback? onPressed;
  const ChatFailureActionButton(
      {super.key, required this.diagnosis, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final label = chatFailureActionLabel(diagnosis.action);
    if (label == null) return const SizedBox.shrink();
    return TextButton.icon(
      key: ValueKey('chat_failure_action_${diagnosis.action.name}'),
      onPressed: onPressed,
      icon: Icon(switch (diagnosis.action) {
        ChatFailureAction.retry => Icons.play_arrow,
        ChatFailureAction.checkBalance => Icons.account_balance_wallet_outlined,
        ChatFailureAction.chooseModel => Icons.swap_horiz,
        ChatFailureAction.checkInput => Icons.tune,
        _ => Icons.settings_outlined,
      }),
      label: Text(label),
    );
  }
}
