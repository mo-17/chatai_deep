import 'dart:async';
import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/semantic_chat_summary_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/semantic_chat_summary_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/semantic_chat_summary.dart';
import 'package:flutter_test/flutter_test.dart';

const smallPolicy = ChatContextPolicy(
  contextWindowTokens: 1600,
  defaultOutputTokens: 200,
  safetyTokens: 50,
  maxSummaryTokens: 220,
  usesFallbackBudget: false,
);

MessageModel message(String text, int time,
        {bool user = true, List<String>? images}) =>
    MessageModel(
      ownerType: user ? OwnerType.sender : OwnerType.receiver,
      content: text,
      createdAt: time,
      imageUrlsOrB64: images,
    );

List<MessageModel> longMessages() => [
      for (var i = 0; i < 12; i++) ...[
        message('Question $i ${'old fact ' * 80}', i * 2 + 1),
        message('Answer $i ${'known detail ' * 80}', i * 2 + 2, user: false),
      ]
    ];

void main() {
  const planner = ChatContextPlanner();
  group('旧对话的请求规划', () {
    test('短纯文本历史原样携带，旧数据无需新字段', () {
      final history = CompletionDao.buildHistory(
          [message('你好', 1), message('你好，我能帮你什么？', 2, user: false)], {});
      final before = jsonEncode(history);
      final plan =
          planner.plan(history: history, systemPrompt: 'system', prompt: '继续');

      expect(plan.canSend, isTrue);
      expect(plan.history.skip(1), history);
      expect(plan.summary, isEmpty);
      expect(plan.includedHistoryTurns, 1);
      expect(plan.omittedHistoryMessages, 0);
      expect(plan.usesFallbackBudget, isTrue);
      expect(jsonEncode(history), before);
    });

    test('旧图片与附件文本仍进入请求，Base64 不按文本长度估算', () {
      final image = 'data:image/png;base64,${'a' * 120000}';
      final history = CompletionDao.buildHistory([
        message('看图片', 1, images: [image]),
        message('蓝色圆形', 2, user: false)
      ], {}, fileHistory: {
        1: '附件原文：销售额 120 万元'
      });
      final plan = planner.plan(
          history: history, systemPrompt: 'system', prompt: '销售额是多少');
      expect(plan.history.skip(1), history);
      expect(plan.estimatedInputTokens, lessThan(5000));
      expect(plan.turns.single.excerpt, contains('[图片]'));
      expect(plan.turns.single.excerpt, contains('销售额'));
      expect(plan.turns.single.excerpt, isNot(contains('base64')));
      expect(plan.warnings.join(), contains('实际 Token'));
    });

    test('旧工具声明和结果按完整轮一起保留或省略', () {
      final tool = ToolBlock(
        id: 'block',
        messageId: '2',
        createdAt: 2,
        status: MessageBlockStatus.success,
        toolId: 'old-call',
        toolName: 'fetch',
        arguments: const {'q': 'old'},
        content: 'tool answer ' * 100,
      );
      final history = CompletionDao.buildHistory([
        message('old question ' * 150, 1),
        message('old answer ' * 150, 2, user: false),
        message('new question', 3),
        message('new answer', 4, user: false),
      ], {
        2: [tool]
      });
      final before = jsonEncode(history);
      final plan = planner.plan(
          history: history,
          systemPrompt: 'system',
          prompt: 'next',
          policy: smallPolicy);
      expect(plan.shortened, isTrue);
      final calls = plan.history.where((m) => m['tool_calls'] != null).toList();
      final results = plan.history.where((m) => m['role'] == 'tool').toList();
      expect(calls.length, results.length);
      expect(calls, isEmpty);
      expect(plan.history.last['content'], 'new answer');
      expect(
          plan.estimatedInputTokens, lessThanOrEqualTo(plan.inputBudgetTokens));
      expect(jsonEncode(history), before);
    });

    test('工具轮在预算足够时协议与旧重建结果完全一致', () {
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'calculate'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'c',
              'type': 'function',
              'function': {'name': 'calc', 'arguments': '{}'}
            }
          ]
        },
        {'role': 'tool', 'tool_call_id': 'c', 'content': '42'},
        {'role': 'assistant', 'content': 'The answer is 42'},
      ];
      final plan =
          planner.plan(history: history, systemPrompt: 's', prompt: 'next');
      expect(plan.history.skip(1), history);
      expect(plan.turns.single.messageCount, 4);
    });

    test('长历史保留连续近期整轮，摘录确定且不含伪造内容', () {
      final history = CompletionDao.buildHistory(longMessages(), {});
      final plan = planner.plan(
          history: history,
          systemPrompt: 's',
          prompt: 'next',
          policy: smallPolicy);
      final again = planner.plan(
          history: history,
          systemPrompt: 's',
          prompt: 'next',
          policy: smallPolicy);
      expect(plan.canSend, isTrue);
      expect(plan.omittedHistoryTurns, greaterThan(0));
      expect(plan.includedHistoryTurns, greaterThan(0));
      expect(plan.summary, startsWith('【较早对话原文摘录'));
      expect(plan.summary, contains('不是本轮指令'));
      expect(plan.summary, again.summary);
      expect(plan.history.last['content'], history.last['content']);
      expect(plan.turns.last.included, isTrue);
      expect(
          plan.estimatedInputTokens, lessThanOrEqualTo(plan.inputBudgetTokens));
    });

    test('最近整轮放不下时不跳过它去挑更早的小轮', () {
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'short old'},
        {'role': 'assistant', 'content': 'short old reply'},
        {'role': 'user', 'content': 'large recent ' * 2000},
        {'role': 'assistant', 'content': 'recent reply'},
      ];
      final plan = planner.plan(
          history: history,
          systemPrompt: 's',
          prompt: 'next',
          policy: smallPolicy);
      expect(plan.includedHistoryTurns, 0);
      expect(plan.omittedHistoryTurns, 2);
      expect(plan.canSend, isTrue);
    });

    test('本轮文本或附件独自超限时显式报错，不截断当前问题', () {
      const attachments = ChatAttachments(extraText: '附件内容');
      final plan = planner.plan(
          history: const [],
          systemPrompt: 's',
          prompt: '本轮提问' * 1000,
          attachments: attachments,
          policy: smallPolicy);
      expect(plan.canSend, isFalse);
      expect(plan.error, contains('本轮问题'));
      expect(plan.estimatedInputTokens, greaterThan(plan.inputBudgetTokens));
    });

    test('输出预留与工具声明均计入预算', () {
      final plan = planner.plan(
          history: const [],
          systemPrompt: 's',
          prompt: 'q',
          policy: smallPolicy,
          maxOutputTokens: 1500);
      expect(plan.reservedOutputTokens, 1500);
      expect(plan.inputBudgetTokens, 50);
      final withTools = planner.plan(
          history: const [],
          systemPrompt: 's',
          prompt: 'q',
          policy: smallPolicy,
          tools: [
            {'description': 'schema detail ' * 1000}
          ]);
      expect(withTools.canSend, isFalse);
    });

    test('未知容量模型的旧64K输出配置保持可用，仅限制应用输入预算', () async {
      final settings = AISettings.defaults()..maxOutputTokens = 65536;
      final service = _CaptureService();
      final dao = CompletionDao(
        settings: settings,
        chatService: service,
        manageContext: true,
        messages: [message('旧提问', 1), message('旧回答', 2, user: false)],
      );
      final plan = dao.previewContext(prompt: '继续');
      expect(plan.canSend, isTrue);
      expect(plan.inputBudgetTokens, 262144);
      expect(plan.reservedOutputTokens, 65536);
      expect(plan.contextWindowTokens,
          plan.inputBudgetTokens + plan.reservedOutputTokens + 1024);
      expect(plan.warnings.join(), contains('输出预留另计'));
      await dao.createCompletionsWithSearch(prompt: '继续');
      expect(service.histories.last, plan.history);
    });

    test('提高默认预算后完整携带超过旧预算的历史，不改原始记录', () async {
      final original = [
        message('旧文件内容 ${'甲' * 45000}', 1),
        message('已记录旧文件', 2, user: false),
      ];
      final before = jsonEncode(CompletionDao.buildHistory(original, {}));
      final service = _CaptureService();
      final dao = CompletionDao(
        settings: AISettings.defaults(),
        chatService: service,
        messages: original,
        manageContext: true,
      );
      final plan = dao.previewContext(prompt: '继续分析旧文件');
      expect(plan.canSend, isTrue);
      expect(plan.estimatedInputTokens, greaterThan(27648));
      expect(plan.estimatedInputTokens, lessThan(262144));
      expect(plan.omittedHistoryMessages, 0);
      expect(plan.summary, isEmpty);
      await dao.createCompletionsWithSearch(prompt: '继续分析旧文件');
      expect(service.histories.last, plan.history);
      expect(jsonEncode(CompletionDao.buildHistory(dao.currentMessages, {})),
          before);
    });

    test('显式应用输入预算独立于输出预留，默认和已知容量策略保持原行为', () {
      for (final output in [1024, 65536]) {
        final configured = planner.plan(
          history: const [],
          systemPrompt: 'system',
          prompt: 'next',
          policy: const ChatContextPolicy(inputBudgetTokens: 8192),
          maxOutputTokens: output,
        );
        expect(configured.inputBudgetTokens, 8192);
        expect(configured.reservedOutputTokens, output);
        expect(configured.contextWindowTokens, 8192 + output + 1024);
        expect(configured.canSend, isTrue);
      }
      final unchanged = planner
          .plan(history: const [], systemPrompt: 'system', prompt: 'next');
      expect(unchanged.inputBudgetTokens, 27648);
      final knownWindow = planner.plan(
          history: const [],
          systemPrompt: 'system',
          prompt: 'next',
          policy: smallPolicy,
          maxOutputTokens: 300);
      expect(knownWindow.inputBudgetTokens, 1600 - 300 - 50);
    });

    test('空字段、assistant 开头的旧记录与旧 file_id 不崩溃', () {
      final plan = planner.plan(history: const [
        {'role': 'assistant', 'content': ''},
        {
          'role': 'user',
          'content': [
            {'type': 'file', 'file_id': 'file-legacy'},
            {'type': 'text'},
          ]
        },
      ], systemPrompt: 's', prompt: 'continue');
      expect(plan.canSend, isTrue);
      expect(plan.includedHistoryTurns, 2);
      expect(plan.estimatedInputTokens, greaterThan(4096));
    });
  });

  group('CompletionDao 全请求入口一致性', () {
    test('设置输入预算控制预览与所有正式入口，输出长度不偷改阈值', () async {
      final settings = AISettings.defaults()
        ..contextInputBudgetTokens = 1024
        ..maxOutputTokens = 65536;
      final service = _CaptureService();
      final messages = longMessages();
      final dao = CompletionDao(
          settings: settings,
          chatService: service,
          messages: messages,
          manageContext: true);
      final plan = dao.previewContext(prompt: 'next');
      expect(plan.inputBudgetTokens, 1024);
      expect(plan.reservedOutputTokens, 65536);
      expect(plan.omittedHistoryTurns, greaterThan(0));
      expect(plan.estimatedInputTokens, lessThanOrEqualTo(1024));
      final observed = <ChatContextPlan>[];
      await dao.createCompletions(prompt: 'next');
      await dao.createCompletionsWithSearch(
          prompt: 'next', onContextPlan: observed.add);
      await dao.streamCompletions(prompt: 'next').toList();
      await dao
          .streamCompletionEvents(prompt: 'next', onContextPlan: observed.add)
          .toList();
      expect(service.histories, hasLength(4));
      for (final request in service.histories) {
        expect(request, plan.history);
      }
      expect(
          observed.every((value) => value.inputBudgetTokens == 1024), isTrue);
      expect(dao.currentMessages, messages);
    });

    test('增大设置预算可保留原来被裁剪的旧轮次，显式 policy 仍优先', () async {
      final settings = AISettings.defaults()..contextInputBudgetTokens = 65536;
      final messages = longMessages();
      final service = _CaptureService();
      final dao = CompletionDao(
          settings: settings,
          chatService: service,
          messages: messages,
          manageContext: true);
      final plan = dao.previewContext(prompt: 'next');
      expect(plan.inputBudgetTokens, 65536);
      expect(plan.omittedHistoryMessages, 0);
      expect(plan.history.skip(1), CompletionDao.buildHistory(messages, {}));
      await dao.createCompletionsWithSearch(prompt: 'next');
      expect(service.histories.single, plan.history);
      final explicit = CompletionDao(
          settings: settings,
          chatService: service,
          messages: messages,
          manageContext: true,
          contextPolicy: smallPolicy);
      final explicitPlan = explicit.previewContext(prompt: 'next');
      expect(explicitPlan.inputBudgetTokens, 1600 - 200 - 50);
      expect(explicitPlan.shortened, isTrue);
      await explicit.createCompletions(prompt: 'next');
      expect(service.histories.last, explicitPlan.history);
    });

    test('设置预算同样限制工具回灌，增加预算后完整工具对可继续请求', () async {
      final registry = ToolRegistry([
        ChatTool(
            name: 'large_tool',
            description: 'returns data',
            parameters: const {},
            execute: (_) async => ToolOutcome(content: '验收数据' * 400)),
      ]);
      for (final budget in [1024, 4096]) {
        final service = _CaptureService(toolOnFirst: true);
        final dao = CompletionDao(
            settings: AISettings.defaults()..contextInputBudgetTokens = budget,
            chatService: service,
            manageContext: true);
        final plans = <ChatContextPlan>[];
        final request = dao
            .streamCompletionEvents(
                prompt: 'next', tools: registry, onContextPlan: plans.add)
            .toList();
        if (budget == 1024) {
          await expectLater(
              request, throwsA(isA<ChatContextBudgetException>()));
          expect(service.histories, hasLength(1));
          expect(plans.last.canSend, isFalse);
        } else {
          final events = await request;
          expect(events.last.delta, 'answer');
          expect(service.histories, hasLength(2));
          expect(service.extraMessageLists.last.map((m) => m['role']),
              ['assistant', 'tool']);
          expect(service.extraMessageLists.last.last['content'], '验收数据' * 400);
          expect(plans.every((plan) => plan.canSend), isTrue);
        }
        expect(plans.every((plan) => plan.inputBudgetTokens == budget), isTrue);
      }
    });

    test('关闭上下文管理时不按新设置裁剪或调用语义摘要', () async {
      var summaryCalls = 0;
      final summaryService = SemanticChatSummaryService(
        store: _MemorySummaryStore(),
        summarizer: (_) async {
          summaryCalls++;
          return '{"facts":["test"]}';
        },
      );
      final service = _CaptureService();
      final messages = longMessages();
      final dao = CompletionDao(
          settings: AISettings.defaults()..contextInputBudgetTokens = 1024,
          chatService: service,
          messages: messages,
          conversationId: 10,
          semanticSummaryService: summaryService);
      await dao.createCompletions(prompt: '提问' * 1000);
      await dao.streamCompletionEvents(prompt: 'next').toList();
      expect(summaryCalls, 0);
      for (final request in service.histories) {
        expect(request.skip(1), CompletionDao.buildHistory(messages, {}));
      }
    });

    test('设置预算决定语义摘要源区间，重建旧对话后按新预算失效重算', () async {
      var summaryCalls = 0;
      final store = _MemorySummaryStore();
      final summaryService = SemanticChatSummaryService(
        store: store,
        summarizer: (_) async {
          summaryCalls++;
          return '{"goal":["验收旧对话"],"facts":["原始记录保留"],'
              '"constraints":[],"completed":[],"pending":["继续"]}';
        },
      );
      final messages = longMessages();
      final service = _CaptureService();
      final observed = <ChatContextPlan>[];
      for (final budget in [2560, 4500]) {
        final dao = CompletionDao(
            settings: AISettings.defaults()..contextInputBudgetTokens = budget,
            chatService: service,
            messages: messages,
            conversationId: 10,
            semanticSummaryService: summaryService,
            manageContext: true);
        final baseline = dao.previewContext(prompt: 'next');
        await dao
            .streamCompletionEvents(prompt: 'next', onContextPlan: observed.add)
            .toList();
        final plan = observed.last;
        expect(plan.inputBudgetTokens, budget);
        expect(plan.usesSemanticSummary, isTrue);
        expect(plan.estimatedInputTokens, lessThanOrEqualTo(budget));
        expect(
            store.latest!.sourceMessageCount, baseline.omittedHistoryMessages);
        expect(service.histories.last, plan.history);
        expect(dao.currentMessages, messages);
      }
      expect(summaryCalls, 2);
      expect(observed.last.omittedHistoryMessages,
          lessThan(observed.first.omittedHistoryMessages));
    });

    test('默认调用方保留完整旧历史，开启管理后请求与预览一致', () async {
      final messages = longMessages();
      final service = _CaptureService();
      final legacy = CompletionDao(
          settings: AISettings.defaults(),
          chatService: service,
          messages: messages,
          contextPolicy: smallPolicy);
      await legacy.createCompletions(prompt: 'next');
      expect(service.histories.last.length, messages.length + 1);
      final managed = CompletionDao(
          settings: AISettings.defaults(),
          chatService: service,
          messages: messages,
          contextPolicy: smallPolicy,
          manageContext: true);
      final plan = managed.previewContext(prompt: 'next');
      await managed.createCompletions(prompt: 'next');
      expect(service.histories.last, plan.history);
      expect(managed.currentMessages, messages);
    });

    test('流式和非流式使用同一规划，重新打开旧会话仍可重建', () async {
      final service = _CaptureService();
      final messages = longMessages();
      final dao = CompletionDao(
          settings: AISettings.defaults(),
          chatService: service,
          messages: messages,
          manageContext: true,
          contextPolicy: smallPolicy);
      final expected = dao.previewContext(prompt: 'next').history;
      await dao.streamCompletionEvents(prompt: 'next').toList();
      expect(service.histories.last, expected);
      await dao.createCompletionsWithSearch(prompt: 'next');
      expect(service.histories.last, expected);
      final reopened = CompletionDao(
          settings: AISettings.defaults(),
          chatService: service,
          messages: dao.currentMessages,
          toolHistory: dao.currentToolHistory,
          fileHistory: dao.currentFileHistory,
          manageContext: true,
          contextPolicy: smallPolicy);
      expect(reopened.previewContext(prompt: 'next').history, expected);
    });

    test('超大的本轮在所有正式入口前阻止网络调用', () async {
      final service = _CaptureService();
      final dao = CompletionDao(
          settings: AISettings.defaults(),
          chatService: service,
          manageContext: true,
          contextPolicy: smallPolicy);
      final prompt = '本轮很长' * 2000;
      await expectLater(dao.createCompletions(prompt: prompt),
          throwsA(isA<ChatContextBudgetException>()));
      await expectLater(dao.createCompletionsWithSearch(prompt: prompt),
          throwsA(isA<ChatContextBudgetException>()));
      await expectLater(dao.streamCompletionEvents(prompt: prompt).toList(),
          throwsA(isA<ChatContextBudgetException>()));
      expect(service.histories, isEmpty);
    });

    test('工具续轮回灌超限时不发出不完整工具对或第二次请求', () async {
      final service = _CaptureService(toolOnFirst: true);
      final registry = ToolRegistry([
        ChatTool(
            name: 'large_tool',
            description: 'returns data',
            parameters: const {},
            execute: (_) async => ToolOutcome(content: 'large output ' * 3000)),
      ]);
      final dao = CompletionDao(
          settings: AISettings.defaults(),
          chatService: service,
          manageContext: true,
          contextPolicy: smallPolicy);
      await expectLater(
          dao.streamCompletionEvents(prompt: 'next', tools: registry).toList(),
          throwsA(isA<ChatContextBudgetException>()));
      expect(service.histories, hasLength(1));
      expect(dao.currentMessages, isEmpty);
    });

    test('非流式进度可回落旧 ChatService，取消后抑制迟到回答', () async {
      final service = _CaptureService();
      service.pendingReply = Completer<String?>();
      final abort = Completer<void>();
      final progress = <ChatSendProgress>[];
      final request =
          CompletionDao(settings: AISettings.defaults(), chatService: service)
              .createCompletionsWithSearch(
                  prompt: 'q',
                  abortTrigger: abort.future,
                  onProgress: progress.add);
      await Future<void>.delayed(Duration.zero);
      expect(progress.last.label, '等待回答');
      abort.complete();
      await expectLater(request, throwsA(isA<ChatTransportException>()));
      service.pendingReply!.complete('late answer');
    });

    test('已完成取消信号阻止首次非流式和流式调用', () async {
      final service = _CaptureService();
      final abort = Completer<void>()..complete();
      final dao =
          CompletionDao(settings: AISettings.defaults(), chatService: service);
      await expectLater(
          dao.createCompletionsWithSearch(
              prompt: 'q', abortTrigger: abort.future),
          throwsA(isA<ChatTransportException>()));
      await expectLater(
          dao
              .streamCompletionEvents(prompt: 'q', abortTrigger: abort.future)
              .toList(),
          throwsA(isA<ChatTransportException>()));
      expect(service.histories, isEmpty);
    });
  });
}

