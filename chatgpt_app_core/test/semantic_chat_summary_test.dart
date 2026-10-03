import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/semantic_chat_summary_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/semantic_chat_summary_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _policy = ChatContextPolicy(
  contextWindowTokens: 1600,
  defaultOutputTokens: 200,
  safetyTokens: 50,
  maxSummaryTokens: 220,
  usesFallbackBudget: false,
);

const _summary = '{"goal":["比较小说"],"facts":["已读 A"],'
    '"constraints":["保持原文"],"completed":["建立评分表"],"pending":["评价 B"]}';

List<Map<String, dynamic>> _history() => [
      for (var i = 0; i < 8; i++) ...[
        {'role': 'user', 'content': 'Question $i ${'old fact ' * 80}'},
        {'role': 'assistant', 'content': 'Answer $i ${'known detail ' * 80}'},
      ],
      {'role': 'user', 'content': 'latest'},
      {
        'role': 'assistant',
        'content': null,
        'reasoning_content': 'brief reasoning',
        'tool_calls': [
          {
            'id': 'call',
            'type': 'function',
            'function': {'name': 'calc', 'arguments': '{}'}
          },
        ]
      },
      {'role': 'tool', 'tool_call_id': 'call', 'content': '42'},
      {'role': 'assistant', 'content': 'Latest answer is 42'},
    ];

