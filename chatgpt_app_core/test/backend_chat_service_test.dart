import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> bodies;
  late String previousHost;
  late bool previousUseHttps;
  late _RecordingTokenStorage storage;
  late int logoutNavigations;

  setUp(() async {
    LoginDao.resetHooksForTest();
    storage = _RecordingTokenStorage.seeded();
    logoutNavigations = 0;
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: storage,
      onLogoutNavigate: () => logoutNavigations++,
    ));
    previousHost = BackendConfig.host;
    previousUseHttps = BackendConfig.useHttps;
    bodies = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    BackendConfig.host = '${server.address.host}:${server.port}';
    BackendConfig.useHttps = false;
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      bodies.add(body);
      final messages = body['messages'] as List<dynamic>;
      final prompt = (messages.last as Map<String, dynamic>)['content'];
      if (prompt == 'provider-401' || prompt == 'backend-auth-401') {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(prompt == 'provider-401'
            ? {
                'code': 'upstream_error',
                'safeCode': 'authentication_error',
                'statusCode': 401,
                'message':
                    'Authorization Bearer secret from http://private.example',
              }
            : {
                'statusCode': 401,
                'message': 'backend JWT expired',
              }));
        await request.response.close();
        return;
      }
      if (request.uri.path.endsWith('/stream')) {
        const safeFailureCodes = {
          'reasoning-control-code': ('unsupported_reasoning_control', 400),
          'raw-unknown-code': ('unknown_parameter', 400),
          'first-event-deadline-code': ('first_event_timeout', 504),
          'idle-deadline-code': ('idle_timeout', 504),
          'total-deadline-code': ('total_timeout', 504),
        };
        final safeFailure = safeFailureCodes[prompt];
        if (safeFailure != null) {
          final (safeCode, statusCode) = safeFailure;
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          request.response.write(
            'event: error\n'
            'data: {"code":"upstream_error","safeCode":"$safeCode",'
            '"statusCode":$statusCode,"message":"SECRET failure detail"}\n\n',
          );
          await request.response.close();
          return;
        }
        const retryHeaderValues = {
          'retry-header-zero': '0',
          'retry-header-over': '121',
          'retry-header-large': '9223372036854775807',
          'retry-header-overflow': '9999999999999999999999999999999999999999',
          'retry-header-signed': '+1',
          'retry-header-date': 'Wed, 21 Oct 2015 07:28:00 GMT',
          'retry-header-sensitive': 'Bearer header-secret',
        };
        final retryHeader = retryHeaderValues[prompt];
        if (retryHeader != null) {
          request.response.statusCode = HttpStatus.tooManyRequests;
          request.response.headers.set('Retry-After', retryHeader);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'code': 'upstream_error',
            'safeCode': 'rate_limited',
            'statusCode': 429,
          }));
          await request.response.close();
          return;
        }
        const retryPayloadValues = {
          'retry-payload-zero': '0',
          'retry-payload-over': '121',
          'retry-payload-large': '9223372036854775807',
          'retry-payload-overflow': '9999999999999999999999999999999999999999',
          'retry-payload-negative': '-1',
          'retry-payload-spaced': '" 1"',
          'retry-payload-date': '"Wed, 21 Oct 2015 07:28:00 GMT"',
          'retry-payload-sensitive': '"Bearer payload-secret"',
        };
        final retryPayload = retryPayloadValues[prompt];
        if (retryPayload != null) {
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          request.response.write(
            'event: error\n'
            'data: {"code":"upstream_error","safeCode":"rate_limited",'
            '"statusCode":429,"retryAfterSeconds":$retryPayload,'
            '"message":"Authorization Bearer secret"}\n\n',
          );
          await request.response.close();
          return;
        }
        if (prompt == 'http-error') {
          request.response.statusCode = HttpStatus.tooManyRequests;
          request.response.headers.set('Retry-After', '17');
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'code': 'upstream_error',
            'safeCode': 'rate_limited',
            'statusCode': 429,
            'retryAfterSeconds': 12,
            'message':
                'Authorization Bearer secret from http://private.example',
          }));
          await request.response.close();
          return;
        }
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        if (prompt == 'sse-error') {
          request.response.write(
            'event: error\n'
            'data: {"code":"upstream_error","safeCode":"rate_limited",'
            '"statusCode":429,"retryAfterSeconds":12,'
            '"message":"Authorization Bearer secret from '
            'http://private.example"}\n\n',
          );
          await request.response.close();
          return;
        }
        request.response.write(
          'data: {"choices":[{"delta":{"reasoning_content":"think",'
          '"content":"ok"}}]}\n\n'
          'data: [DONE]\n\n',
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'code': 0,
          'data': {
            'content': 'ok',
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
            },
          },
        }));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    BackendConfig.host = previousHost;
    BackendConfig.useHttps = previousUseHttps;
    await server.close();
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  BackendChatService serviceWithTopP(double? topP) => BackendChatService(
        AISettings.defaults()..topP = topP,
      );

  for (final effort in [null, ...DeepSeekReasoningEffort.values]) {
    test('后端代理所有入口传送所选等级 $effort', () async {
      final settings = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = 'deepseek-flash'
        ..deepSeekReasoningEffort = effort;
      final service = ChatService.from(settings);
      await service.chat(prompt: 'plain', history: const []);
      await service.chatWithUsage(prompt: 'usage', history: const []);
      await service
          .chatStream(prompt: 'stream', history: const []).drain<void>();
      await service
          .chatStreamEvents(prompt: 'typed', history: const []).drain<void>();
      await service.chatWithUsageWithOptions(
          prompt: 'usage options',
          history: const [],
          options: const ChatRequestOptions());
      await service
          .chatStreamEventsWithOptions(
              prompt: 'typed options',
              history: const [],
              options: const ChatRequestOptions())
          .drain<void>();
      expect(bodies, hasLength(6));
      for (final body in bodies) {
        expect(body.containsKey('thinking'), isFalse);
        if (effort == DeepSeekReasoningEffort.off) {
          expect(body['reasoning_policy'], 'off_if_supported');
          expect(body.containsKey('reasoning_effort'), isFalse);
        } else if (effort == null) {
          expect(body.containsKey('reasoning_effort'), isFalse);
          expect(body['reasoning_policy'], isNot('off_if_supported'));
        } else {
          expect(body['reasoning_effort'], effort.wireValue);
          expect(body['reasoning_policy'], isNot('off_if_supported'));
        }
      }
    });
  }

  test('后端等级覆盖、翻译关闭、抑制在流式和非流式保持一致', () async {
    final service = BackendChatService(AISettings.defaults()
      ..mode = AIMode.backend
      ..backendModel = 'deepseek-v4-pro'
      ..deepSeekReasoningEffort = DeepSeekReasoningEffort.max);
    for (final options in [
      const ChatRequestOptions(
          deepSeekReasoningEffort: DeepSeekReasoningEffort.low),
      const ChatRequestOptions(
          profile: ChatRequestProfile.translation,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported),
      const ChatRequestOptions(suppressReasoningControl: true),
    ]) {
      await service.chatWithUsageWithOptions(
          prompt: 'usage', history: const [], options: options);
      await service
          .chatStreamEventsWithOptions(
              prompt: 'stream', history: const [], options: options)
          .drain<void>();
    }
    expect(bodies[0]['reasoning_effort'], 'low');
    expect(bodies[1]['reasoning_effort'], 'low');
    for (final body in bodies.skip(2).take(2)) {
      expect(body['reasoning_policy'], 'off_if_supported');
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['request_profile'], 'translation');
    }
    for (final body in bodies.skip(4)) {
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['reasoning_policy'], isNot('off_if_supported'));
    }
  });

  test('后端非双模式模型不携带所选 DeepSeek 等级', () async {
    for (final model in ['deepseek-reasoner', 'gpt-5.2', 'custom-flash']) {
      final service = BackendChatService(AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = model
        ..deepSeekReasoningEffort = DeepSeekReasoningEffort.max);
      await service.chatWithUsage(prompt: 'usage', history: const []);
      await service
          .chatStreamEvents(prompt: 'stream', history: const []).drain<void>();
    }
    for (final body in bodies) {
      expect(body.containsKey('reasoning_effort'), isFalse);
    }
  });

  test('BackendChatService 可从流式 JSON 中解析 final usage 事件', () {
    final event = BackendChatService.usageEventFromStreamJson(const {
      'choices': [],
      'usage': {
        'prompt_tokens': 21,
        'prompt_tokens_details': {
          'cached_tokens': 8,
        },
        'completion_tokens': 9,
        'total_tokens': 30,
      },
    });

    expect(event, isNotNull);
    expect(event!.type, StreamEventType.usage);
    expect(event.promptTokens, 21);
    expect(event.cachedPromptTokens, 8);
    expect(event.completionTokens, 9);
  });

  test('BackendChatService 无 usage 的流式 JSON 不产生 usage 事件', () {
    final event = BackendChatService.usageEventFromStreamJson(const {
      'choices': [
        {
          'delta': {'content': '你好'}
        }
      ],
    });

    expect(event, isNull);
  });

  test('BackendChatService forwards top_p through all request variants',
      () async {
    final service = serviceWithTopP(0.6);

    await service.chat(prompt: 'one', history: const []);
    await service.chatWithUsage(prompt: 'two', history: const []);
    await service.chatStreamEvents(prompt: 'three', history: const []).toList();

    expect(bodies, hasLength(3));
    expect(bodies.map((body) => body['top_p']), everyElement(0.6));
  });

  test('BackendChatService omits top_p when unset', () async {
    await serviceWithTopP(null).chat(prompt: 'one', history: const []);

    expect(bodies.single.containsKey('top_p'), isFalse);
  });

  for (final model in ['deepseek-flash', 'deepseek-v4-pro', 'gpt-4o']) {
    test(
        'BackendChatService $model preserves compatible reasoning and leaves source intact',
        () async {
      final settings = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = model;
      final service = BackendChatService(settings);
      final history = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '',
          'reasoning_content': 'preserve locally',
          'tool_calls': [
            {
              'id': 'c',
              'type': 'function',
              'function': {'name': 'calc', 'arguments': '{}'}
            }
          ]
        },
        {'role': 'tool', 'tool_call_id': 'c', 'content': '42'},
        {'role': 'assistant', 'content': '42', 'reasoning_content': ''},
      ];
      final original = jsonEncode(history);
      await service.chat(prompt: 'one', history: history);
      await service.chatWithUsage(prompt: 'two', history: history);
      await service
          .chatStreamEvents(prompt: 'three', history: history)
          .drain<void>();
      expect(bodies, hasLength(3));
      for (final body in bodies) {
        final transmitted =
            (body['messages'] as List).take(history.length).toList();
        if (model.startsWith('deepseek-')) {
          expect(transmitted, history);
        } else {
          final stripped = history.map((row) {
            final copy = Map<String, dynamic>.from(row);
            copy.remove('reasoning_content');
            return copy;
          }).toList();
          expect(transmitted, stripped);
        }
      }
      expect(jsonEncode(history), original);
    });
  }

  test(
      'options-aware stream sends only semantic policy fields and raises max tokens',
      () async {
    final settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..maxOutputTokens = 512;
    final service = BackendChatService(settings);

    final events = await service
        .chatStreamEventsWithOptions(
          prompt: 'translate',
          history: const [],
          options: const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
            connectTimeout: Duration(milliseconds: 321),
            minOutputTokens: 2048,
          ),
        )
        .toList();

    expect(events.map((event) => event.type), [
      StreamEventType.reasoning,
      StreamEventType.text,
    ]);
    expect(events.map((event) => event.delta), ['think', 'ok']);
    expect(bodies.single['request_profile'], 'translation');
    expect(bodies.single['reasoning_policy'], 'off_if_supported');
    expect(bodies.single['max_tokens'], 2048);
    expect(
      bodies.single.keys.where(
        (key) =>
            key.contains('timeout') ||
            key.contains('deadline') ||
            key.contains('abort'),
      ),
      isEmpty,
    );
  });

  test('options-aware stream uses the exact max output token override',
      () async {
    final service = BackendChatService(AISettings.defaults()
      ..mode = AIMode.backend
      ..maxOutputTokens = 4096);

    await service
        .chatStreamEventsWithOptions(
          prompt: 'probe',
          history: const [],
          options: const ChatRequestOptions(
            minOutputTokens: 2048,
            maxOutputTokensOverride: 128,
          ),
        )
        .drain<void>();

    expect(bodies.single['max_tokens'], 128);
  });

  test('max token calculation runs before the mapped transport try block', () {
    final source =
        File('lib/dao/chat/backend_chat_service.dart').readAsStringSync();
    final methodStart = source.indexOf(
      'Stream<StreamEvent> chatStreamEventsWithOptions({',
    );
    final methodEnd = source.indexOf('\n  int? _maxTokensFor', methodStart);
    final method = source.substring(methodStart, methodEnd);
    final calculation = method.indexOf(
      'final maxTokens = _maxTokensFor(options);',
    );
    final mappedTry = method.indexOf('try {');

    expect(methodStart, isNonNegative);
    expect(methodEnd, isNonNegative);
    expect(calculation, isNonNegative);
    expect(mappedTry, isNonNegative);
    expect(calculation, lessThan(mappedTry));
    expect(method, contains("'max_tokens': maxTokens"));
  });

  test('options-aware stream sends provider_default when control is suppressed',
      () async {
    final service = BackendChatService(AISettings.defaults()
      ..mode = AIMode.backend
      ..maxOutputTokens = 4096);

    await service
        .chatStreamEventsWithOptions(
          prompt: 'translate',
          history: const [],
          options: const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
            minOutputTokens: 2048,
            suppressReasoningControl: true,
          ),
        )
        .drain<void>();

    expect(bodies.single['reasoning_policy'], 'provider_default');
    expect(bodies.single['max_tokens'], 4096);
  });

  test('options-aware stream preserves safe HTTP error metadata only',
      () async {
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'http-error',
        history: const [],
        options: const ChatRequestOptions(
          profile: ChatRequestProfile.translation,
        ),
      ),
    );

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 429)
          .having((value) => value.retryAfter, 'retryAfter',
              const Duration(seconds: 17))
          .having((value) => value.safeCode, 'safeCode', 'rate_limited'),
    );
    _expectNoUnsafeErrorData(error);
  });

  test('options-aware stream preserves safe SSE error metadata only', () async {
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'sse-error',
        history: const [],
        options: const ChatRequestOptions(
          profile: ChatRequestProfile.translation,
        ),
      ),
    );

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 429)
          .having((value) => value.retryAfter, 'retryAfter',
              const Duration(seconds: 12))
          .having((value) => value.safeCode, 'safeCode', 'rate_limited'),
    );
    _expectNoUnsafeErrorData(error);
  });

  test('options-aware stream preserves the reasoning-control safe code',
      () async {
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'reasoning-control-code',
        history: const [],
        options: const ChatRequestOptions(
          profile: ChatRequestProfile.translation,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
      ),
    );

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 400)
          .having((value) => value.safeCode, 'safeCode',
              'unsupported_reasoning_control'),
    );
    _expectNoUnsafeErrorData(error);
  });

  test('options-aware stream keeps a raw unknown parameter distinct', () async {
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'raw-unknown-code',
        history: const [],
        options: const ChatRequestOptions(
          profile: ChatRequestProfile.translation,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
      ),
    );

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 400)
          .having((value) => value.safeCode, 'safeCode', 'unknown_parameter'),
    );
    _expectNoUnsafeErrorData(error);
  });

  for (final deadline in const {
    'first-event-deadline-code': 'first_event_timeout',
    'idle-deadline-code': 'idle_timeout',
    'total-deadline-code': 'total_timeout',
  }.entries) {
    test('options-aware stream preserves ${deadline.value}', () async {
      final service =
          BackendChatService(AISettings.defaults()..mode = AIMode.backend);

      final error = await _captureError(
        service.chatStreamEventsWithOptions(
          prompt: deadline.key,
          history: const [],
          options: const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
          ),
        ),
      );

      expect(
        error,
        isA<ChatTransportException>()
            .having((value) => value.statusCode, 'statusCode', 504)
            .having((value) => value.safeCode, 'safeCode', deadline.value),
      );
      _expectNoUnsafeErrorData(error);
    });
  }

  test('options-aware stream keeps app login for trusted provider 401 envelope',
      () async {
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'provider-401',
        history: const [],
        options: const ChatRequestOptions(),
      ),
    );
    await _awaitAuthQueueWithAccount();

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 401)
          .having(
              (value) => value.safeCode, 'safeCode', 'authentication_error'),
    );
    expect(storage.clearCalls, 0);
    expect(storage.readTokenSync(), 'app-jwt');
    expect(logoutNavigations, 0);
    _expectNoUnsafeErrorData(error);
  });

  test('options-aware stream still logs out for backend-auth 401', () async {
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'backend-auth-401',
        history: const [],
        options: const ChatRequestOptions(),
      ),
    );
    await storage.cleared.future.timeout(const Duration(seconds: 1));

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 401)
          .having(
              (value) => value.safeCode, 'safeCode', 'authentication_error'),
    );
    expect(storage.clearCalls, 1);
    expect(storage.readTokenSync(), isNull);
    expect(logoutNavigations, 1);
  });

  for (final method in const ['chat', 'chatWithUsage']) {
    test('$method keeps app login and exposes typed provider 401 safely',
        () async {
      final service =
          BackendChatService(AISettings.defaults()..mode = AIMode.backend);

      final error = await _captureFutureError(
        _runNonStreamingRequest(service, method, 'provider-401'),
      );
      await _awaitAuthQueueWithAccount();

      expect(
        error,
        isA<ChatTransportException>()
            .having((value) => value.statusCode, 'statusCode', 401)
            .having(
              (value) => value.safeCode,
              'safeCode',
              'authentication_error',
            ),
      );
      expect(storage.clearCalls, 0);
      expect(storage.readTokenSync(), 'app-jwt');
      expect(logoutNavigations, 0);
      _expectNoUnsafeErrorData(error);
    });

    test('$method still logs out for backend-auth 401', () async {
      final service =
          BackendChatService(AISettings.defaults()..mode = AIMode.backend);

      final error = await _captureFutureError(
        _runNonStreamingRequest(service, method, 'backend-auth-401'),
      );
      await storage.cleared.future.timeout(const Duration(seconds: 1));

      expect(error.toString(), contains('登录已过期'));
      expect(storage.clearCalls, 1);
      expect(storage.readTokenSync(), isNull);
      expect(logoutNavigations, 1);
    });
  }

  const headerRetryCases = <String, int?>{
    'retry-header-zero': 1,
    'retry-header-over': 120,
    'retry-header-large': 120,
    'retry-header-overflow': null,
    'retry-header-signed': null,
    'retry-header-date': null,
    'retry-header-sensitive': null,
  };
  for (final testCase in headerRetryCases.entries) {
    test('options-aware stream clamps strict Retry-After ${testCase.key}',
        () async {
      final service =
          BackendChatService(AISettings.defaults()..mode = AIMode.backend);

      final error = await _captureError(
        service.chatStreamEventsWithOptions(
          prompt: testCase.key,
          history: const [],
          options: const ChatRequestOptions(),
        ),
      );

      expect(
        error,
        isA<ChatTransportException>().having(
          (value) => value.retryAfter,
          'retryAfter',
          testCase.value == null ? null : Duration(seconds: testCase.value!),
        ),
      );
      _expectNoUnsafeErrorData(error);
      expect(error.toString(), isNot(contains('header-secret')));
    });
  }

  const payloadRetryCases = <String, int?>{
    'retry-payload-zero': 1,
    'retry-payload-over': 120,
    'retry-payload-large': 120,
    'retry-payload-overflow': null,
    'retry-payload-negative': null,
    'retry-payload-spaced': null,
    'retry-payload-date': null,
    'retry-payload-sensitive': null,
  };
  for (final testCase in payloadRetryCases.entries) {
    test('options-aware stream clamps SSE retry seconds ${testCase.key}',
        () async {
      final service =
          BackendChatService(AISettings.defaults()..mode = AIMode.backend);

      final error = await _captureError(
        service.chatStreamEventsWithOptions(
          prompt: testCase.key,
          history: const [],
          options: const ChatRequestOptions(),
        ),
      );

      expect(
        error,
        isA<ChatTransportException>().having(
          (value) => value.retryAfter,
          'retryAfter',
          testCase.value == null ? null : Duration(seconds: testCase.value!),
        ),
      );
      _expectNoUnsafeErrorData(error);
    });
  }

  test('options-aware stream aborts the request and emits no late token',
      () async {
    final delayed = await _DelayedSseServer.start();
    addTearDown(delayed.close);
    BackendConfig.host =
        '${delayed.server.address.host}:${delayed.server.port}';
    final abort = Completer<void>();
    final firstToken = Completer<void>();
    final failure = Completer<Object>();
    final received = <String>[];
    final service =
        BackendChatService(AISettings.defaults()..mode = AIMode.backend);
    final subscription = service
        .chatStreamEventsWithOptions(
      prompt: 'cancel',
      history: const [],
      options: ChatRequestOptions(abortTrigger: abort.future),
    )
        .listen(
      (event) {
        received.add(event.delta);
        if (!firstToken.isCompleted) firstToken.complete();
      },
      onError: (Object error) {
        if (!failure.isCompleted) failure.complete(error);
      },
      onDone: () {
        if (!failure.isCompleted) {
          failure.complete(StateError('stream completed before cancellation'));
        }
      },
    );
    addTearDown(subscription.cancel);

    await firstToken.future.timeout(const Duration(seconds: 1));
    abort.complete();
    final error = await failure.future.timeout(const Duration(seconds: 1));
    await delayed.lateWriteAttempted.timeout(const Duration(seconds: 1));

    expect(received, ['first']);
    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.safeCode, 'safeCode', 'cancelled'),
    );
  });
}