class _CaptureService extends Fake implements ChatService {
  final bool toolOnFirst;
  final histories = <List<Map<String, dynamic>>>[];
  final extraMessageLists = <List<Map<String, dynamic>>>[];
  Completer<String?>? pendingReply;
  _CaptureService({this.toolOnFirst = false});

  @override
  ModelCapabilities get capabilities => const ModelCapabilities.none();

  @override
  Future<String?> chat(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      Duration? timeout}) async {
    histories.add(List.of(history));
    if (pendingReply != null) return await pendingReply!.future;
    return 'answer';
  }

  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) async =>
      ChatCompletionResult(
          content: await chat(
              prompt: prompt, history: history, attachments: attachments));

  @override
  Stream<String> chatStream(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments}) async* {
    histories.add(List.of(history));
    yield 'answer';
  }

  @override
  Stream<StreamEvent> chatStreamEvents(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const []}) async* {
    histories.add(List.of(history));
    extraMessageLists.add(List.of(extraMessages));
    if (toolOnFirst && histories.length == 1) {
      yield StreamEvent.toolCall(
          toolId: 'call', name: 'large_tool', arguments: const {});
    } else {
      yield StreamEvent.text('answer');
    }
  }
}

class _MemorySummaryStore implements SemanticChatSummaryStore {
  SemanticChatSummary? latest;

  @override
  Future<SemanticChatSummary?> get(int cid, String sourceFingerprint) async =>
      latest?.cid == cid && latest?.sourceFingerprint == sourceFingerprint
          ? latest
          : null;

  @override
  Future<void> save(SemanticChatSummary summary) async => latest = summary;

  @override
  Future<void> deleteForConversation(int cid) async {
    if (latest?.cid == cid) latest = null;
  }
}
