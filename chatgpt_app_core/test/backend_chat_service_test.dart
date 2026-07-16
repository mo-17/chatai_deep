import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';

void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> bodies;
  late String previousHost;
  late bool previousUseHttps;

  setUpAll(() {
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: _EmptyTokenStorage(),
      onLogoutNavigate: () {},
    ));
  });

  tearDownAll(LoginSdkConfig.reset);

  setUp(() async {
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
      if (request.uri.path.endsWith('/stream')) {
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
  });

  BackendChatService serviceWithTopP(double? topP) => BackendChatService(
        AISettings.defaults()..topP = topP,
      );

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

class _EmptyTokenStorage implements TokenStorage {
  @override
  Future<void> clear() async {}

  @override
  Future<Map<String, dynamic>?> readProfile() async => null;

  @override
  Map<String, dynamic>? readProfileSync() => null;

  @override
  Future<String?> readToken() async => null;

  @override
  String? readTokenSync() => null;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {}
}
