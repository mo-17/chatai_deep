import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('cancelled tool returning late cannot overwrite the next reply protocol',
      () async {
    final abort = Completer<void>();
    final started = Completer<void>();
    final release = Completer<ToolOutcome>();
    final completion = CompletionDao(
      settings: AISettings.defaults(),
      chatService: _Service([
        [_call('old')],
        [StreamEvent.reasoning('新的推理'), StreamEvent.text('新的回答')],
      ]),
    );
    final old = completion
        .streamCompletionEvents(
          prompt: '旧任务',
          abortTrigger: abort.future,
          tools: ToolRegistry([
            ChatTool(
              name: 'echo',
              description: 'echo',
              parameters: const {'type': 'object'},
              execute: (_) async {
                started.complete();
                return release.future;
              },
            ),
          ]),
        )
        .toList();
    final cancelled = expectLater(old, throwsA(isA<ChatTransportException>()));
    await started.future;
    abort.complete();
    await completion.streamCompletionEvents(prompt: '新任务').toList();
    final current = jsonEncode(completion.lastProtocolMessages);
    release.complete(const ToolOutcome(content: '迟到的旧结果'));
    await cancelled;
    expect(jsonEncode(completion.lastProtocolMessages), current);
    expect(completion.lastProtocolMessages.single['content'], '新的回答');
  });

  test('multiple reasoning/tool rounds survive SQLite close and reopen exactly',
      () async {
    final directory = await Directory.systemTemp.createTemp('chat-protocol-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/chat.db';
    var db = await databaseFactoryFfi.openDatabase(path);
    var messages = await MessageDao.create(HiDBManager.test(db), cid: 700);
    final service = _Service([
      [
        StreamEvent.reasoning('先读取'),
        StreamEvent.reasoning('两份资料'),
        StreamEvent.text('开始读取。'),
        _call('a'),
        _call('b'),
      ],
      [StreamEvent.reasoning('核验差异'), _call('c')],
      [StreamEvent.reasoning('资料已齐全'), StreamEvent.text('差异总结')],
    ]);
    final completion = CompletionDao(
      settings: AISettings.defaults(),
      chatService: service,
    );
    await completion
        .streamCompletionEvents(
          prompt: '比较资料',
          tools: ToolRegistry([
            ChatTool(
              name: 'echo',
              description: 'echo',
              parameters: const {'type': 'object'},
              execute: (arguments) async =>
                  ToolOutcome(content: '资料 ${arguments['key']}'),
            ),
          ]),
        )
        .toList();
    final protocol = completion.lastProtocolMessages;
    expect(protocol.map((message) => message['role']),
        ['assistant', 'tool', 'tool', 'assistant', 'tool', 'assistant']);
    expect(protocol[0]['reasoning_content'], '先读取两份资料');
    expect(protocol[3]['reasoning_content'], '核验差异');
    expect(protocol.last['reasoning_content'], '资料已齐全');
    final user = _user('比较资料', 101);
    final assistant = _assistant('差异总结', 102);
    final block = MainTextBlock(
      id: 'main',
      messageId: chatMessageKey(102),
      createdAt: 102,
      status: MessageBlockStatus.success,
      content: assistant.content,
      protocolMessages: protocol,
    );
    await messages.saveMessageWithBlocks(user);
    await messages.saveMessageWithBlocks(assistant,
        blocksJson: MessageBlock.encodeList([block]));
    await db.close();

    db = await databaseFactoryFfi.openDatabase(path);
    addTearDown(db.close);
    messages = await MessageDao.create(HiDBManager.test(db), cid: 700);
    final restored = await messages.getAllMessage();
    final encoded = await messages.getBlocksByCreatedAt([102]);
    final blocks = MessageBlock.decodeList(encoded[chatMessageKey(102)]!);
    final recoveredProtocol = blocks
        .whereType<MainTextBlock>()
        .expand((block) => block.protocolMessages)
        .toList();
    final history = CompletionDao.buildHistory(
      restored,
      const {},
      protocolHistory: {102: recoveredProtocol},
    );

    expect(history, [
      {'role': 'user', 'content': '比较资料'},
      ...protocol,
    ]);
    expect(
        history.where((message) => message['content'] == '差异总结'), hasLength(1));
    expect((history[1]['tool_calls'] as List).map((call) => call['id']),
        ['a', 'b']);
    _expectPaired(history);
  });

  test('protocol history replaces legacy tool blocks; regenerate clears both',
      () {
    final completion = CompletionDao(
      settings: AISettings.defaults(),
      chatService: _Service(const []),
    );
    final protocol = [
      {
        'role': 'assistant',
        'content': '完成',
        'reasoning_content': '已核验',
      },
    ];
    completion
        .appendTurn(_user('问题', 1), _assistant('完成', 2), assistantBlocks: [
      MainTextBlock(
        id: 'main',
        messageId: 'assistant',
        createdAt: 2,
        status: MessageBlockStatus.success,
        content: '完成',
        protocolMessages: protocol,
      ),
      const ToolBlock(
        id: 'old-tool',
        messageId: 'assistant',
        createdAt: 2,
        status: MessageBlockStatus.success,
        toolId: 'old',
        toolName: 'echo',
        content: '旧渲染工具结果',
      ),
    ]);
    final history = CompletionDao.buildHistory(
        completion.currentMessages, completion.currentToolHistory,
        protocolHistory: completion.currentProtocolHistory);
    expect(history, [
      {'role': 'user', 'content': '问题'},
      ...protocol,
    ]);
    expect(completion.dropLastTurn()!.createdAt, 1);
    expect(completion.currentProtocolHistory, isEmpty);
    expect(completion.currentToolHistory, isEmpty);
    expect(completion.currentMessages, isEmpty);
  });

  test(
      'incomplete multi-tool checkpoint cannot produce an unpaired next request',
      () {
    final history = CompletionDao.buildHistory(
      [_user('比较资料', 1), _assistant('操作被中断', 2)],
      const {},
      protocolHistory: {
        2: [
          {
            'role': 'assistant',
            'content': '',
            'reasoning_content': '需要两份资料',
            'tool_calls': [
              _jsonCall('a'),
              _jsonCall('b'),
            ],
          },
          {'role': 'tool', 'tool_call_id': 'a', 'content': '资料 a'},
        ],
      },
    );
    _expectPaired(history);
    expect(history.last['role'], 'assistant');
    expect(history.last['content'], '操作被中断');
    expect(history[1]['reasoning_content'], '需要两份资料');
    expect(history.where((message) => message['tool_call_id'] == 'b'),
        hasLength(1));
  });

  test('legacy text blocks and ordinary reasoning snapshots both remain valid',
      () async {
    final legacy = MessageBlock.fromJson({
      'id': 'legacy',
      'messageId': 'assistant',
      'type': 'mainText',
      'status': 'success',
      'createdAt': 2,
      'content': '旧回答',
    }) as MainTextBlock;
    expect(legacy.protocolMessages, isEmpty);
    expect(
        CompletionDao.buildHistory(
          [_user('旧问题', 1), _assistant('旧回答', 2)],
          const {},
        ),
        [
          {'role': 'user', 'content': '旧问题'},
          {'role': 'assistant', 'content': '旧回答'},
        ]);
    final completion = CompletionDao(
      settings: AISettings.defaults(),
      chatService: _Service([
        [StreamEvent.reasoning('先考虑'), StreamEvent.text('新回答')],
        [StreamEvent.text('没有思考的回答')],
      ]),
    );
    await completion.streamCompletionEvents(prompt: '新问题').toList();
    expect(completion.lastProtocolMessages.single, {
      'role': 'assistant',
      'content': '新回答',
      'reasoning_content': '先考虑',
    });
    await completion.streamCompletionEvents(prompt: '再问').toList();
    expect(completion.lastProtocolMessages.single, {
      'role': 'assistant',
      'content': '没有思考的回答',
      'reasoning_content': '',
    });
  });

  test('isolated old tool result falls back to the saved assistant text', () {
    final history = CompletionDao.buildHistory(
      [_user('问题', 1), _assistant('已有回答', 2)],
      const {},
      protocolHistory: {
        2: [
          {'role': 'tool', 'tool_call_id': 'orphan', 'content': '孤立结果'},
        ],
      },
    );
    expect(history, [
      {'role': 'user', 'content': '问题'},
      {'role': 'assistant', 'content': '已有回答'},
    ]);
  });

  test('reasoning-only protocol keeps role continuation without losing replay',
      () {
    final history = CompletionDao.buildHistory(
      [_user('继续角色故事', 1), _assistant('', 2)],
      const {},
      protocolHistory: {
        2: [
          {
            'role': 'assistant',
            'content': '',
            'reasoning_content': '角色正准备回应',
          },
        ],
      },
      roleContinuationHistory: {2: '角色已经决定先观察环境'},
    );
    expect(history, hasLength(2));
    expect(history.last['content'],
        CompletionDao.roleContinuationPrompt('角色已经决定先观察环境'));
    expect(history.last['reasoning_content'], '角色正准备回应');
  });
}

