import 'package:chatgpt_app_core/util/scroll_jump.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验收：会话列表边缘判定（驱动分页 + 置顶/置底按钮可见性）。
/// 列表 reverse:true → index 0 在最底(最新)，index 越大越靠顶(越旧)。
void main() {
  group('computeChatListEdges', () {
    test('空列表 -> 既在顶也在底（按钮都不显示）', () {
      final e = computeChatListEdges(visibleIndices: const [], itemCount: 0);
      expect(e.atTop, isTrue);
      expect(e.atBottom, isTrue);
    });

    test('全部项都可见（内容不足以滚动）-> 既在顶也在底', () {
      final e = computeChatListEdges(visibleIndices: [0, 1, 2], itemCount: 3);
      expect(e.atTop, isTrue);
      expect(e.atBottom, isTrue);
    });

    test('停在最底部(最新)：可见 0..3，共 20 条 -> 在底不在顶', () {
      final e =
          computeChatListEdges(visibleIndices: [0, 1, 2, 3], itemCount: 20);
      expect(e.atBottom, isTrue);
      expect(e.atTop, isFalse);
    });

    test('停在最顶端(最旧)：可见 17..19，共 20 条 -> 在顶不在底', () {
      final e =
          computeChatListEdges(visibleIndices: [17, 18, 19], itemCount: 20);
      expect(e.atTop, isTrue);
      expect(e.atBottom, isFalse);
    });

    test('停在中间：可见 8..11，共 20 条 -> 既不在顶也不在底', () {
      final e =
          computeChatListEdges(visibleIndices: [8, 9, 10, 11], itemCount: 20);
      expect(e.atTop, isFalse);
      expect(e.atBottom, isFalse);
    });

    test('可见 index 乱序也能算出最小/最大', () {
      final e =
          computeChatListEdges(visibleIndices: [10, 0, 5, 19], itemCount: 20);
      expect(e.atBottom, isTrue); // 含 0
      expect(e.atTop, isTrue); // 含 19 == itemCount-1
    });
  });
}
