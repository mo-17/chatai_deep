import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/semantic_chat_summary_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/semantic_chat_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('SQLite reopening resumes complete tool rounds without executing again',
      () async {
    final directory = await Directory.systemTemp.createTemp('agent-resume-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/task.db';
    var db = await databaseFactoryFfi.openDatabase(path);
    final first = AgentTaskSession(
      cid: 7,
      store: await AgentTaskDao.create(HiDBManager.test(db)),
    );
    await first.setEnabled(true);
    await first.begin(userAt: 101, input: '比较两份资料');
    await first.todoTool.execute({
      'todos': [
        {'content': '读取资料', 'status': 'completed'},
        {'content': '比较差异', 'status': 'in_progress'},
      ],
    });
    final protocol = [
      _assistant(['a'], '先读第一份'),
      _result('a', '资料 A'),
      _assistant(['b'], '再读第二份'),
      _result('b', '资料 B'),
    ];
    await first.checkpoint(protocol, 2);
    await first.finish(complete: false);
    first.dispose();
    await db.close();

    db = await databaseFactoryFfi.openDatabase(path);
    addTearDown(db.close);
    final reopened = AgentTaskSession(
      cid: 7,
      store: await AgentTaskDao.create(HiDBManager.test(db)),
    );
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.canResume, isTrue);
    expect(reopened.todos.map((todo) => todo.status),
        ['completed', 'in_progress']);
    await reopened.begin(userAt: 101, input: '比较两份资料', resume: true);
    final service = _Service([
      [StreamEvent.reasoning('综合两份资料。'), StreamEvent.text('差异如下')],
    ]);
    var executions = 0;
    final events = await ToolLoopRunner(
      chatService: service,
      registry: ToolRegistry([
        _echo((_) async {
          executions++;
          return const ToolOutcome(content: '不应重做');
        }),
      ]),
    ).run(prompt: reopened.prompt, history: const [], task: reopened).toList();

    expect(executions, 0);
    expect(service.extra.single, protocol);
    expect(
        events
            .where((event) => event.type == StreamEventType.toolResult)
            .map((event) => event.toolContent),
        ['资料 A', '资料 B']);
    expect(reopened.messages.last['reasoning_content'], '综合两份资料。');
    expect(reopened.messages.last['content'], '差异如下');
  });

  test('uncertain interrupted tool is not replayed; pending tool executes once',
      () async {
    final task = await _task();
    await task.checkpoint([
      _assistant(['a', 'b'], '读取资料')
    ], 1, executing: 'a');
    await task.finish(complete: false);
    final executions = <String>[];
    final service = _Service([
      [StreamEvent.text('继续完成任务')],
    ]);
    await ToolLoopRunner(
      chatService: service,
      registry: ToolRegistry([
        _echo((arguments) async {
          executions.add(arguments['key'] as String);
          return const ToolOutcome(content: '资料 B');
        }),
      ]),
    ).run(prompt: task.prompt, history: const [], task: task).toList();

    expect(executions, ['b']);
    expect(service.extra.single[1]['tool_call_id'], 'a');
    expect(service.extra.single[1]['content'], contains('禁止自动重复'));
    expect(service.extra.single[2], _result('b', '资料 B'));
    _expectPaired(service.extra.single);
  });

  test(
      'cancel during first tool saves its result and resumes only remaining tool',
      () async {
    final task = await _task();
    final abort = Completer<void>();
    final started = Completer<void>();
    final release = Completer<ToolOutcome>();
    final executions = <String>[];
    final registry = ToolRegistry([
      _echo((arguments) async {
        final key = arguments['key'] as String;
        executions.add(key);
        if (key == 'a') {
          started.complete();
          return release.future;
        }
        return const ToolOutcome(content: '资料 B');
      }),
    ]);
    final firstService = _Service([
      [StreamEvent.reasoning('读取两份资料'), _call('a'), _call('b')],
    ]);
    final first = ToolLoopRunner(chatService: firstService, registry: registry)
        .run(
          prompt: task.prompt,
          history: const [],
          task: task,
          abortTrigger: abort.future,
        )
        .toList();
    final cancelled = expectLater(
      first,
      throwsA(isA<ChatTransportException>()
          .having((error) => error.safeCode, 'safeCode', 'cancelled')),
    );
    await started.future;
    abort.complete();
    release.complete(const ToolOutcome(content: '资料 A'));
    await cancelled;
    await task.finish(complete: false);

    expect(executions, ['a']);
    expect(task.messages.last, _result('a', '资料 A'));
    expect(task.executingToolId, isNull);
    final reopened = AgentTaskSession(cid: task.cid, store: task.store);
    addTearDown(reopened.dispose);
    await reopened.load();
    await reopened.begin(userAt: 101, input: '比较两份资料', resume: true);
    final resumedService = _Service([
      [StreamEvent.reasoning('完成比较'), StreamEvent.text('比较完成')],
    ]);
    await ToolLoopRunner(chatService: resumedService, registry: registry)
        .run(prompt: reopened.prompt, history: const [], task: reopened)
        .toList();

    expect(executions, ['a', 'b']);
    expect(resumedService.extra.single[0]['reasoning_content'], '读取两份资料');
    expect(resumedService.extra.single.skip(1),
        [_result('a', '资料 A'), _result('b', '资料 B')]);
    _expectPaired(resumedService.extra.single);
  });

  test(
      'completed final checkpoint replays answer without another model request',
      () async {
    final task = await _task();
    await task.checkpoint([
      _assistant(['a'], '调用工具'),
      _result('a', '工具结果'),
      {
        'role': 'assistant',
        'content': '任务已完成',
        'reasoning_content': '结果已核对',
      },
    ], 1);
    // 模拟最终结果已写入但 finish(complete:true) 前退出。
    final reopened = AgentTaskSession(cid: task.cid, store: task.store);
    addTearDown(reopened.dispose);
    await reopened.load();
    final service = _Service(const []);
    var executions = 0;
    final events = await ToolLoopRunner(
      chatService: service,
      registry: ToolRegistry([
        _echo((_) async {
          executions++;
          return const ToolOutcome(content: '不应重复');
        }),
      ]),
    ).run(prompt: reopened.prompt, history: const [], task: reopened).toList();

    expect(service.extra, isEmpty);
    expect(executions, 0);
    expect(
        events
            .where((event) => event.type == StreamEventType.text)
            .map((event) => event.delta),
        ['任务已完成']);
    expect(
        events
            .where((event) => event.type == StreamEventType.reasoning)
            .map((event) => event.delta),
        ['结果已核对']);
  });

  test('uncertain operation cannot repeat under a new id or another resume',
      () async {
    final task = await _task();
    const original = {
      'target': 'favorite',
      'payload': {
        'text': '资料',
        'tags': ['A', 'B']
      },
    };
    const reordered = {
      'payload': {
        'tags': ['A', 'B'],
        'text': '资料'
      },
      'target': 'favorite',
    };
    await task.checkpoint([
      {
        'role': 'assistant',
        'content': '',
        'reasoning_content': '保存资料',
        'tool_calls': [
          {
            'id': 'before-crash',
            'type': 'function',
            'function': {
              'name': 'echo',
              'arguments': jsonEncode(original),
            },
          },
        ],
      },
    ], 1, executing: 'before-crash');
    var executions = 0;
    final registry = ToolRegistry([
      _echo((_) async {
        executions++;
        return const ToolOutcome(content: '禁止重复此写入');
      }),
    ]);
    final abort = Completer<void>();
    final service = _Service([
      [
        StreamEvent.reasoning('再尝试保存'),
        StreamEvent.toolCall(
            toolId: 'new-id', name: 'echo', arguments: reordered),
      ],
    ]);
    await expectLater(
      ToolLoopRunner(chatService: service, registry: registry)
          .run(
            prompt: task.prompt,
            history: const [],
            task: task,
            abortTrigger: abort.future,
            onProtocolMessages: (messages) {
              if (messages.any((message) =>
                  message['role'] == 'tool' &&
                  message['tool_call_id'] == 'new-id')) {
                abort.complete();
              }
            },
          )
          .toList(),
      throwsA(isA<ChatTransportException>()
          .having((error) => error.safeCode, 'safeCode', 'cancelled')),
    );
    await task.finish(complete: false);
    expect(executions, 0);
    expect(task.messages.last['content'], contains('禁止自动重复'));

    final reopened = AgentTaskSession(cid: task.cid, store: task.store);
    addTearDown(reopened.dispose);
    await reopened.load();
    await reopened.begin(userAt: 101, input: '比较两份资料', resume: true);
    final secondService = _Service([
      [
        StreamEvent.toolCall(
            toolId: 'another-new-id', name: 'echo', arguments: original),
      ],
      [StreamEvent.text('请用户核对保存结果')],
    ]);
    await ToolLoopRunner(chatService: secondService, registry: registry)
        .run(prompt: reopened.prompt, history: const [], task: reopened)
        .toList();
    expect(executions, 0);
    expect(secondService.extra.last.last['tool_call_id'], 'another-new-id');
    expect(secondService.extra.last.last['content'], contains('禁止自动重复'));
    _expectPaired(secondService.extra.last);
  });

  test('human resume continues pending todo after a saved final answer',
      () async {
    final task = await _task();
    await task.todoTool.execute({
      'todos': [
        {'content': '读取资料', 'status': 'completed'},
        {'content': '比较资料', 'status': 'pending'},
      ],
    });
    final saved = [
      _assistant(['read'], '先读取资料'),
      _result('read', '已读取'),
      {
        'role': 'assistant',
        'content': '读取已完成，比较仍未完成',
        'reasoning_content': '需要下一轮继续',
      },
    ];
    await task.checkpoint(saved, ToolLoopRunner.maxRounds);
    await task.finish(complete: true);
    expect(task.canResume, isTrue);
    expect(task.status, 'paused');
    expect(task.needsContinuation, isTrue);

    final reopened = AgentTaskSession(cid: task.cid, store: task.store);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.needsContinuation, isTrue);
    await reopened.begin(userAt: 101, input: '比较两份资料', resume: true);
    expect(reopened.nextRound, 0);
    expect(reopened.messages, saved);
    final service = _Service([
      [
        StreamEvent.reasoning('已完成比较并核验'),
        StreamEvent.toolCall(toolId: 'todo', name: 'todo_write', arguments: {
          'todos': [
            {'content': '读取资料', 'status': 'completed'},
            {'content': '比较资料', 'status': 'completed'},
          ],
        }),
      ],
      [StreamEvent.text('比较结果已完成')],
    ]);
    var readExecutions = 0;
    final events = await ToolLoopRunner(
      chatService: service,
      registry: ToolRegistry([
        reopened.todoTool,
        _echo((_) async {
          readExecutions++;
          return const ToolOutcome(content: '读取不能重做');
        }),
      ]),
    ).run(prompt: reopened.prompt, history: const [], task: reopened).toList();
    expect(service.extra, hasLength(2));
    expect(service.extra.first, saved);
    expect(service.declarations.first, isNotNull);
    expect(readExecutions, 0);
    expect(
        events
            .where((event) => event.type == StreamEventType.text)
            .map((event) => event.delta),
        ['比较结果已完成']);
    await reopened.finish(complete: true);
    expect(reopened.status, 'complete');
    expect(reopened.canResume, isFalse);
    expect(reopened.needsContinuation, isFalse);
  });

  test('legacy conversation has task mode off until explicitly enabled',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final store = await AgentTaskDao.create(HiDBManager.test(db));
    final task = AgentTaskSession(cid: 700, store: store);
    addTearDown(task.dispose);
    await task.load();
    expect(task.enabled, isFalse);
    expect(task.canResume, isFalse);
    expect(task.status, 'idle');
    expect(task.messages, isEmpty);
    expect(task.todos, isEmpty);
    expect(await store.read(700), isNull);
  });

  test('invalid todo replacements leave the previous persisted list intact',
      () async {
    final task = await _task();
    await task.todoTool.execute({
      'todos': [
        {'content': '有效任务', 'status': 'pending'},
      ],
    });
    final before = jsonEncode(await task.store.read(task.cid));
    final invalid = <Object?>[
      null,
      [
        for (var index = 0; index < 21; index++)
          {'content': '任务 $index', 'status': 'pending'},
      ],
      [42],
      [
        {'content': 42, 'status': 'pending'},
      ],
      [
        {'content': '   ', 'status': 'pending'},
      ],
      [
        {'content': 'a' * 301, 'status': 'pending'},
      ],
      [
        {'content': '重复', 'status': 'pending'},
        {'content': '重复', 'status': 'completed'},
      ],
      [
        {'content': '任务', 'status': 'unknown'},
      ],
      [
        {'content': '第一步', 'status': 'in_progress'},
        {'content': '第二步', 'status': 'in_progress'},
      ],
    ];
    for (final raw in invalid) {
      final outcome = await task.todoTool.execute({'todos': raw});
      expect(outcome.content, startsWith('错误'));
      expect(task.todos.single.content, '有效任务');
      expect(jsonEncode(await task.store.read(task.cid)), before);
    }
  });

  test('new begin resets todo and protocol; stale checkpoint cannot overwrite',
      () async {
    final task = await _task();
    await task.todoTool.execute({
      'todos': [
        {'content': '旧任务', 'status': 'in_progress'},
      ],
    });
    await task.checkpoint([
      _assistant(['a'], '旧思考')
    ], 3, executing: 'a');
    final previousGeneration = task.generation;
    await task.begin(userAt: 202, input: '新的独立任务');
    expect(task.prompt, '新的独立任务');
    expect(task.userCreatedAt, 202);
    expect(task.todos, isEmpty);
    expect(task.messages, isEmpty);
    expect(task.nextRound, 0);
    expect(task.executingToolId, isNull);
    expect(task.generation, greaterThan(previousGeneration));
    final current = jsonEncode(await task.store.read(task.cid));
    await task.checkpoint([
      _assistant(['a'], '迟到的旧思考')
    ], 4, executing: 'a', expectedGeneration: previousGeneration);
    expect(task.messages, isEmpty);
    expect(task.executingToolId, isNull);
    expect(jsonEncode(await task.store.read(task.cid)), current);
  });

  test('conversation deletion removes messages, task and summary only for cid',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final storage = HiDBManager.test(db);
    final conversations = await ConversationListDao.create(storage);
    final tasks = await AgentTaskDao.create(storage);
    final summaries = await SemanticChatSummaryDao.create(storage);
    final records = <ConversationModel>[];
    for (final cid in [7, 8]) {
      final conversation = ConversationModel(
          cid: cid, title: '会话 $cid', icon: '', updateAt: cid);
      await conversations.saveConversation(conversation);
      records.add(conversation);
      final messages = await MessageDao.create(storage, cid: cid);
      await messages.saveMessageWithBlocks(MessageModel(
          ownerType: OwnerType.sender, content: '消息 $cid', createdAt: cid));
      await tasks.write(cid, {'enabled': true, 'status': 'paused'});
      await summaries.save(SemanticChatSummary(
          cid: cid,
          sourceFingerprint: 'fingerprint-$cid',
          sourceMessageCount: 10,
          content: '摘要 $cid',
          createdAt: cid));
    }

    await conversations.deleteConversation(records.first);
    expect(await tasks.read(7), isNull);
    expect(await summaries.get(7, 'fingerprint-7'), isNull);
    expect(await db.query('tb_messages', where: 'cid = ?', whereArgs: [7]),
        isEmpty);
    expect((await conversations.getConversationList()).single.cid, 8);
    expect(await tasks.read(8), {'enabled': true, 'status': 'paused'});
    expect((await summaries.get(8, 'fingerprint-8'))!.content, '摘要 8');
    expect(await db.query('tb_messages', where: 'cid = ?', whereArgs: [8]),
        hasLength(1));
  });

  test('legacy database without task or summary tables still deletes safely',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final storage = HiDBManager.test(db);
    final conversations = await ConversationListDao.create(storage);
    final conversation =
        ConversationModel(cid: 7, title: '旧会话', icon: '', updateAt: 1);
    await conversations.saveConversation(conversation);
    final messages = await MessageDao.create(storage, cid: 7);
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, content: '旧消息', createdAt: 1));
    // 新建的会话内存模型可能没有数据库 id，按 cid 也能完整清理。
    await conversations
        .deleteConversation(ConversationModel(cid: 7, title: '旧会话', icon: ''));
    expect(await conversations.getConversationList(), isEmpty);
    expect(await db.query('tb_messages'), isEmpty);
    expect(
        await db.rawQuery(
            "select name from sqlite_master where type = 'table' and "
            "name in ('tb_agent_task_session', 'tb_chat_semantic_summary')"),
        isEmpty);
  });

  test('failed derived-table cleanup rolls back conversation deletion',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final storage = HiDBManager.test(db);
    final conversations = await ConversationListDao.create(storage);
    final conversation =
        ConversationModel(cid: 7, title: '保留会话', icon: '', updateAt: 1);
    await conversations.saveConversation(conversation);
    final messages = await MessageDao.create(storage, cid: 7);
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, content: '保留消息', createdAt: 1));
    final tasks = await AgentTaskDao.create(storage);
    await tasks.write(7, {'enabled': true});
    final summaries = await SemanticChatSummaryDao.create(storage);
    await summaries.save(const SemanticChatSummary(
        cid: 7,
        sourceFingerprint: 'fingerprint',
        sourceMessageCount: 1,
        content: '保留摘要',
        createdAt: 1));
    await db.execute('create trigger fail_cleanup '
        'before delete on tb_chat_semantic_summary '
        "begin select raise(abort, 'test rollback'); end");

    await expectLater(conversations.deleteConversation(conversation),
        throwsA(isA<DatabaseException>()));
    expect((await conversations.getConversationList()).single.cid, 7);
    expect(await messages.getMessageCount(), 1);
    expect(await tasks.read(7), {'enabled': true});
    expect((await summaries.get(7, 'fingerprint'))!.content, '保留摘要');
  });
}

