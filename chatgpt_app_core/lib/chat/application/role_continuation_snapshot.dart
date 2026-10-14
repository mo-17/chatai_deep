import 'package:flutter/widgets.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';

/// 同一份值快照用于持久化和跨轮历史，不依赖页面或重新解析模型请求。
List<MessageBlock> withRoleContinuationSnapshot(List<MessageBlock> blocks,
    {required bool assistantBound,
    required int receiverCreatedAt,
    required String messageKey,
    required String modelId,
    required String mainText,
    required bool hasError}) {
  if (!assistantBound ||
      mainText.trim().isNotEmpty ||
      blocks.any((b) => b is RoleContinuationBlock)) {
    return blocks;
  }
  final thinking = blocks
      .whereType<ThinkingBlock>()
      .map((b) => b.content.trim())
      .where((s) => s.isNotEmpty)
      .join('\n');
  final compact = thinking
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('<<<', '')
      .replaceAll('>>>', '')
      .trim();
  if (compact.isEmpty) return blocks;
  final summary = compact.characters.length <= 240
      ? compact
      : '${compact.characters.take(240).toString()}...';
  final prefix = hasError ? '上一轮回复中断，' : '上一轮尚未正式开口，';
  return [
    ...blocks,
    RoleContinuationBlock(
        id: 'blk_${messageKey}_role_continuation',
        messageId: messageKey,
        createdAt: receiverCreatedAt,
        status: MessageBlockStatus.success,
        modelId: modelId,
        content: '$prefix角色已形成的心理/动作状态：$summary')
  ];
}
