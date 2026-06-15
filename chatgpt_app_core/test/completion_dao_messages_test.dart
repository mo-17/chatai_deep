import 'package:chat_message/models/message_model.dart';
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
  });
}