Future<AgentTaskSession> _task() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  addTearDown(db.close);
  final task = AgentTaskSession(
    cid: 7,
    store: await AgentTaskDao.create(HiDBManager.test(db)),
  );
  addTearDown(task.dispose);
  await task.setEnabled(true);
  await task.begin(userAt: 101, input: '比较两份资料');
  return task;
}

Map<String, dynamic> _assistant(List<String> ids, String reasoning) => {
      'role': 'assistant',
      'content': '',
      'reasoning_content': reasoning,
      'tool_calls': [
        for (final id in ids)
          {
            'id': id,
            'type': 'function',
            'function': {
              'name': 'echo',
              'arguments': jsonEncode({'key': id}),
            },
          },
      ],
    };

Map<String, dynamic> _result(String id, String content) =>
    {'role': 'tool', 'tool_call_id': id, 'content': content};

StreamEvent _call(String id) =>
    StreamEvent.toolCall(toolId: id, name: 'echo', arguments: {'key': id});

ChatTool _echo(Future<ToolOutcome> Function(Map<String, dynamic>) execute) =>
    ChatTool(
      name: 'echo',
      description: 'echo',
      parameters: const {'type': 'object'},
      execute: execute,
    );

void _expectPaired(List<Map<String, dynamic>> messages) {
  final calls = [
    for (final message in messages)
      for (final call in (message['tool_calls'] as List? ?? const []))
        call['id'],
  ];
  final results = [
    for (final message in messages)
      if (message['role'] == 'tool') message['tool_call_id'],
  ];
  expect(results, calls);
}

class _Service implements ChatService, OptionsAwareChatService {
  final List<List<StreamEvent>> rounds;
  final extra = <List<Map<String, dynamic>>>[];
  final declarations = <List<Map<String, dynamic>>?>[];
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
  }) async* {
    final index = extra.length;
    declarations.add(tools);
    extra.add([
      for (final message in jsonDecode(jsonEncode(extraMessages)) as List)
        (message as Map).cast<String, dynamic>(),
    ]);
    yield* Stream.fromIterable(rounds[index]);
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) =>
      chatStreamEvents(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
      );

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
