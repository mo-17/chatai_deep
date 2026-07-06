import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 阶段一 / 阶段二 验收的可执行版本。覆盖块化消息系统的核心不变量：
/// 多块并存与顺序、思考与正文分离、块类型切换收尾、错误块、持久化往返、占位块变身。
void main() {
  const key = 'msg_1000';

  group('StreamDispatcher 块化分发', () {
    test('先思考再正文 -> 两个独立块，按到达顺序排列', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onThinkingChunk('让我想想');
      d.onThinkingChunk('……好的');
      d.onTextChunk('答案是');
      d.onTextChunk(' 42');
      d.finish();

      final blocks = store.blocksFor(key);
      expect(blocks.length, 2, reason: '思考 + 正文 = 两个块');
      expect(blocks[0], isA<ThinkingBlock>());
      expect(blocks[1], isA<MainTextBlock>());
      expect((blocks[0] as ThinkingBlock).content, '让我想想……好的');
      // 关键：正文块只含正文，思考内容没有混进去（不会被当历史重发）。
      expect((blocks[1] as MainTextBlock).content, '答案是 42');
    });

    test('正文开始时上一个思考块被标记完成（块类型切换收尾）', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onThinkingChunk('思考中');
      d.onTextChunk('开始回答');
      // 此刻思考块应已 success，正文块在 streaming。
      final blocks = store.blocksFor(key);
      expect(blocks[0].status, MessageBlockStatus.success);
      expect(blocks[1].status, MessageBlockStatus.streaming);
      d.finish();
      expect(store.blocksFor(key)[1].status, MessageBlockStatus.success);
    });

    test('占位块在收到首个事件后「变身」，不会残留额外块', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      expect(store.blocksFor(key).length, 1);
      expect(store.blocksFor(key).first, isA<PlaceholderBlock>());
      d.onTextChunk('hi');
      // 占位块变身为正文块，数量仍为 1。
      expect(store.blocksFor(key).length, 1);
      expect(store.blocksFor(key).first, isA<MainTextBlock>());
    });

    test('交错流 think→text→think→text 按到达顺序成 4 个块（对称收尾）', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onThinkingChunk('想 A');
      d.onTextChunk('答 A');
      d.onThinkingChunk('想 B');
      d.onTextChunk('答 B');
      d.finish();

      final blocks = store.blocksFor(key);
      expect(blocks.map((b) => b.type).toList(), [
        MessageBlockType.thinking,
        MessageBlockType.mainText,
        MessageBlockType.thinking,
        MessageBlockType.mainText,
      ]);
      expect((blocks[0] as ThinkingBlock).content, '想 A');
      expect((blocks[1] as MainTextBlock).content, '答 A');
      expect((blocks[2] as ThinkingBlock).content, '想 B');
      expect((blocks[3] as MainTextBlock).content, '答 B');
      // mainText 聚合所有正文块（不含思考），用于历史上下文。
      expect(d.mainText, '答 A答 B');
    });

    test('空流式：占位块被移除，无残留块，mainText 为空', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.finish(); // 没有任何 chunk
      expect(store.hasBlocks(key), isFalse);
      expect(store.blocksFor(key), isEmpty);
      expect(d.mainText, '');
      expect(d.hasError, isFalse);
    });

    test('思考计时：thinkingMillsec 单调不减，complete 落最终值', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onThinkingChunk('a');
      final t1 = (store.blocksFor(key).first as ThinkingBlock).thinkingMillsec;
      d.onThinkingChunk('b');
      final t2 = (store.blocksFor(key).first as ThinkingBlock).thinkingMillsec;
      expect(t2, greaterThanOrEqualTo(t1));
      d.finish();
      final tf = (store.blocksFor(key).first as ThinkingBlock).thinkingMillsec;
      expect(tf, greaterThanOrEqualTo(t2));
    });

    test('出错插入 error 块，标记 hasError', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onTextChunk('部分内容');
      d.onError('网络异常');
      expect(d.hasError, isTrue);
      final blocks = store.blocksFor(key);
      expect(blocks.whereType<ErrorBlock>().length, 1);
      expect(blocks.whereType<ErrorBlock>().first.message, '网络异常');
      // 已收到的正文保留。
      expect(d.mainText, '部分内容');
    });

    test('一个字都没收到就报错：占位块直接变 error 块', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onError('连接失败');
      final blocks = store.blocksFor(key);
      expect(blocks.length, 1);
      expect(blocks.first, isA<ErrorBlock>());
    });

    test('用户停止：当前块标记 paused', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onTextChunk('写到一半');
      d.onStopped();
      expect(store.blocksFor(key).first.status, MessageBlockStatus.paused);
    });
  });

  group('持久化往返', () {
    test('encodeList -> decodeList 完整恢复思考块与正文块', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onThinkingChunk('深度推理过程');
      d.onTextChunk('最终答案');
      d.finish();

      final json = MessageBlock.encodeList(store.blocksFor(key));
      final restored = MessageBlock.decodeList(json);

      expect(restored.length, 2);
      expect(restored[0], isA<ThinkingBlock>());
      expect((restored[0] as ThinkingBlock).content, '深度推理过程');
      expect(restored[1], isA<MainTextBlock>());
      expect((restored[1] as MainTextBlock).content, '最终答案');
      // 恢复后状态也保留。
      expect(restored[0].status, MessageBlockStatus.success);
    });

    test('decodeList 容错：坏数据返回空列表而非抛异常', () {
      expect(MessageBlock.decodeList('不是 json'), isEmpty);
      expect(MessageBlock.decodeList(null), isEmpty);
      expect(MessageBlock.decodeList(''), isEmpty);
    });

    test('恢复的占位块/未知类型一律视为 success，不会渲染成永久加载圈', () {
      // 模拟历史里存了一个 streaming 状态的占位块（或更新版本的未知类型）。
      const json =
          '[{"type":"unknown","id":"b1","messageId":"m","createdAt":1,"status":"streaming"}]';
      final restored = MessageBlock.decodeList(json);
      expect(restored.single, isA<PlaceholderBlock>());
      expect(restored.single.status, MessageBlockStatus.success);
    });

    test('角色上下文快照块可持久化往返', () {
      const blocks = [
        RoleContextBlock(
          id: 'b_role_context',
          messageId: key,
          createdAt: 1000,
          status: MessageBlockStatus.success,
          content: '[当前命中的角色记忆]\n- 钟声代表潮汐',
          memoryBudget: AssistantMemoryContextBudget(
            context: '[当前命中的角色记忆]\n- 钟声代表潮汐',
            matchedCount: 3,
            includedCount: 1,
            skippedCount: 2,
            truncated: true,
            maxContextChars: 80,
            usedChars: 60,
          ),
          memoryHits: [
            AssistantMemoryEntryPreview(
              keywords: ['钟声'],
              content: '钟声代表潮汐',
              alwaysOn: false,
              priority: 5,
            ),
          ],
        ),
      ];

      final json = MessageBlock.encodeList(blocks);
      final restored = MessageBlock.decodeList(json);

      expect(restored.single, isA<RoleContextBlock>());
      final roleBlock = restored.single as RoleContextBlock;
      expect(roleBlock.content, contains('钟声代表潮汐'));
      expect(roleBlock.memoryBudget?.matchedCount, 3);
      expect(roleBlock.memoryBudget?.includedCount, 1);
      expect(roleBlock.memoryBudget?.skippedCount, 2);
      expect(roleBlock.memoryBudget?.truncated, isTrue);
      expect(roleBlock.memoryHits, hasLength(1));
      expect(roleBlock.memoryHits.single.label, '钟声 · p=5');
      expect(roleBlock.memoryHits.single.content, '钟声代表潮汐');
      expect(restored.single.type, MessageBlockType.roleContext);
    });

    test('未完成回复角色状态承接块可持久化往返', () {
      const blocks = [
        RoleContinuationBlock(
          id: 'b_role_continuation',
          messageId: key,
          createdAt: 1001,
          status: MessageBlockStatus.success,
          content: '上一轮尚未正式开口，角色紧张地攥住笔记本。',
        ),
      ];

      final json = MessageBlock.encodeList(blocks);
      final restored = MessageBlock.decodeList(json);

      expect(restored.single, isA<RoleContinuationBlock>());
      final block = restored.single as RoleContinuationBlock;
      expect(block.content, contains('尚未正式开口'));
      expect(block.type, MessageBlockType.roleContinuation);
    });
  });

  group('ChatBlockStore', () {
    test('blockIdsFor 未变更时返回同一引用（供 Selector 跳过重建）', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onTextChunk('x');
      final ids1 = store.blockIdsFor(key);
      d.onTextChunk('y'); // 同一个块更新内容，不新增块
      final ids2 = store.blockIdsFor(key);
      expect(identical(ids1, ids2), isTrue, reason: '块列表未变 -> 同一 List 引用');
    });

    test('removeMessage 清掉该消息的全部块', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, key)..start();
      d.onTextChunk('x');
      expect(store.hasBlocks(key), isTrue);
      store.removeMessage(key);
      expect(store.hasBlocks(key), isFalse);
      expect(store.blocksFor(key), isEmpty);
    });
  });
}
