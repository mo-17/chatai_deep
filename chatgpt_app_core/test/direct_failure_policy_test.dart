import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/semantic_chat_summary_service.dart';
import 'package:chatgpt_app_core/db/semantic_chat_summary_dao.dart';
import 'package:chatgpt_app_core/model/semantic_chat_summary.dart';
import 'package:chatgpt_app_core/chat/application/search_orchestrator.dart';
import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

AISettings settings() => AISettings.defaults()
  ..activeProviderId = 'A'
  ..providers = [
    AiProvider(
        id: 'A',
        type: 'openai',
        name: 'A',
        apiKey: 'synthetic-A',
        models: [AiModel(id: 'M'), AiModel(id: 'N')],
        selectedModelId: 'M'),
    AiProvider(
        id: 'B',
        type: 'openai',
        name: 'B',
        apiKey: 'synthetic-B',
        models: [AiModel(id: 'M')],
        selectedModelId: 'M'),
  ];

class _SyntheticSearch extends WebSearchProvider {
  int calls = 0;
  _SyntheticSearch() : super(apiKey: 'synthetic');
  @override
  Future<List<WebSearchResult>> search(String query) async {
    calls++;
    return [];
  }
}

class _EmptySummaryStore implements SemanticChatSummaryStore {
  @override
  Future<SemanticChatSummary?> get(int cid, String hash) async => null;
  @override
  Future<void> save(SemanticChatSummary value) async {}
  @override
  Future<void> deleteForConversation(int cid) async {}
}

