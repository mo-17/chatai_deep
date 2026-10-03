import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归：会话页在「改 AI 设置 / 切换助手」后会用上一个 dao 的 `currentMessages`
/// （`List.unmodifiable`）重建 CompletionDao，之后发消息/重新生成会对内部
/// `_messageList` 做 add/removeLast。修复前这会抛
/// `Unsupported operation: Cannot add to an unmodifiable list`。
/// 修复点：构造函数把传入的 messages 防御性拷贝成 growable 列表。
void main() {
  MessageModel msg(OwnerType type, String content, int t) =>
      MessageModel(ownerType: type, content: content, createdAt: t);

  group('CompletionDao 消息列表可变性', () {
    test('重新生成保留图片与已解析文件文字，回退后可再次写入历史', () {
      final user = MessageModel(
        ownerType: OwnerType.sender,
        content: '分析附件',
        createdAt: 1,
        imageUrlsOrB64: const ['data:image/png;base64,cGljdHVyZQ=='],
      );
      final dao = CompletionDao(
        settings: AISettings.defaults(),
        messages: [user, msg(OwnerType.receiver, '第一次回答', 2)],
        fileHistory: const {1: '[附件「报告.txt」内容开始]\n营收增长\n内容结束'},
      );
      final attachments = dao.attachmentsForUserMessage(user);
      dao.dropLastTurn();
      expect(dao.currentFileHistory, isEmpty);
      final parts = attachments.buildUserContent(user.content) as List;
      expect(parts.first['text'], contains('营收增长'));
      expect(parts.last['image_url']['url'], user.imageUrlsOrB64!.single);
      dao.appendTurn(user, msg(OwnerType.receiver, '再次回答', 3),
          userFileText: attachments.extraText);
      final history = CompletionDao.buildHistory(dao.currentMessages, {},
          fileHistory: dao.currentFileHistory);
      expect(
          (history.first['content'] as List).first['text'], contains('营收增长'));
    });

    test('用上一个 dao 的 currentMessages 重建后仍能 appendTurn / dropLastTurn', () {
      final settings = AISettings.defaults();
      final dao1 = CompletionDao(
        settings: settings,
        messages: [
          msg(OwnerType.sender, '你好', 1),
          msg(OwnerType.receiver, '你好，有什么可以帮你', 2),
        ],
      );

      // 模拟会话页「改设置/切助手」后的重建：传入的是 List.unmodifiable。
      final rebuilt = CompletionDao(
        settings: settings,
        messages: dao1.currentMessages,
      );

      // 修复前：这一步抛 Cannot add to an unmodifiable list。
      expect(
        () => rebuilt.appendTurn(
          msg(OwnerType.sender, '再问一句', 3),
          msg(OwnerType.receiver, '好的', 4),
        ),
        returnsNormally,
      );
      expect(rebuilt.currentMessages.length, 4);

      // 「重新生成」回退路径同理（removeLast）。
      final droppedUser = rebuilt.dropLastTurn();
      expect(droppedUser?.content, '再问一句');
      expect(rebuilt.currentMessages.length, 2);
    });

    test('currentMessages 对外仍是只读（不破坏只读契约）', () {
      final dao = CompletionDao(
        settings: AISettings.defaults(),
        messages: [msg(OwnerType.sender, 'x', 1)],
      );
      expect(
        () => dao.currentMessages.add(msg(OwnerType.sender, 'y', 2)),
        throwsUnsupportedError,
      );
    });

    test('未完成回复状态会进入下一轮 history，且重新生成会清理', () {
      final dao = CompletionDao(settings: AISettings.defaults());
      final user = msg(OwnerType.sender, 'hello', 1);
      final assistant = msg(OwnerType.receiver, 'no response', 2);

      dao.appendTurn(
        user,
        assistant,
        assistantBlocks: const [
          RoleContinuationBlock(
            id: 'b_role_continuation',
            messageId: 'msg_2',
            createdAt: 2,
            status: MessageBlockStatus.success,
            content: '上一轮尚未正式开口，角色紧张地攥住笔记本。',
          ),
        ],
      );

      final history = CompletionDao.buildHistory(
        dao.currentMessages,
        dao.currentToolHistory,
        roleContinuationHistory: dao.currentRoleContinuationHistory,
      );
      expect(history.last['role'], 'assistant');
      expect(history.last['content'], contains('未完成回复状态'));
      expect(history.last['content'], contains('角色紧张地攥住笔记本'));
      expect(history.last['content'], isNot(contains('no response')));

      final dropped = dao.dropLastTurn();
      expect(dropped?.content, 'hello');
      expect(dao.currentRoleContinuationHistory, isEmpty);
    });
  });
}
