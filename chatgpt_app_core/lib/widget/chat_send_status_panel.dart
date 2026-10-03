import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:flutter/material.dart';

/// 输入框上方的发送状态。只展示快照，取消、预览与草稿操作由会话页处理。
class ChatSendStatusPanel extends StatelessWidget {
  final ChatSendProgress? progress;
  final bool busy;
  final String? draftNotice;
  final ChatContextPlan? contextPlan;
  final bool attachmentsPending;
  final VoidCallback? onCancel;
  final VoidCallback? onPreview;
  final VoidCallback? onDismissDraft;

  const ChatSendStatusPanel({
    super.key,
    this.progress,
    this.busy = false,
    this.draftNotice,
    this.contextPlan,
    this.attachmentsPending = false,
    this.onCancel,
    this.onPreview,
    this.onDismissDraft,
  });

  @override
  Widget build(BuildContext context) {
    final notice = draftNotice?.trim() ?? '';
    if (!busy && notice.isEmpty && contextPlan == null && onPreview == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final plan = contextPlan;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (notice.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(notice, style: theme.textTheme.bodySmall),
                  ),
                ),
                if (onDismissDraft != null)
                  IconButton(
                    key: const ValueKey('dismiss_chat_draft_notice'),
                    tooltip: '关闭草稿提示',
                    onPressed: onDismissDraft,
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          if (busy)
            Semantics(
              container: true,
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                decoration: BoxDecoration(
                  color: colors.primaryContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '${progress?.label ?? '准备发送'}'
                              '${progress != null && progress!.total > 1 ? '（${progress!.index}/${progress!.total}）' : ''}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ),
                        if (onCancel != null)
                          IconButton(
                            key: const ValueKey('cancel_chat_send'),
                            tooltip: '取消本次发送',
                            onPressed: onCancel,
                            icon: const Icon(Icons.close, size: 20),
                          ),
                      ],
                    ),
                    if (progress?.fileName?.isNotEmpty == true) ...[
                      Text(
                        progress!.fileName!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                    ],
                    LinearProgressIndicator(
                      key: const ValueKey('chat_send_progress'),
                      value: progress?.fraction,
                      semanticsLabel: progress?.label ?? '准备发送',
                    ),
                    if (progress?.fraction != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${_bytes(progress!.completedBytes!.clamp(0, progress!.totalBytes!))}'
                        ' / ${_bytes(progress!.totalBytes!)}'
                        ' · ${(progress!.fraction! * 100).round()}%',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (plan != null) ...[
            const SizedBox(height: 6),
            Text(
              '本轮输入约 ${plan.estimatedInputTokens} Token'
              ' / 应用预算 ${plan.inputBudgetTokens} Token',
              style: theme.textTheme.bodySmall?.copyWith(
                color: !plan.canSend
                    ? colors.error
                    : plan.usageRatio >= 0.8
                        ? colors.primary
                        : colors.onSurfaceVariant,
              ),
            ),
            if (attachmentsPending)
              Text('附件待处理，发送前会重新估算', style: theme.textTheme.bodySmall),
            if (plan.shortened)
              Text(
                '本轮省略 ${plan.omittedHistoryMessages} 条较早消息'
                '${plan.summary.isEmpty ? '' : '，附带原文摘录'}',
                style: theme.textTheme.bodySmall,
              ),
            if (!plan.canSend)
              Text(plan.error!,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: colors.error))
            else if (plan.usageRatio >= 0.8)
              Text('接近输入预算', style: theme.textTheme.bodySmall),
          ],
          if (plan != null || onPreview != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('chat_context_preview'),
                onPressed: onPreview,
                icon: const Icon(Icons.preview_outlined, size: 18),
                label: const Text('查看本轮上下文'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _bytes(int count) {
    if (count < 1024) return '$count B';
    if (count < 1024 * 1024) return '${(count / 1024).toStringAsFixed(1)} KiB';
    return '${(count / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}