Future<Object> _captureError(Stream<Object?> stream) async {
  try {
    await stream.drain<void>();
  } catch (error) {
    return error;
  }
  return StateError('stream completed without an error');
}

Future<Object> _captureFutureError(Future<void> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  return StateError('future completed without an error');
}

Future<void> _runNonStreamingRequest(
  BackendChatService service,
  String method,
  String prompt,
) async {
  if (method == 'chat') {
    await service.chat(prompt: prompt, history: const []);
    return;
  }
  await service.chatWithUsage(prompt: prompt, history: const []);
}

Future<void> _awaitAuthQueueWithAccount() => LoginDao.runWithStableAccount(
      expectedAccountHash: 'account-1',
      action: () async {},
    );

void _expectNoUnsafeErrorData(Object error) {
  for (final unsafe in [
    'Authorization',
    'Bearer',
    'secret',
    'private.example',
  ]) {
    expect(error.toString(), isNot(contains(unsafe)));
  }
}

final class _DelayedSseServer {
  _DelayedSseServer._(
    this.server,
    this.lateWriteAttempted,
    this._responses,
  );

  final HttpServer server;
  final Future<void> lateWriteAttempted;
  final List<HttpResponse> _responses;

  static Future<_DelayedSseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final lateWriteAttempted = Completer<void>();
    final responses = <HttpResponse>[];
    server.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      responses.add(response);
      response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      response.write(
        'data: {"choices":[{"delta":{"content":"first"}}]}\n\n',
      );
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      try {
        response.write(
          'data: {"choices":[{"delta":{"content":"late"}}]}\n\n'
          'data: [DONE]\n\n',
        );
        await response.close();
      } catch (_) {
        // AbortableRequest 关闭连接后，服务端晚写应失败。
      } finally {
        if (!lateWriteAttempted.isCompleted) lateWriteAttempted.complete();
      }
    });
    return _DelayedSseServer._(
      server,
      lateWriteAttempted.future,
      responses,
    );
  }

  Future<void> close() async {
    for (final response in _responses) {
      try {
        await response.close();
      } catch (_) {
        // 测试请求可能已经由客户端取消。
      }
    }
    await server.close(force: true);
  }
}

class _RecordingTokenStorage implements TokenStorage {
  _RecordingTokenStorage.seeded()
      : _profile = {
          'boardingPass': 'app-jwt',
          'userName': 'tester',
          'accountHash': 'account-1',
        };

  Map<String, dynamic>? _profile;
  int clearCalls = 0;
  final Completer<void> cleared = Completer<void>();

  @override
  Future<void> clear() async {
    clearCalls++;
    _profile = null;
    if (!cleared.isCompleted) cleared.complete();
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = {
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode,
      ...extras,
    };
  }
}
