import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DirectChatService forwards top_p through all request variants',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      bodies.add(body);
      if (body['stream'] == true) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
          'data: [DONE]\n\n',
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'}
            }
          ],
        }));
      }
      await request.response.close();
    });

    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'test-model',
      ),
      topP: 0.45,
    );

    await service.chat(prompt: 'one', history: const []);
    await service.chatWithUsage(prompt: 'two', history: const []);
    await service.chatStream(prompt: 'three', history: const []).toList();
    await service.chatStreamEvents(prompt: 'four', history: const []).toList();

    expect(bodies, hasLength(4));
    expect(bodies.map((body) => body['top_p']), everyElement(0.45));
  });

  test('DirectChatService omits top_p when unset', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    late Map<String, dynamic> captured;
    server.listen((request) async {
      captured = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'}
          }
        ],
      }));
      await request.response.close();
    });

    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'test-model',
      ),
    );
    await service.chat(prompt: 'one', history: const []);

    expect(captured.containsKey('top_p'), isFalse);
  });

  test(
      'options-aware stream sends provider fields, raises max tokens, and keeps reasoning before text',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late Map<String, dynamic> captured;
    server.listen((request) async {
      captured = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(
        'data: {"choices":[{"delta":{"reasoning_content":"think",'
        '"content":"answer"}}]}\n\n'
        'data: [DONE]\n\n',
      );
      await request.response.close();
    });

    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'deepseek-v4-flash',
      ),
      providerId: 'deepseek',
      providerCode: 'deepseek',
      maxOutputTokens: 512,
    );

    final events = await service
        .chatStreamEventsWithOptions(
          prompt: 'translate',
          history: const [],
          options: const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
            minOutputTokens: 2048,
          ),
        )
        .toList();

    expect(events.map((event) => event.type), [
      StreamEventType.reasoning,
      StreamEventType.text,
    ]);
    expect(events.map((event) => event.delta), ['think', 'answer']);
    expect(captured['thinking'], {'type': 'disabled'});
    expect(captured['max_tokens'], 2048);
    expect(captured.containsKey('request_profile'), isFalse);
    expect(captured.containsKey('reasoning_policy'), isFalse);
  });

  test('options-aware stream uses the exact max output token override',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late Map<String, dynamic> captured;
    server.listen((request) async {
      captured = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'test-model',
      ),
      maxOutputTokens: 4096,
    );

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

    expect(captured['max_tokens'], 128);
  });

  test('max token calculation runs before the mapped transport try block', () {
    final source =
        File('lib/dao/chat/direct_chat_service.dart').readAsStringSync();
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
    expect(method, contains('maxTokens: maxTokens,'));
  });

  test('ChatService.from passes exact provider id instead of trusting its code',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late Map<String, dynamic> captured;
    server.listen((request) async {
      captured = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final settings = AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'custom_1',
          type: 'openai',
          name: 'Custom',
          apiKey: 'test-key',
          apiHost: 'http://${server.address.host}:${server.port}/chat',
          models: [AiModel(id: 'gpt-5.2')],
          selectedModelId: 'gpt-5.2',
          enabled: true,
        ),
      ],
      activeProviderId: 'custom_1',
      backendModel: 'unused',
      streamEnabled: true,
      resetOnLogout: true,
    );
    final service = ChatService.from(settings);

    await service
        .chatStreamEventsWithOptions(
          prompt: 'translate',
          history: const [],
          options: const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          ),
        )
        .drain<void>();

    expect(captured.containsKey('reasoning_effort'), isFalse);
  });

  test('legacy ChatService uses the default options delegation unchanged',
      () async {
    final service = _LegacyChatService();

    final events = await service
        .chatStreamEventsWithOptions(
          prompt: 'legacy',
          history: const [],
          options: const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          ),
        )
        .toList();

    expect(service.calls, 1);
    expect(events.single.type, StreamEventType.text);
    expect(events.single.delta, 'legacy');
  });

  test('options-aware stream forwards abort and exposes safe cancellation',
      () async {
    final server = await _HangingSseServer.start();
    addTearDown(server.close);
    final abort = Completer<void>();
    final firstToken = Completer<void>();
    final failure = Completer<Object>();
    final received = <String>[];
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl:
            'http://${server.server.address.host}:${server.server.port}/chat',
        model: 'test-model',
      ),
      providerId: 'custom_1',
      providerCode: 'openai',
    );
    final subscription = service
        .chatStreamEventsWithOptions(
      prompt: 'translate',
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

    expect(received, ['first']);
    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.safeCode, 'safeCode', 'cancelled')
          .having((value) => value.statusCode, 'statusCode', isNull),
    );
    expect(error.toString(), isNot(contains(service.toString())));
    await expectLater(
      server.clientDisconnected.timeout(const Duration(seconds: 1)),
      completes,
    );
  });

  test('options-aware stream maps connect timeout to a safe transport error',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Socket? detachedSocket;
    addTearDown(() async {
      detachedSocket?.destroy();
      await server.close(force: true);
    });
    final requestReceived = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      detachedSocket = await request.response.detachSocket(writeHeaders: false);
      if (!requestReceived.isCompleted) requestReceived.complete();
    });
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/private',
        model: 'test-model',
      ),
      providerId: 'custom_1',
      providerCode: 'openai',
    );

    final failure = _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'translate',
        history: const [],
        options: const ChatRequestOptions(
          connectTimeout: Duration(milliseconds: 50),
          maxAutoRetries: 0,
        ),
      ),
    );
    await requestReceived.future.timeout(const Duration(seconds: 1));
    final error = await failure.timeout(const Duration(seconds: 1));

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.safeCode, 'safeCode', 'timeout'),
    );
    expect(error.toString(), isNot(contains('/private')));
  });

  test('response-body timeout is diagnosed after response and never retried',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      await request.drain<void>();
      requests++;
      request.response.headers.contentType = ContentType.json;
      request.response.bufferOutput = false;
      request.response.write('{"choices":[');
      await request.response.flush();
      // 保持成功响应正文未结束，直到 SDK 请求期限取消该连接。
    });
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'test-model',
      ),
      providerId: 'custom_1',
      providerCode: 'openai',
    );
    await expectLater(
      service.chat(
        prompt: 'test',
        history: const [],
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<ChatTransportException>()
          .having((error) => error.safeCode, 'code', 'timeout')
          .having((error) => error.responseStarted, 'response started', isTrue)
          .having((error) => error.failureStage, 'stage',
              ChatFailureStage.response)),
    );
    expect(requests, 1);
  });

  test('options-aware stream rejects invalid endpoint without exposing it',
      () async {
    const unsafeUrl = 'http://127.0.0.1:not-a-port/private?key=secret';
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: unsafeUrl,
        model: 'test-model',
      ),
      providerId: 'custom_1',
      providerCode: 'openai',
    );

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'translate',
        history: const [],
        options: const ChatRequestOptions(),
      ),
    );

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.safeCode, 'safeCode', 'invalid_endpoint'),
    );
    expect(error.toString(), isNot(contains(unsafeUrl)));
    expect(error.toString(), isNot(contains('secret')));
  });

  test('options-aware stream preserves only allowlisted request error metadata',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final unsafeUrl =
        'http://${server.address.host}:${server.port}/private?key=secret';
    server.listen((request) async {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.set('Retry-After', '5');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': {
          'code': 'unknown_parameter',
          'message': 'Authorization Bearer secret from $unsafeUrl',
        },
      }));
      await request.response.close();
    });
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: unsafeUrl,
        model: 'gpt-5.2',
      ),
      providerId: 'openai',
      providerCode: 'openai',
    );

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'translate',
        history: const [],
        options: const ChatRequestOptions(
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
      ),
    );

    expect(
      error,
      isA<ChatTransportException>()
          .having((value) => value.statusCode, 'statusCode', 400)
          .having((value) => value.retryAfter, 'retryAfter',
              const Duration(seconds: 5))
          .having((value) => value.safeCode, 'safeCode',
              'unsupported_reasoning_control'),
    );
    expect(error.toString(), isNot(contains('Authorization')));
    expect(error.toString(), isNot(contains(unsafeUrl)));
    expect(error.toString(), isNot(contains('secret')));
  });

  test(
      'options-aware stream keeps explicit parameter code when no reasoning field was attached',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      expect(body.containsKey('reasoning_effort'), isFalse);
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': {
          'code': 'unknown_parameter',
          'message': 'SECRET unrelated upstream parameter',
        },
      }));
      await request.response.close();
    });
    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'gpt-5.2',
      ),
      providerId: 'custom_1',
      providerCode: 'openai',
    );

    final error = await _captureError(
      service.chatStreamEventsWithOptions(
        prompt: 'translate',
        history: const [],
        options: const ChatRequestOptions(
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
    expect(error.toString(), isNot(contains('SECRET')));
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

final class _LegacyChatService implements ChatService {
  int calls = 0;

  @override
  ModelCapabilities get capabilities => const ModelCapabilities();

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) async =>
      'legacy';

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      Stream.value('legacy');

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) {
    calls++;
    return Stream.value(StreamEvent.text('legacy'));
  }

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async =>
      const ChatCompletionResult(content: 'legacy');
}

final class _HangingSseServer {
  _HangingSseServer._(
    this.server,
    this.clientDisconnected,
    this._sockets,
  );

  final HttpServer server;
  final Future<void> clientDisconnected;
  final List<Socket> _sockets;

  static Future<_HangingSseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final disconnected = Completer<void>();
    final sockets = <Socket>[];
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.headers.chunkedTransferEncoding = false;
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
      final socket = await request.response.detachSocket();
      sockets.add(socket);
      socket.listen(
        (_) {},
        onError: (_) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        cancelOnError: true,
      );
      socket.add(utf8.encode(
        'data: {"choices":[{"delta":{"content":"first"}}]}\n\n',
      ));
      await socket.flush();
    });
    return _HangingSseServer._(server, disconnected.future, sockets);
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close(force: true);
  }
}
