import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/semantic_chat_summary_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/semantic_chat_summary_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/semantic_chat_summary.dart';
import 'package:flutter_test/flutter_test.dart';

const _policy = ChatContextPolicy(
  contextWindowTokens: 2000,
  defaultOutputTokens: 200,
  safetyTokens: 100,
  maxSummaryTokens: 220,
  usesFallbackBudget: false,
);
const _summary = '{"goal":["compare novels"],"facts":["read novel A"],'
    '"constraints":["preserve originals"],"completed":["created score table"],'
    '"pending":["review novel B"]}';

List<MessageModel> _messages({bool long = true}) => [
      for (var i = 0; i < (long ? 8 : 1); i++) ...[
        MessageModel(
          ownerType: OwnerType.sender,
          content: long ? 'Question $i ${'old fact ' * 90}' : 'hello',
          createdAt: i * 2 + 1,
        ),
        MessageModel(
          ownerType: OwnerType.receiver,
          content: long ? 'Answer $i ${'detail ' * 90}' : 'world',
          createdAt: i * 2 + 2,
        ),
      ],
    ];

void main() {
  test(
      'CompletionDao first tool round uses semantic summary; expanded replay changes source and falls back once',
      () async {
    final original = _messages();
    final before = jsonEncode(CompletionDao.buildHistory(original, {}));
    final store = _SummaryStore();
    var summaryCalls = 0;
    var toolCalls = 0;
    final summaries = SemanticChatSummaryService(
      store: store,
      summarizer: (_) async {
        summaryCalls++;
        return _summary;
      },
    );
    final chat = _ScriptedChat(toolRequest: true);
    final registry = ToolRegistry([
      ChatTool(
        name: 'read_more',
        description: 'read additional novel information',
        parameters: const {'type': 'object', 'properties': {}},
        execute: (_) async {
          toolCalls++;
          return ToolOutcome(content: 'result fact ' * 110);
        },
      ),
    ]);
    final dao = CompletionDao(
      settings: AISettings.defaults()..maxOutputTokens = 200,
      chatService: chat,
      messages: original,
      conversationId: 42,
      semanticSummaryService: summaries,
      manageContext: true,
      contextPolicy: _policy,
    );
    final beforePlan = dao.previewContext(prompt: 'continue', tools: registry);
    expect(beforePlan.omittedHistoryMessages, greaterThan(0));
    final plans = <ChatContextPlan>[];
    final events = await dao
        .streamCompletionEvents(
          prompt: 'continue',
          tools: registry,
          onContextPlan: plans.add,
        )
        .toList();

    expect(summaryCalls, 1);
    expect(toolCalls, 1);
    expect(chat.requests, hasLength(2));
    final first = chat.requests.first;
    final second = chat.requests.last;
    final firstSummary = first.history.firstWhere((message) =>
        message['content'] is String &&
        (message['content'] as String).startsWith('【较早对话语义摘要'));
    expect(firstSummary['role'], 'assistant');
    expect(firstSummary['reasoning_content'], '');
    expect(firstSummary['content'], contains('compare novels'));
    expect(first.extraMessages, isEmpty);
    expect(second.extraMessages, hasLength(2));
    expect(
        second.extraMessages.first['reasoning_content'], 'need more evidence');
    expect(second.extraMessages.first['tool_calls'][0]['id'], 'read_1');
    expect(second.extraMessages.last['tool_call_id'], 'read_1');
    expect(second.extraMessages.last['content'], 'result fact ' * 110);
    expect(
        second.history.any((message) =>
            message['content'] is String &&
            (message['content'] as String).startsWith('【较早对话语义摘要')),
        isFalse);
    expect(
        second.history.any((message) =>
            message['content'] is String &&
            (message['content'] as String).startsWith('【较早对话原文摘录')),
        isTrue);
    final semanticPlan = plans.firstWhere((plan) => plan.usesSemanticSummary);
    expect(plans.last.omittedHistoryMessages,
        greaterThan(semanticPlan.omittedHistoryMessages));
    expect(plans.last.usesSemanticSummary, isFalse);
    expect(
        plans.every((plan) =>
            plan.canSend &&
            plan.estimatedInputTokens <= plan.inputBudgetTokens),
        isTrue);
    expect(
        events
            .where((event) => event.type == StreamEventType.text)
            .map((event) => event.delta)
            .join(),
        'finished');
    expect(dao.lastProtocolMessages.last['content'], 'finished');
    expect(jsonEncode(CompletionDao.buildHistory(dao.currentMessages, {})),
        before);
    expect(jsonEncode(CompletionDao.buildHistory(original, {})), before);
    expect(store.rows, hasLength(1));
  });

  test(
      'file history and saved assistant protocol use the matching semantic summary before and after reopening',
      () async {
    const cid = 45;
    const firstUserAt = 1;
    const firstAssistantAt = 2;
    const anchors = '测试代号 HARNESS-SUMMARY-A07，城市青岛，人数 3，预算 480 元，'
        '不坐飞机，只用中文。已确认城市人数，待办三天行程。';
    final firstFile = '[附件「part1.txt」内容开始]\n$anchors${'甲' * 13400}'
        '\n[附件「part1.txt」内容结束]';
    final secondFile = '[附件「part2.txt」内容开始]\n${'乙' * 14500}'
        '\n[附件「part2.txt」内容结束]';
    final original = [
      MessageModel(
        ownerType: OwnerType.sender,
        content: '请记住附件中的测试事实。',
        createdAt: firstUserAt,
      ),
      MessageModel(
        ownerType: OwnerType.receiver,
        content: '已记录第1段',
        createdAt: firstAssistantAt,
      ),
    ];
    final files = {firstUserAt: firstFile};
    final protocol = {
      firstAssistantAt: [
        {
          'role': 'assistant',
          'content': '已记录第1段',
          'reasoning_content': '',
        },
      ],
    };
    final before = jsonEncode(CompletionDao.buildHistory(original, {},
        fileHistory: files, protocolHistory: protocol));
    final store = _SummaryStore();
    var summaryCalls = 0;
    final summaries = SemanticChatSummaryService(
      store: store,
      summarizer: (request) async {
        summaryCalls++;
        expect(request.source, contains('HARNESS-SUMMARY-A07'));
        return '{"goal":["三天行程"],"facts":["HARNESS-SUMMARY-A07，青岛，'
            '3 人，480 元"],"constraints":["不坐飞机，只用中文"],'
            '"completed":["确认城市人数"],"pending":["三天行程"]}';
      },
    );
    final registry = ToolRegistry([
      ChatTool(
        name: 'read_more',
        description: 'read additional information',
        parameters: const {'type': 'object', 'properties': {}},
        execute: (_) async => const ToolOutcome(content: 'unused'),
      ),
    ]);
    final attachments = ChatAttachments(extraText: secondFile);
    const prompt = '请根据第一份附件输出测试事实。';
    for (var reopen = 0; reopen < 2; reopen++) {
      final chat = _ScriptedChat();
      final dao = CompletionDao(
        settings: AISettings.defaults()..contextInputBudgetTokens = 27648,
        chatService: chat,
        messages: original,
        fileHistory: files,
        protocolHistory: protocol,
        conversationId: cid,
        semanticSummaryService: summaries,
        manageContext: true,
      );
      final baseline = dao.previewContext(
          prompt: prompt, attachments: attachments, tools: registry);
      expect(baseline.omittedHistoryMessages, 2);
      expect(baseline.usesSemanticSummary, isFalse);
      final plans = <ChatContextPlan>[];
      await dao
          .streamCompletionEvents(
            prompt: prompt,
            attachments: attachments,
            tools: registry,
            onContextPlan: plans.add,
          )
          .toList();
      expect(summaryCalls, 1, reason: 'reopened history must reuse the cache');
      expect(store.rows[cid]!.sourceMessageCount, 2);
      expect(
          store.rows[cid]!.sourceFingerprint,
          SemanticChatSummaryService.sourceFingerprint(jsonDecode(before)
              .map<Map<String, dynamic>>(
                  (row) => Map<String, dynamic>.from(row as Map))
              .toList()));
      expect(plans, isNotEmpty);
      expect(plans.every((plan) => plan.usesSemanticSummary), isTrue);
      expect(plans.last.omittedHistoryMessages, 2);
      expect(plans.last.summary, contains('HARNESS-SUMMARY-A07'));
      expect(plans.last.summary, contains('不坐飞机'));
      expect(plans.last.estimatedInputTokens,
          lessThanOrEqualTo(plans.last.inputBudgetTokens));
      expect(chat.requests.single.history[1]['content'], plans.last.summary);
      expect(
          dao
              .previewContext(
                  prompt: prompt, attachments: attachments, tools: registry)
              .usesSemanticSummary,
          isTrue);
      expect(
          jsonEncode(CompletionDao.buildHistory(dao.currentMessages, {},
              fileHistory: dao.currentFileHistory,
              protocolHistory: dao.currentProtocolHistory)),
          before);
    }
  });

  test(
      'summary generation failure still streams answer with the original excerpt',
      () async {
    final chat = _ScriptedChat();
    var summaryCalls = 0;
    final original = _messages();
    final before = jsonEncode(CompletionDao.buildHistory(original, {}));
    final dao = CompletionDao(
      settings: AISettings.defaults()..maxOutputTokens = 200,
      chatService: chat,
      messages: original,
      conversationId: 43,
      semanticSummaryService: SemanticChatSummaryService(
        store: _SummaryStore(),
        summarizer: (_) async {
          summaryCalls++;
          throw const FormatException('summary failed');
        },
      ),
      manageContext: true,
      contextPolicy: _policy,
    );
    final events =
        await dao.streamCompletionEvents(prompt: 'continue').toList();
    expect(summaryCalls, 1);
    expect(chat.requests, hasLength(1));
    expect(
        chat.requests.single.history.any((message) =>
            message['content'] is String &&
            (message['content'] as String).startsWith('【较早对话原文摘录')),
        isTrue);
    expect(
        events
            .where((event) => event.type == StreamEventType.text)
            .map((event) => event.delta)
            .join(),
        'finished');
    expect(jsonEncode(CompletionDao.buildHistory(dao.currentMessages, {})),
        before);
  });

  test('short legacy conversation has no summary request or summary injection',
      () async {
    final chat = _ScriptedChat();
    var summaryCalls = 0;
    final original = _messages(long: false);
    final dao = CompletionDao(
      settings: AISettings.defaults()..maxOutputTokens = 200,
      chatService: chat,
      messages: original,
      conversationId: 44,
      semanticSummaryService: SemanticChatSummaryService(
        store: _SummaryStore(),
        summarizer: (_) async {
          summaryCalls++;
          return _summary;
        },
      ),
      manageContext: true,
      contextPolicy: _policy,
    );
    final events =
        await dao.streamCompletionEvents(prompt: 'continue').toList();
    expect(summaryCalls, 0);
    expect(chat.requests.single.history.skip(1).toList(),
        CompletionDao.buildHistory(original, {}));
    expect(events.last.delta, 'finished');
    expect(dao.currentMessages, original);
  });
}

