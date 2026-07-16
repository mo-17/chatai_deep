import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';

void main() {
  test('external abort disconnects an active SSE request', () async {
    final server = await _HangingBodyServer.start(
      contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
      body: 'data: {"choices":[{"delta":{"content":"first"}}]}\n\n',
    );
    addTearDown(server.close);

    final completion = AICompletion(_configFor(server.server));
    final abort = Completer<void>();
    final firstToken = Completer<void>();
    final errors = <Object>[];
    final events = completion.createChatStreamEvents(
      model: 'test',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
      abortTrigger: abort.future,
    );
    final subscription = events.listen(
      (event) {
        if (event.text == 'first' && !firstToken.isCompleted) {
          firstToken.complete();
        }
      },
      onError: errors.add,
    );

    await firstToken.future.timeout(const Duration(seconds: 1));
    abort.complete();
    await expectLater(
      server.clientDisconnected.timeout(const Duration(seconds: 1)),
      completes,
    );
    await subscription.cancel();
  });

  test('subscription cancellation disconnects an active SSE request', () async {
    final server = await _HangingBodyServer.start(
      contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
      body: 'data: {"choices":[{"delta":{"content":"first"}}]}\n\n',
    );
    addTearDown(server.close);

    final firstToken = Completer<void>();
    final subscription =
        AICompletion(_configFor(server.server)).createChatStreamEvents(
      model: 'test',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
    ).listen((event) {
      if (event.text == 'first' && !firstToken.isCompleted) {
        firstToken.complete();
      }
    });
    addTearDown(subscription.cancel);

    await firstToken.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();

    await expectLater(
      server.clientDisconnected.timeout(const Duration(seconds: 1)),
      completes,
    );
  });

  test('non-stream timeout disconnects the in-flight socket', () async {
    final server = await _HangingBodyServer.start(
      contentType: ContentType.json,
      body: '{"choices":',
    );
    addTearDown(server.close);

    Object? failure;
    try {
      await AICompletion(_configFor(server.server)).createChat(
        prompt: 'hello',
        timeout: const Duration(milliseconds: 50),
      );
    } catch (error) {
      failure = error;
    }

    expect(failure, isNotNull);
    await expectLater(
      server.clientDisconnected.timeout(const Duration(seconds: 1)),
      completes,
    );
  });

  test('stream connect timeout disconnects before response headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Socket? detachedSocket;
    addTearDown(() async {
      detachedSocket?.destroy();
      await server.close(force: true);
    });
    final requestReceived = Completer<void>();
    final serverObservedClose = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      final socket = await request.response.detachSocket(writeHeaders: false);
      detachedSocket = socket;
      socket.listen(
        (_) {},
        onError: (_) {
          if (!serverObservedClose.isCompleted) {
            serverObservedClose.complete();
          }
        },
        onDone: () {
          if (!serverObservedClose.isCompleted) {
            serverObservedClose.complete();
          }
        },
        cancelOnError: true,
      );
      if (!requestReceived.isCompleted) requestReceived.complete();
    });

    final events = AICompletion(_configFor(server)).createChatStreamEvents(
      model: 'test',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
      connectTimeout: const Duration(milliseconds: 50),
    );
    final failure = Completer<Object>();
    final subscription = events.listen(
      (_) {},
      onError: (Object error) {
        if (!failure.isCompleted) failure.complete(error);
      },
    );
    addTearDown(subscription.cancel);

    await requestReceived.future.timeout(const Duration(seconds: 1));
    expect(
      await failure.future.timeout(const Duration(seconds: 1)),
      isA<http.RequestAbortedException>(),
    );
    await expectLater(
      serverObservedClose.future.timeout(const Duration(seconds: 1)),
      completes,
    );
  });

  test('event error frame fails the SSE stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(
        'event: error\n'
        'data: {"error":{"message":"stream exploded"}}\n\n',
      );
      await request.response.close();
    });

    await expectLater(
      AICompletion(_configFor(server)).createChatStreamEvents(
        model: 'test',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
      ),
      emitsError(
        isA<AIRequestException>().having(
          (error) => error.message,
          'message',
          'stream exploded',
        ),
      ),
    );
  });

  test('top-level error object fails the SSE stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(
        'data: {"error":{"message":"provider stream error"}}\n\n',
      );
      await request.response.close();
    });

    await expectLater(
      AICompletion(_configFor(server)).createChatStreamEvents(
        model: 'test',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
      ),
      emitsError(
        isA<AIRequestException>().having(
          (error) => error.message,
          'message',
          'provider stream error',
        ),
      ),
    );
  });

  test('request errors retain immutable lowercase response headers safely',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final url = 'http://${server.address.host}:${server.port}/chat?secret=yes';
    server.listen((request) async {
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.headers.set('Retry-After', '7');
      request.response.headers.set('X-Request-ID', 'request-123');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': {
          'message': 'body sk-secret Authorization Bearer test-key from $url',
        },
      }));
      await request.response.close();
    });

    AIRequestException? failure;
    try {
      await AICompletion(AIConfigBuilder(apiKey: 'test-key', chatUrl: url))
          .createChat(prompt: 'hello');
    } on AIRequestException catch (error) {
      failure = error;
    }

    expect(failure, isNotNull);
    expect(failure!.statusCode, HttpStatus.tooManyRequests);
    expect(failure.headers['retry-after'], '7');
    expect(failure.headers['x-request-id'], 'request-123');
    expect(failure.headers, isNot(contains('Retry-After')));
    expect(failure.retryAfter, const Duration(seconds: 7));
    expect(
      () => failure!.headers['retry-after'] = '99',
      throwsUnsupportedError,
    );
    expect(failure.toString(), contains('429'));
    expect(failure.toString(), isNot(contains('sk-secret')));
    expect(failure.toString(), isNot(contains('Authorization')));
    expect(failure.toString(), isNot(contains('test-key')));
    expect(failure.toString(), isNot(contains(url)));
  });
}

AIConfigBuilder _configFor(HttpServer server) => AIConfigBuilder(
      apiKey: 'test-key',
      chatUrl: 'http://${server.address.host}:${server.port}/chat',
    );

final class _HangingBodyServer {
  _HangingBodyServer._(
    this.server,
    this.clientDisconnected,
    this._sockets,
  );

  final HttpServer server;
  final Future<void> clientDisconnected;
  final List<Socket> _sockets;

  static Future<_HangingBodyServer> start({
    required ContentType contentType,
    required String body,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final clientDisconnected = Completer<void>();
    final sockets = <Socket>[];
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = contentType;
      request.response.headers.chunkedTransferEncoding = false;
      request.response.headers.set(HttpHeaders.connectionHeader, 'close');
      final socket = await request.response.detachSocket();
      sockets.add(socket);
      socket.listen(
        (_) {},
        onError: (_) {
          if (!clientDisconnected.isCompleted) {
            clientDisconnected.complete();
          }
        },
        onDone: () {
          if (!clientDisconnected.isCompleted) {
            clientDisconnected.complete();
          }
        },
        cancelOnError: true,
      );
      socket.add(utf8.encode(body));
      await socket.flush();
    });
    return _HangingBodyServer._(
      server,
      clientDisconnected.future,
      sockets,
    );
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close(force: true);
  }
}