void main() {
  test('missing explicit provider remains invalid instead of taking B', () {
    final s = settings()..activeProviderId = 'deleted';
    expect(s.activeProvider.id, isNot('A'));
    expect(s.activeProvider.id, isNot('B'));
    expect(s.activeLocal.apiKey, isEmpty);
    expect(s.activeProviderId, 'deleted');
  });
  test('missing explicit selected model remains original, never N', () {
    final s = settings();
    s.activeProvider.models.removeWhere((m) => m.id == 'M');
    expect(s.effectiveModel, 'M');
    expect(s.activeProvider.selectedModelId, 'M');
  });
  test('invalid explicit assistant provider cannot dissolve into global', () {
    final s = settings();
    final result =
        AssistantModel(name: 'role', providerId: 'deleted', model: 'M')
            .applyTo(s);
    expect(result.activeProviderId, 'deleted');
    expect(result.activeLocal.apiKey, isEmpty);
    expect(s.activeProviderId, 'A');
  });
  test('truly absent assistant override still inherits original', () {
    expect(
        AssistantModel(name: 'role').applyTo(settings()).activeProviderId, 'A');
  });

  for (final stream in [false, true]) {
    test('direct ${stream ? 'stream' : 'nonstream'} accepted 503 is one POST',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var posts = 0;
      server.listen((r) async {
        await r.drain<void>();
        posts++;
        r.response.statusCode = 503;
        r.response.write('{"error":{"message":"synthetic raw secret"}}');
        await r.response.close();
      });
      final service = DirectChatService(ProviderConfig(
          apiKey: 'synthetic',
          baseUrl: 'http://127.0.0.1:${server.port}/chat',
          model: 'M'));
      const options = ChatRequestOptions(
          maxAutoRetries: 2,
          retryBaseDelay: Duration(milliseconds: 1),
          maxRetryDelay: Duration(milliseconds: 2));
      await expectLater(
          stream
              ? service
                  .chatStreamEventsWithOptions(
                      prompt: 'x', history: const [], options: options)
                  .toList()
              : service.chatWithUsageWithOptions(
                  prompt: 'x', history: const [], options: options),
          throwsA(isA<ChatTransportException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(posts, 1);
    });
  }
  test('direct accepted without response timeout has no automatic replay',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var posts = 0;
    server.listen((r) async {
      await r.drain<void>();
      posts++;
    });
    final service = DirectChatService(ProviderConfig(
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/chat',
        model: 'M'));
    await expectLater(
        service
            .chatStreamEventsWithOptions(
                prompt: 'x',
                history: const [],
                options: const ChatRequestOptions(
                    connectTimeout: Duration(milliseconds: 35),
                    retryBaseDelay: Duration(milliseconds: 1),
                    maxRetryDelay: Duration(milliseconds: 2)))
            .toList(),
        throwsA(isA<ChatTransportException>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(posts, 1);
  });
  test('direct translation timeout pauses, no whole-card fallback second POST',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var posts = 0;
    server.listen((r) async {
      await r.drain<void>();
      posts++;
    });
    final service = DirectChatService(ProviderConfig(
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/chat',
        model: 'M'));
    final executor = TranslationStreamExecutor(
        service: service,
        profile: TranslationRequestProfile(
            mode: TranslationExecutionMode.local,
            providerId: 'A',
            modelId: 'M',
            reasoningPolicy: ChatReasoningPolicy.providerDefault,
            reasoningControlSuppressed: false),
        firstEventTimeout: const Duration(milliseconds: 30));
    var calls = 0;
    Object? failure;
    try {
      await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
          AssistantModel(name: 'English role', prompt: 'English text'),
          complete: (prompt) {
        if (++calls > 1) throw const RoleCardTranslationCancelled();
        return executor.complete(prompt,
            cancellation: TranslationCancellationController());
      });
    } catch (e) {
      failure = e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(failure, isA<TranslationWorkPaused>());
    expect(calls, 1);
    expect(posts, 1);
  });
  for (final failure in ['http', 'protocol']) {
    test('direct search $failure does not fall through to another model POST',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var posts = 0;
      server.listen((r) async {
        await r.drain<void>();
        posts++;
        if (failure == 'http') {
          r.response.statusCode = 503;
          r.response.write('{}');
        } else {
          r.response
              .write('{"choices":[{"message":{"content":"not intent JSON"}}]}');
        }
        await r.response.close();
      });
      final service = DirectChatService(ProviderConfig(
          apiKey: 'synthetic',
          baseUrl: 'http://127.0.0.1:${server.port}/chat',
          model: 'M'));
      final fake = _SyntheticSearch();
      final dao = CompletionDao(
          settings: settings(),
          chatService: service,
          webSearchRunner: (prompt, history) =>
              SearchOrchestrator(chatService: service, provider: fake)
                  .run(prompt: prompt, history: history));
      await expectLater(
          dao.createCompletionsWithSearch(prompt: 'x', webSearch: true),
          throwsA(isA<ChatTransportException>()));
      expect(posts, 1);
      expect(fake.calls, 0);
    });
  }

  test(
      'direct semantic summary failure cannot fall through to main model request',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var posts = 0;
    server.listen((r) async {
      await r.drain<void>();
      posts++;
      r.response.statusCode = 503;
      r.response.write('{}');
      await r.response.close();
    });
    final direct = DirectChatService(ProviderConfig(
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/chat',
        model: 'M'));
    final history = [
      for (var i = 0; i < 8; i++) ...[
        {'role': 'user', 'content': 'Q $i ${'old fact ' * 80}'},
        {'role': 'assistant', 'content': 'A $i ${'known fact ' * 80}'}
      ]
    ];
    final plan = const ChatContextPlanner().plan(
        history: history,
        systemPrompt: 'system',
        prompt: 'continue',
        policy: const ChatContextPolicy(
            contextWindowTokens: 1600,
            defaultOutputTokens: 200,
            safetyTokens: 50,
            maxSummaryTokens: 220,
            usesFallbackBudget: false));
    expect(plan.omittedHistoryMessages, greaterThan(0));
    final summary = SemanticChatSummaryService(
        store: _EmptySummaryStore(),
        summarizer: SemanticChatSummaryService.chatSummarizer(direct));
    await expectLater(summary.prepare(cid: 1, history: history, plan: plan),
        throwsA(isA<ChatTransportException>()));
    expect(posts, 1);
  });
}