class _SummaryStore implements SemanticChatSummaryStore {
  final Map<int, SemanticChatSummary> rows = {};
  @override
  Future<SemanticChatSummary?> get(int cid, String fingerprint) async {
    final row = rows[cid];
    return row?.sourceFingerprint == fingerprint ? row : null;
  }

  @override
  Future<void> save(SemanticChatSummary summary) async =>
      rows[summary.cid] = summary;
  @override
  Future<void> deleteForConversation(int cid) async => rows.remove(cid);
}

class _RecordedRequest {
  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> extraMessages;
  _RecordedRequest(List<Map<String, dynamic>> history,
      List<Map<String, dynamic>> extraMessages)
      : history = _copy(history),
        extraMessages = _copy(extraMessages);
  static List<Map<String, dynamic>> _copy(List<Map<String, dynamic>> values) =>
      (jsonDecode(jsonEncode(values)) as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
}

class _ScriptedChat implements ChatService {
  final bool toolRequest;
  final List<_RecordedRequest> requests = [];
  _ScriptedChat({this.toolRequest = false});
  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);
  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) async* {
    final round = requests.length;
    requests.add(_RecordedRequest(history, extraMessages));
    if (toolRequest && round == 0) {
      expect(tools, isNotEmpty);
      yield StreamEvent.reasoning('need more evidence');
      yield StreamEvent.toolCall(
          toolId: 'read_1', name: 'read_more', arguments: const {});
    } else {
      yield StreamEvent.text('finished');
    }
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
}
