import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';
import 'package:openai_flutter/http/ai_http.dart';

void main() {
  test('external abort exposes a safe typed cancellation and disconnects',
      () async {
    final server = await _HangingBodyServer.start(
      contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
      body: 'data: {"choices":[{"delta":{"content":"first"}}]}\n\n',
    );
    addTearDown(server.close);

    final config = _configFor(server.server);
    final completion = AICompletion(config);
    final abort = Completer<void>();
    final firstToken = Completer<void>();
    final failure = Completer<Object>();
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
      onError: (Object error) {
        if (!failure.isCompleted) failure.complete(error);
      },
    );

    await firstToken.future.timeout(const Duration(seconds: 1));
    abort.complete();
    final error = await failure.future.timeout(const Duration(seconds: 1));
    expect(error, isA<AIRequestCancelledException>());
    expect(error, isNot(isA<http.RequestAbortedException>()));
    expect(error.toString(), 'AIRequestCancelledException: Request cancelled');
    expect(error.toString(), isNot(contains(config.chatUrl)));
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

    expect(failure, isA<TimeoutException>());
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

    final config = _configFor(server);
    final events = AICompletion(config).createChatStreamEvents(
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
    final error = await failure.future.timeout(const Duration(seconds: 1));
    expect(error, isA<TimeoutException>());
    expect(error, isNot(isA<http.RequestAbortedException>()));
    expect(error.toString(), isNot(contains(config.chatUrl)));
    await expectLater(
      serverObservedClose.future.timeout(const Duration(seconds: 1)),
      completes,
    );
  });

  for (final streaming in const [false, true]) {
    test(
        '${streaming ? 'stream' : 'non-stream'} closed-port failure is a safe transport exception',
        () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final url = 'http://127.0.0.1:$port/chat'
          '?token=query-secret&key=sk-secret';
      final completion = AICompletion(AIConfigBuilder(
        apiKey: 'test-key',
        chatUrl: url,
      ));

      Object? failure;
      try {
        if (streaming) {
          await completion
              .createChatStreamEvents(
                prompt: 'hello',
                connectTimeout: const Duration(seconds: 1),
              )
              .drain<void>();
        } else {
          await completion.createChat(
            prompt: 'hello',
            timeout: const Duration(seconds: 1),
          );
        }
      } catch (error) {
        failure = error;
      }

      _expectSafeTransportFailure(failure, url);
    });
  }

  for (final streaming in const [false, true]) {
    test(
        '${streaming ? 'stream' : 'non-stream'} malformed endpoint is a safe transport exception',
        () async {
      const url =
          'http://127.0.0.1:not-a-port/chat?token=query-secret&key=sk-secret';
      final completion = AICompletion(AIConfigBuilder(
        apiKey: 'test-key',
        chatUrl: url,
      ));

      Object? failure;
      try {
        if (streaming) {
          await completion
              .createChatStreamEvents(prompt: 'hello')
              .drain<void>();
        } else {
          await completion.createChat(prompt: 'hello');
        }
      } catch (error) {
        failure = error;
      }

      _expectSafeTransportFailure(failure, url);
    });
  }

  test('non-stream caller callback errors are not transport-wrapped', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    });
    final url = 'http://${server.address.host}:${server.port}/chat';

    await expectLater(
      AIHttp.post<void>(
        config: AIConfigBuilder(apiKey: 'test-key', chatUrl: url),
        url: url,
        body: const {'model': 'test'},
        onSuccess: (_) => throw const FormatException('caller-owned failure'),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'caller-owned failure',
        ),
      ),
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
          'Streaming request failed',
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
          'Streaming request failed',
        ),
      ),
    );
  });

  test('event error takes precedence over a DONE data line', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('event: error\ndata: [DONE]\n\n');
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
          'Streaming request failed',
        ),
      ),
    );
  });

  test('blank SSE line resets event state before the next block', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(
        'event: error\n'
        '\n'
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
        'data: [DONE]\n\n',
      );
      await request.response.close();
    });

    final events =
        await AICompletion(_configFor(server)).createChatStreamEvents(
      model: 'test',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
    ).toList();

    expect(events.single.text, 'ok');
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
      request.response.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer response-secret',
      );
      request.response.headers.set('Set-Cookie', 'session=response-cookie');
      request.response.headers.set('X-Api-Key', 'response-api-key');
      request.response.headers.set(HttpHeaders.locationHeader, url);
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
    expect(failure.message, 'HTTP request failed');
    expect(failure.headers['retry-after'], '7');
    expect(
      failure.headers.keys,
      unorderedEquals(const ['retry-after']),
    );
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
    expect(failure.message, isNot(contains('sk-secret')));
    expect(failure.message, isNot(contains('Authorization')));
    expect(failure.message, isNot(contains('test-key')));
    expect(failure.message, isNot(contains(url)));
    expect(failure.headers.toString(), isNot(contains('response-secret')));
    expect(failure.headers.toString(), isNot(contains('response-cookie')));
    expect(failure.headers.toString(), isNot(contains('response-api-key')));
    expect(failure.headers.toString(), isNot(contains(url)));
  });

  test('non-JSON error body is not saved in the public exception', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final url = 'http://${server.address.host}:${server.port}/private/path';
    server.listen((request) async {
      request.response.statusCode = HttpStatus.badGateway;
      request.response.headers.contentType =
          ContentType('text', 'plain', charset: 'utf-8');
      request.response.write(
        'upstream body sk-secret Authorization Bearer test-key from $url',
      );
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
    expect(failure!.message, 'HTTP request failed');
    expect(failure.toString(), contains('502'));
    for (final sensitive in [
      'upstream body',
      'sk-secret',
      'Authorization',
      'test-key',
      url,
    ]) {
      expect(failure.message, isNot(contains(sensitive)));
      expect(failure.toString(), isNot(contains(sensitive)));
    }
  });

  test('retryAfter accepts only non-negative decimal delay-seconds', () {
    AIRequestException withRetryAfter(String value) => AIRequestException(
          'safe',
          HttpStatus.tooManyRequests,
          headers: {'Retry-After': value},
        );

    final zero = withRetryAfter('0');
    expect(zero.headers, const {'retry-after': '0'});
    expect(zero.retryAfter, Duration.zero);
    final seven = withRetryAfter('7');
    expect(seven.headers, const {'retry-after': '7'});
    expect(seven.retryAfter, const Duration(seconds: 7));
    final padded = withRetryAfter('007');
    expect(padded.headers, const {'retry-after': '7'});
    expect(padded.retryAfter, const Duration(seconds: 7));
    for (final invalid in const [
      '-1',
      '+1',
      '1.5',
      ' 1',
      '1 ',
      'Wed, 21 Oct 2015 07:28:00 GMT',
      'Bearer header-secret',
      'https://example.com/path?token=query-secret',
      '9999999999999999999999999999999999999999',
    ]) {
      final failure = withRetryAfter(invalid);
      expect(failure.headers, isEmpty, reason: invalid);
      expect(failure.retryAfter, isNull, reason: invalid);
    }
  });
}

void _expectSafeTransportFailure(Object? failure, String unsafeUrl) {
  expect(failure, isA<AITransportException>());
  final transport = failure! as AITransportException;
  expect(transport.message, 'Network request failed');
  expect(transport.toString(), 'AITransportException: Network request failed');
  for (final sensitive in [unsafeUrl, 'query-secret', 'sk-secret']) {
    expect(transport.message, isNot(contains(sensitive)));
    expect(transport.toString(), isNot(contains(sensitive)));
  }
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
