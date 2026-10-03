import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:flutter/material.dart';

/// 对话级思考强度入口。默认值留空，沿用服务端策略。
class DeepSeekReasoningSelector extends StatelessWidget {
  final DeepSeekReasoningEffort? effort;
  final VoidCallback? onTap;

  const DeepSeekReasoningSelector({super.key, this.effort, this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: ActionChip(
          key: const ValueKey('conversation_reasoning_effort'),
          avatar: const Icon(Icons.psychology_outlined, size: 18),
          label: Text('思考：${effort?.label ?? '默认'}'),
          onPressed: onTap,
        ),
      );
}

/// 用对象区分“选择默认（null）”与“取消弹层（null 返回值）”。
class DeepSeekReasoningSelection {
  final DeepSeekReasoningEffort? effort;
  const DeepSeekReasoningSelection(this.effort);
}

class DeepSeekReasoningDialog extends StatelessWidget {
  final DeepSeekReasoningEffort? selected;
  const DeepSeekReasoningDialog({super.key, this.selected});

  static const _descriptions = {
    DeepSeekReasoningEffort.off: '直接回答，关闭深度思考',
    DeepSeekReasoningEffort.low: '较低推理强度，适合日常任务',
    DeepSeekReasoningEffort.high: '默认强度，适合一般分析',
    DeepSeekReasoningEffort.max: '最高推理强度，适合复杂问题',
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('思考强度'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('只影响当前会话，从下一次请求开始生效。'),
                const SizedBox(height: 8),
                _option(context, null, '跟随默认', '使用服务端默认强度（当前为 high）'),
                for (final effort in DeepSeekReasoningEffort.values)
                  _option(
                      context,
                      effort,
                      '${effort.label}（${effort.wireValue}）',
                      _descriptions[effort]!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      );

  Widget _option(BuildContext context, DeepSeekReasoningEffort? effort,
          String title, String description) =>
      ListTile(
        key: ValueKey('reasoning_effort_${effort?.wireValue ?? 'default'}'),
        title: Text(title),
        subtitle: Text(description),
        selected: selected == effort,
        trailing: selected == effort ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(context, DeepSeekReasoningSelection(effort)),
      );
}
