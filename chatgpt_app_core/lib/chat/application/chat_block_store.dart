import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:flutter/foundation.dart';

/// 一条消息在 [ChatBlockStore] 与持久化里的稳定 key。
///
/// 复用 [MessageModel.createdAt]（同一会话内唯一，且 ChatController 也用它
/// 作为消息身份）作为 key，避免给 MessageModel 再加一个 id 字段。
String chatMessageKey(int createdAt) => 'msg_$createdAt';

/// 规范化的「块仓库」。对应源项目 Redux 的
/// `messageBlocks slice` + `BlockManager` 的状态部分。
///
/// 用 `provider` 体系的 [ChangeNotifier] 实现（本仓库约定只用 provider，
/// 不引入 Riverpod —— 见 CLAUDE.md）。块按 id 规范化存储，
/// 消息只持有 blockId 的有序列表。
///
/// 高频更新只替换「当前块」这一个引用，UI 侧用 `Selector` 精确订阅
/// 单个块 / 单条消息的 blockIds，因此一个 token 到达时只有正在更新的
/// 那个块会重渲染，其它块不动（满足阶段一验收：流式中只有当前块在增量更新）。
class ChatBlockStore extends ChangeNotifier {
  /// blockId -> 块对象
  final Map<String, MessageBlock> _blocks = {};

  /// messageKey -> 该消息的有序 blockId 列表
  final Map<String, List<String>> _messageBlockIds = {};

  MessageBlock? block(String id) => _blocks[id];

  /// 返回某条消息的 blockId 有序列表。
  ///
  /// 未变更时返回同一 List 引用，以便 [Selector] 用 `==` 跳过无谓重建。
  List<String> blockIdsFor(String messageKey) =>
      _messageBlockIds[messageKey] ?? const [];

  bool hasBlocks(String messageKey) =>
      (_messageBlockIds[messageKey]?.isNotEmpty) ?? false;

  /// 某条消息当前的全部块（按顺序），用于落库。
  List<MessageBlock> blocksFor(String messageKey) {
    final ids = _messageBlockIds[messageKey];
    if (ids == null) return const [];
    return [
      for (final id in ids)
        if (_blocks[id] != null) _blocks[id]!,
    ];
  }

  /// 新增 / 更新一个块。流式中每个 chunk 都会调用。
  void upsertBlock(MessageBlock block) {
    _blocks[block.id] = block;
    notifyListeners();
  }

  /// 把块追加到某条消息的块列表（若尚未在列表中）。
  void attachBlockToMessage(String messageKey, String blockId) {
    final ids = _messageBlockIds[messageKey] ?? const [];
    if (ids.contains(blockId)) return;
    _messageBlockIds[messageKey] = [...ids, blockId];
    notifyListeners();
  }

  /// 从持久化数据恢复某条消息的全部块（历史会话 hydration）。
  /// 不触发逐条通知，调用方在批量 seed 完成后统一刷新。
  void seedMessage(String messageKey, List<MessageBlock> blocks) {
    if (blocks.isEmpty) return;
    for (final b in blocks) {
      _blocks[b.id] = b;
    }
    _messageBlockIds[messageKey] = blocks.map((b) => b.id).toList();
  }

  /// 批量 seed 完成后调用一次，刷新 UI。
  void commitSeed() => notifyListeners();

  /// 从某条消息移除单个块（如空流式遗留的占位块）。
  /// 列表清空后一并清掉该消息条目，使 hasBlocks 回到 false（回退平铺渲染）。
  void removeBlock(String messageKey, String blockId) {
    _blocks.remove(blockId);
    final ids = _messageBlockIds[messageKey];
    if (ids == null) return;
    final next = ids.where((id) => id != blockId).toList();
    if (next.isEmpty) {
      _messageBlockIds.remove(messageKey);
    } else {
      _messageBlockIds[messageKey] = next;
    }
    notifyListeners();
  }

  /// 删除某条消息及其全部块（删除消息时调用）。
  void removeMessage(String messageKey) {
    final ids = _messageBlockIds.remove(messageKey);
    if (ids != null) {
      for (final id in ids) {
        _blocks.remove(id);
      }
      notifyListeners();
    }
  }
}