MessageModel _user(String content, int at) =>
    MessageModel(ownerType: OwnerType.sender, content: content, createdAt: at);
MessageModel _assistant(String content, int at) => MessageModel(
    ownerType: OwnerType.receiver, content: content, createdAt: at);
StreamEvent _call(String id) =>
    StreamEvent.toolCall(toolId: id, name: 'echo', arguments: {'key': id});
Map<String, dynamic> _jsonCall(String id) => {
      'id': id,
      'type': 'function',
      'function': {
        'name': 'echo',
        'arguments': jsonEncode({'key': id})
      },
    };

void _expectPaired(List<Map<String, dynamic>> messages) {
  final pending = <String>{};
  for (final message in messages) {
    if (message['role'] == 'assistant') {
      expect(pending, isEmpty, reason: '上一轮工具结果未收齐，不可开始新的 assistant 消息');
      for (final call in (message['tool_calls'] as List? ?? const [])) {
        pending.add(call['id'] as String);
      }
    } else if (message['role'] == 'tool') {
      expect(pending.remove(message['tool_call_id']), isTrue,
          reason: 'role:tool 必须有对应 assistant.tool_calls');
    }
  }
  expect(pending, isEmpty, reason: '下一次请求不可回灌未配对工具调用');
}

class _Service implements ChatService {
  final List<List<StreamEvent>> rounds;
  int requests = 0;
  _Service(this.rounds);
  @override
  ModelCapabilities get capabilities =>
      const ModelCapabilities(tool: true, reasoning: true);
  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) =>
      Stream.fromIterable(rounds[requests++]);
  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) async =>
      null;
  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async =>
      const ChatCompletionResult(content: null);
  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      const Stream.empty();
}