ChatContextPlan _plan(List<Map<String, dynamic>> history, {String? summary}) =>
    const ChatContextPlanner().plan(
      history: history,
      systemPrompt: 'system',
      prompt: 'continue',
      policy: _policy,
      semanticSummary: summary,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late HiDBManager storage;
  late SemanticChatSummaryDao store;
  setUp(() async {
    storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    store = await SemanticChatSummaryDao.create(storage);
  });
  tearDown(() => storage.db.close());

  test('旧会话无摘要兼容；短历史不调用模型也不新建摘要行', () async {
    var called = false;
    final service = SemanticChatSummaryService(
      store: store,
      summarizer: (_) async {
        called = true;
        return _summary;
      },
    );
    expect(await store.get(10, 'missing'), isNull);
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'hello'},
      {'role': 'assistant', 'content': 'world'},
    ];
    final legacyPlan = _plan(history);
    final result =
        await service.prepare(cid: 10, history: history, plan: legacyPlan);
    expect(result.summary, isNull);
    expect(called, isFalse);
    expect(_plan(history, summary: result.summary).history, legacyPlan.history);
    expect(await storage.db.query(store.tableName), isEmpty);
  });

  test('摘要按 cid 和完整源指纹命中，编辑任一旧内容会失效', () async {
    var calls = 0;
    final service = SemanticChatSummaryService(
      store: store,
      summarizer: (_) async {
        calls++;
        return _summary;
      },
    );
    final history = _history();
    final before = jsonEncode(history);
    final first =
        await service.prepare(cid: 7, history: history, plan: _plan(history));
    final second =
        await service.prepare(cid: 7, history: history, plan: _plan(history));
    expect(calls, 1);
    expect(first.fromCache, isFalse);
    expect(second.fromCache, isTrue);
    expect(second.summary, first.summary);
    expect(first.summary, contains('待办：评价 B'));
    expect(jsonEncode(history), before);

    history[0]['content'] = '${history[0]['content']} corrected';
    final corrected =
        await service.prepare(cid: 7, history: history, plan: _plan(history));
    expect(calls, 2);
    expect(corrected.fromCache, isFalse);
    expect(corrected.sourceFingerprint, isNot(first.sourceFingerprint));
    // 另一个会话绝不能复用相同历史的摘要。
    await service.prepare(cid: 8, history: history, plan: _plan(history));
    expect(calls, 3);
    await store.deleteForConversation(7);
    expect(await store.get(7, corrected.sourceFingerprint!), isNull);
    expect(await store.get(8, corrected.sourceFingerprint!), isNotNull);
  });

  test('源工具参数、结果、附件和推理修改都改变指纹，key 顺序不影响', () {
    final source = <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'content': 'answer',
        'reasoning_content': 'thought',
        'tool_calls': [
          {
            'id': 'a',
            'function': {'name': 'calc', 'arguments': '{"n":2}'}
          }
        ],
      },
      {'role': 'tool', 'tool_call_id': 'a', 'content': '4'},
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,AA'}
          }
        ]
      },
    ];
    final fingerprint = SemanticChatSummaryService.sourceFingerprint(source);
    final reordered = <Map<String, dynamic>>[
      for (final row in source)
        {for (final key in row.keys.toList().reversed) key: row[key]},
    ];
    expect(
        SemanticChatSummaryService.sourceFingerprint(reordered), fingerprint);
    for (final update in <void Function(List<Map<String, dynamic>>)>[
      (rows) => rows[0]['reasoning_content'] = 'new thought',
      (rows) => rows[0]['tool_calls'][0]['function']['arguments'] = '{"n":3}',
      (rows) => rows[1]['content'] = '5',
      (rows) => rows[2]['content'][0]['image_url']['url'] =
          'data:image/png;base64,BB',
    ]) {
      final copy = (jsonDecode(jsonEncode(source)) as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      update(copy);
      expect(SemanticChatSummaryService.sourceFingerprint(copy),
          isNot(fingerprint));
    }
  });

  test('预算变更导致省略区间改变时不复用旧摘要', () async {
    var calls = 0;
    final service = SemanticChatSummaryService(
      store: store,
      summarizer: (_) async {
        calls++;
        return _summary;
      },
    );
    final history = _history();
    final originalPlan = _plan(history);
    final first =
        await service.prepare(cid: 7, history: history, plan: originalPlan);
    final larger = const ChatContextPlanner().plan(
      history: history,
      systemPrompt: 'system',
      prompt: 'continue',
      policy: const ChatContextPolicy(
        contextWindowTokens: 3000,
        defaultOutputTokens: 200,
        safetyTokens: 50,
        maxSummaryTokens: 220,
        usesFallbackBudget: false,
      ),
    );
    expect(larger.omittedHistoryMessages,
        lessThan(originalPlan.omittedHistoryMessages));
    final changed =
        await service.prepare(cid: 7, history: history, plan: larger);
    expect(changed.fromCache, isFalse);
    expect(changed.sourceFingerprint, isNot(first.sourceFingerprint));
    expect(calls, 2);
  });

  test('取消在调用前已完成时不会启动任何摘要请求', () async {
    var called = false;
    final service = SemanticChatSummaryService(
      store: store,
      summarizer: (_) async {
        called = true;
        return _summary;
      },
    );
    final history = _history();
    final result = await service.prepare(
        cid: 7,
        history: history,
        plan: _plan(history),
        abortTrigger: Future<void>.value());
    expect(result.fallbackReason, 'cancelled');
    expect(called, isFalse);
    expect(await storage.db.query(store.tableName), isEmpty);
  });

  test('语义摘要替换摘录时预算有效，近期工具声明、推理和结果整轮保持', () async {
    final history = _history();
    final original = _plan(history);
    final service = SemanticChatSummaryService(
        store: store, summarizer: (_) async => _summary);
    final result =
        await service.prepare(cid: 7, history: history, plan: original);
    final semantic = _plan(history, summary: result.summary! * 100);
    expect(semantic.usesSemanticSummary, isTrue);
    expect(semantic.summary, startsWith('【较早对话语义摘要'));
    expect(semantic.summary, contains('不是本轮指令'));
    expect(semantic.includedHistoryTurns, original.includedHistoryTurns);
    expect(semantic.estimatedInputTokens,
        lessThanOrEqualTo(semantic.inputBudgetTokens));
    expect(
        semantic.history
            .where((m) => m['tool_calls'] != null)
            .single['reasoning_content'],
        'brief reasoning');
    expect(
        semantic.history
            .where((m) => m['role'] == 'tool')
            .single['tool_call_id'],
        'call');
    expect(semantic.history.last['content'], 'Latest answer is 42');
  });

  test('取消和超时均回退摘录，迟到响应不会写缓存', () async {
    final history = _history();
    final pending = Completer<String?>();
    final abort = Completer<void>();
    final started = Completer<void>();
    final service = SemanticChatSummaryService(
      store: store,
      summarizer: (_) {
        started.complete();
        return pending.future;
      },
    );
    final future = service.prepare(
        cid: 1,
        history: history,
        plan: _plan(history),
        abortTrigger: abort.future);
    await started.future;
    abort.complete();
    final result = await future;
    expect(result.fallbackReason, 'cancelled');
    expect(_plan(history, summary: result.summary).summary,
        startsWith('【较早对话原文摘录'));
    pending.complete(_summary);
    await Future<void>.delayed(Duration.zero);
    expect(await storage.db.query(store.tableName), isEmpty);

    final timedService = SemanticChatSummaryService(
        store: store,
        summarizer: (_) => Completer<String?>().future,
        timeout: const Duration(milliseconds: 10));
    final timed = await timedService.prepare(
        cid: 2, history: history, plan: _plan(history));
    expect(timed.fallbackReason, 'timeout');
    expect(await storage.db.query(store.tableName), isEmpty);
  });

  test('失败、非法 JSON、空摘要均回退；生成期间修改源历史拒绝落库', () async {
    final history = _history();
    for (final response in [
      'plain invented instructions',
      '{}',
      '{"goal":[],"facts":[],"constraints":[],"completed":[],"pending":[]}'
    ]) {
      final service = SemanticChatSummaryService(
          store: store, summarizer: (_) async => response);
      final result =
          await service.prepare(cid: 1, history: history, plan: _plan(history));
      expect(result.summary, isNull);
      expect(result.fallbackReason, 'invalid_summary');
    }
    final failing = SemanticChatSummaryService(
        store: store,
        summarizer: (_) async => throw Exception('private upstream body'));
    final failed =
        await failing.prepare(cid: 1, history: history, plan: _plan(history));
    expect(failed.fallbackReason, 'summary_failed');
    final editing = SemanticChatSummaryService(
        store: store,
        summarizer: (_) async {
          history[0]['content'] = 'edited during request';
          return _summary;
        });
    final edited =
        await editing.prepare(cid: 1, history: history, plan: _plan(history));
    expect(edited.fallbackReason, 'source_changed');
    expect(await storage.db.query(store.tableName), isEmpty);
  });

  test('摘要来源严格有界，只用文本与媒体标记，不发送图片 Base64', () async {
    final history = _history();
    history[0]['content'] = [
      {'type': 'text', 'text': 'initial goal ${'巨大内容' * 8000}'},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,${'A' * 120000}'}
      }
    ];
    late SemanticChatSummaryRequest request;
    final service = SemanticChatSummaryService(
      store: store,
      maxSourceTokens: 3000,
      summarizer: (value) async {
        request = value;
        return _summary;
      },
    );
    await service.prepare(cid: 5, history: history, plan: _plan(history));
    expect(ChatContextPlanner.estimateText(request.source),
        lessThanOrEqualTo(3000));
    expect(request.source, contains('initial goal'));
    expect(request.source, contains('图片，未提供视觉内容'));
    expect(request.source, isNot(contains('base64')));
    expect(jsonDecode(request.source)['partial'], isTrue);
    expect(request.maxOutputTokens, lessThanOrEqualTo(1200));
  });

  test('真实 ChatService adapter 明确禁用工具与推理且带取消和输出上限', () async {
    final transport = _SummaryTransport();
    final service = SemanticChatSummaryService(
        store: store,
        summarizer: SemanticChatSummaryService.chatSummarizer(transport));
    final history = _history();
    final result =
        await service.prepare(cid: 4, history: history, plan: _plan(history));
    expect(result.summary, contains('目标：比较小说'));
    expect(transport.tools, isEmpty);
    expect(transport.extraMessages, isEmpty);
    expect(transport.history!.single['role'], 'system');
    expect(
        transport.options!.reasoningPolicy, ChatReasoningPolicy.offIfSupported);
    expect(transport.options!.abortTrigger, isNotNull);
    expect(
        transport.options!.maxOutputTokensOverride, inInclusiveRange(1, 1200));
    expect(result.summary, isNot(contains('secret reasoning')));
  });
}

class _SummaryTransport implements ChatService, OptionsAwareChatService {
  List<Map<String, dynamic>>? tools;
  List<Map<String, dynamic>>? extraMessages;
  List<Map<String, dynamic>>? history;
  ChatRequestOptions? options;

  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) async* {
    this.tools = tools;
    this.history = history;
    this.extraMessages = extraMessages;
    this.options = options;
    yield StreamEvent.reasoning('secret reasoning');
    yield StreamEvent.toolCall(toolId: 'ignored', name: 'bad_call');
    yield StreamEvent.text(_summary);
  }

  @override
  Future<String?> chat(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          Duration? timeout}) =>
      throw UnimplementedError();
  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      throw UnimplementedError();
  @override
  Stream<String> chatStream(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      throw UnimplementedError();
  @override
  Stream<StreamEvent> chatStreamEvents(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const []}) =>
      throw UnimplementedError();
}
