/// 会话列表「边缘状态」纯计算（与 Widget 解耦，便于单测）。
///
/// 列表是 `ScrollablePositionedList.builder(reverse: true)`：index 0 是最新消息、
/// 渲染在**最底部**；index 越大越旧、越靠**顶端**。可见项的 index 集合由
/// `ItemPositionsListener` 给出。基于「当前可见的最小/最大 index」与「总条数」
/// 推断是否到顶/到底，用于：
/// - 分页：到达最旧的已加载项（atTop）→ 加载更早一页；
/// - 「回到顶部 / 回到底部」按钮可见性：未到顶才显示回顶、未到底才显示回底。
class ChatListEdges {
  /// 最旧的已加载项（index == itemCount-1）已可见。
  final bool atTop;

  /// 最新消息（index 0）已可见。
  final bool atBottom;

  const ChatListEdges({required this.atTop, required this.atBottom});

  @override
  bool operator ==(Object other) =>
      other is ChatListEdges && other.atTop == atTop && other.atBottom == atBottom;

  @override
  int get hashCode => Object.hash(atTop, atBottom);

  @override
  String toString() => 'ChatListEdges(atTop: $atTop, atBottom: $atBottom)';
}

ChatListEdges computeChatListEdges({
  required Iterable<int> visibleIndices,
  required int itemCount,
}) {
  // 空列表或还没有任何可见项：视为既在顶也在底（两个按钮都不显示）。
  if (itemCount <= 0) return const ChatListEdges(atTop: true, atBottom: true);
  final it = visibleIndices.iterator;
  if (!it.moveNext()) return const ChatListEdges(atTop: true, atBottom: true);
  var minI = it.current;
  var maxI = it.current;
  while (it.moveNext()) {
    final i = it.current;
    if (i < minI) minI = i;
    if (i > maxI) maxI = i;
  }
  return ChatListEdges(atTop: maxI >= itemCount - 1, atBottom: minI <= 0);
}
