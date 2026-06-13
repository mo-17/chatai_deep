import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:flutter_test/flutter_test.dart';

/// 遗留项 2 验收：工具调用历史跨轮。
///
/// 在落库 history 里，assistant 若在该轮调用过工具，必须能重建出
/// 「assistant(tool_calls) + role:tool 结果」配对，使下一轮请求看得到工具
/// 调用与结果（而非只剩正文）。覆盖 [CompletionDao.toolCallMessages] 与
/// [CompletionDao.buildHistory] 两个纯函数。
void main() {
  ToolBlock toolBlock({
    String toolId = 'call_1',
    String? name = 'web_search',
    Map<String, dynamic>? args,
    Object? content = '搜索结果文本',
    int createdAt = 2,
  }) =>
      ToolBlock(
        id: 'blk_$toolId',
        messageId: 'msg_$createdAt',
        createdAt: createdAt,
        status: MessageBlockStatus.success,
        toolId: toolId,
        toolName: name,
        arguments: args,
        content: content,
      );

  MessageModel user(String content, {int createdAt = 1, List<String>? images}) =>
      MessageModel(
        ownerType: OwnerType.sender,
        content: content,
        createdAt: createdAt,
        imageUrlsOrB64: images,
      );

  MessageModel assistant(String content, {int createdAt = 2}) => MessageModel(
        ownerType: OwnerType.receiver,
        content: content,
        createdAt: createdAt,
      );

  group('CompletionDao.toolCallMessages 还原 OpenAI 工具消息', () {
    test('一个工具块 -> assistant(tool_calls) + role:tool 配对', () {
      final msgs = CompletionDao.toolCallMessages([
        toolBlock(
          toolId: 'call_abc',
          name: 'web_search',
          args: {'query': 'flutter'},
          content: '命中 3 条',
        ),
      ]);

      expect(msgs.length, 2);

      final asst = msgs[0];
      expect(asst['role'], 'assistant');
      expect(asst['content'], isNull);
      final calls = asst['tool_calls'] as List;
      expect(calls.length, 1);
      final call = calls.first as Map;
      expect(call['id'], 'call_abc');
      expect(call['type'], 'function');
      final fn = call['function'] as Map;
      expect(fn['name'], 'web_search');
      // arguments 必须是 JSON 字符串（OpenAI 协议要求），不是 Map
      expect(fn['arguments'], '{"query":"flutter"}');

      final tool = msgs[1];
      expect(tool['role'], 'tool');
      expect(tool['tool_call_id'], 'call_abc');
      expect(tool['content'], '命中 3 条');
    });

    test('null arguments -> "{}"；非字符串结果 -> JSON 编码', () {
      final msgs = CompletionDao.toolCallMessages([
        toolBlock(toolId: 'c1', args: null, content: {'ok': true}),
      ]);
      final fn = (msgs[0]['tool_calls'] as List).first['function'] as Map;
      expect(fn['arguments'], '{}');
      expect(msgs[1]['content'], '{"ok":true}');
    });

    test('多个工具调用 -> 逐对输出（每个 tool 紧跟其 assistant）', () {
      final msgs = CompletionDao.toolCallMessages([
        toolBlock(toolId: 'a', content: 'ra'),
        toolBlock(toolId: 'b', content: 'rb'),
      ]);
      expect(msgs.length, 4);
      expect(msgs[0]['role'], 'assistant');
      expect((msgs[0]['tool_calls'] as List).first['id'], 'a');
      expect(msgs[1]['tool_call_id'], 'a');
      expect(msgs[2]['role'], 'assistant');
      expect((msgs[2]['tool_calls'] as List).first['id'], 'b');
      expect(msgs[3]['tool_call_id'], 'b');
    });

    test('空 toolId 无法配对 -> 跳过', () {
      final msgs = CompletionDao.toolCallMessages([
        toolBlock(toolId: ''),
      ]);
      expect(msgs, isEmpty);
    });
  });

  group('CompletionDao.buildHistory 跨轮重建', () {
    test('无工具的 assistant：照旧只发 {role, content}', () {
      final history = CompletionDao.buildHistory(
        [user('你好', createdAt: 1), assistant('你好呀', createdAt: 2)],
        const {},
      );
      expect(history, [
        {'role': 'user', 'content': '你好'},
        {'role': 'assistant', 'content': '你好呀'},
      ]);
    });

    test('有工具的 assistant：正文消息前插入 tool_calls/role:tool 配对', () {
      final history = CompletionDao.buildHistory(
        [user('北京天气？', createdAt: 1), assistant('今天晴', createdAt: 2)],
        {
          2: [
            toolBlock(
                toolId: 'call_w',
                name: 'web_search',
                args: {'query': '北京天气'},
                content: '晴 25℃',
                createdAt: 2),
          ],
        },
      );

      expect(history.length, 4);
      expect(history[0], {'role': 'user', 'content': '北京天气？'});
      // 工具调用配对在正文之前
      expect(history[1]['role'], 'assistant');
      expect((history[1]['tool_calls'] as List).first['id'], 'call_w');
      expect(history[2], {
        'role': 'tool',
        'tool_call_id': 'call_w',
        'content': '晴 25℃',
      });
      // 最后才是 assistant 正文（最终答复）
      expect(history[3], {'role': 'assistant', 'content': '今天晴'});
    });

    test('跨轮：仅带工具的那一轮重建，其它轮不受影响', () {
      final history = CompletionDao.buildHistory(
        [
          user('查一下', createdAt: 1),
          assistant('好的，结果是 A', createdAt: 2), // 这一轮用了工具
          user('谢谢', createdAt: 3),
          assistant('不客气', createdAt: 4), // 这一轮没用工具
        ],
        {
          2: [toolBlock(toolId: 'call_1', content: 'A', createdAt: 2)],
        },
      );

      expect(history.map((m) => m['role']).toList(), [
        'user', // 查一下
        'assistant', // tool_calls
        'tool', // 结果
        'assistant', // 结果是 A
        'user', // 谢谢
        'assistant', // 不客气（无工具配对）
      ]);
      expect(history[3]['content'], '好的，结果是 A');
      expect(history[5]['content'], '不客气');
      expect(history[5].containsKey('tool_calls'), isFalse);
    });

    test('带图片的 user 消息：vision content 数组保持不变（回归）', () {
      final history = CompletionDao.buildHistory(
        [
          user('看图', createdAt: 1, images: ['data:image/png;base64,AAA']),
        ],
        const {},
      );
      final content = history[0]['content'] as List;
      expect(content[0], {'type': 'text', 'text': '看图'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AAA'},
      });
    });
  });

  group('CompletionDao.buildHistory 附件文本跨轮（遗留项 6）', () {
    const fileText = '[附件「a.txt」内容开始]\nhello\n[附件「a.txt」内容结束]';

    test('user 带附件文本：拼回 content（正文\\n\\n文本，与 buildUserContent 一致）', () {
      final history = CompletionDao.buildHistory(
        [user('看下这个', createdAt: 1)],
        const {},
        fileHistory: {1: fileText},
      );
      expect(history.single, {
        'role': 'user',
        'content': '看下这个\n\n$fileText',
      });
    });

    test('正文为空时：content 即附件文本（不留前导空行）', () {
      final history = CompletionDao.buildHistory(
        [user('', createdAt: 1)],
        const {},
        fileHistory: {1: fileText},
      );
      expect(history.single['content'], fileText);
    });

    test('图片 + 附件文本：文本 part 含两者，图片 part 不变', () {
      final history = CompletionDao.buildHistory(
        [user('看图也看文件', createdAt: 1, images: ['data:image/png;base64,AAA'])],
        const {},
        fileHistory: {1: fileText},
      );
      final content = history.single['content'] as List;
      expect(content[0]['type'], 'text');
      expect(content[0]['text'], '看图也看文件\n\n$fileText');
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AAA'},
      });
    });

    test('无附件文本的 user 不受影响（回归）', () {
      final history = CompletionDao.buildHistory(
        [user('纯文本', createdAt: 1)],
        const {},
        fileHistory: {2: fileText}, // 另一条消息的，不应命中
      );
      expect(history.single, {'role': 'user', 'content': '纯文本'});
    });
  });
}
