import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  late HttpServer server;
  late String previousHost;
  late bool previousHttps;
  late int requests;
  late Future<void> Function(HttpRequest request) respond;
  const fast = ChatRequestOptions(
      retryBaseDelay: Duration.zero, maxRetryDelay: Duration.zero);

  setUp(() async {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => const {},
        syncHeaders: () => const {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: _Storage(),
        onLogoutNavigate: () {}));
    previousHost = BackendConfig.host;
    previousHttps = BackendConfig.useHttps;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    BackendConfig.host = '${server.address.host}:${server.port}';
    BackendConfig.useHttps = false;
    requests = 0;
    respond = (_) async {};
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      await respond(request);
    });
  });
  tearDown(() async {
    await server.close(force: true);
    BackendConfig.host = previousHost;
    BackendConfig.useHttps = previousHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
  });

  DirectChatService direct() => DirectChatService(ProviderConfig(
      apiKey: 'test-key',
      baseUrl: 'http://${server.address.host}:${server.port}/chat',
      model: 'test-model'));
  BackendChatService backend() => BackendChatService(AISettings.defaults()
    ..mode = AIMode.backend
    ..backendSelection = BackendSelection.pair(
        providerCode: 'deepseek',
        modelId: 'deepseek-chat',
        accountHash: 'guest',
        origin: BackendConfig.buildUri('/uapi/chat/completions').origin));

  for (final viaBackend in [false, true]) {
    for (final streaming in [false, true]) {
      test(
          '${viaBackend ? '代理' : '直连'}${streaming ? '流式' : '非流式'}503重试策略正确且保留结果与usage',
          () async {
        respond = (request) async {
          if (requests == 1) {
            request.response.statusCode = 503;
            request.response.write('SECRET server error');
          } else if (streaming) {
            request.response.headers.contentType =
                ContentType('text', 'event-stream');
            request.response.write(
                'data: {"usage":{"prompt_tokens":12,"completion_tokens":3},"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n');
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(viaBackend
                ? '{"code":0,"data":{"content":"ok","usage":{"prompt_tokens":12,"completion_tokens":3}}}'
                : '{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":12,"completion_tokens":3}}');
          }
          await request.response.close();
        };
        var service =
            viaBackend ? backend() as ChatService : direct() as ChatService;
        if (!viaBackend) {
          final failed = streaming
              ? service
                  .chatStreamEventsWithOptions(
                      prompt: 'test', history: const [], options: fast)
                  .drain<void>()
              : service.chatWithUsageWithOptions(
                  prompt: 'test', history: const [], options: fast);
          await expectLater(
              failed,
              throwsA(isA<ChatTransportException>()
                  .having((e) => e.statusCode, 'status', 503)));
          expect(requests, 1, reason: '直连失败不自动重放；后续调用模拟显式新请求');
          service = direct();
        }
        if (streaming) {
          final events = await service
              .chatStreamEventsWithOptions(
                  prompt: 'test', history: const [], options: fast)
              .toList();
          expect(
              events.where((e) => e.type == StreamEventType.text).single.delta,
              'ok');
          expect(
              events
                  .where((e) => e.type == StreamEventType.usage)
                  .single
                  .promptTokens,
              12);
        } else {
          final result = await service.chatWithUsageWithOptions(
              prompt: 'test', history: const [], options: fast);
          expect(result.content, 'ok');
          expect(result.promptTokens, 12);
        }
        expect(requests, 2);
      });

      test(
          '${viaBackend ? '代理' : '直连'}${streaming ? '流式' : '非流式'}402错误正文断网仍保留余额诊断且不重试',
          () async {
        final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(raw.close);
        raw.listen((socket) {
          requests++;
          var answered = false;
          socket.listen((_) async {
            if (answered) return;
            answered = true;
            socket.add(utf8.encode(
                'HTTP/1.1 402 Payment Required\r\nContent-Type: application/json\r\nContent-Length: 99999\r\nConnection: close\r\n\r\n'
                'SECRET partial error body'));
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
            socket.destroy();
          });
        });
        BackendConfig.host = '${raw.address.host}:${raw.port}';
        final service = viaBackend
            ? backend() as ChatService
            : DirectChatService(ProviderConfig(
                apiKey: 'test-key',
                baseUrl: 'http://${raw.address.host}:${raw.port}/chat',
                model: 'test-model')) as ChatService;
        final request = streaming
            ? service
                .chatStreamEventsWithOptions(
                    prompt: 'test', history: const [], options: fast)
                .drain<void>()
            : service.chatWithUsageWithOptions(
                prompt: 'test', history: const [], options: fast);
        await expectLater(
            request,
            throwsA(isA<ChatTransportException>()
                .having((e) => e.statusCode, 'status', 402)
                .having((e) => e.safeCode, 'code', 'insufficient_balance')
                .having((e) => e.responseStarted, 'success started', false)));
        expect(requests, 1);
      });
    }

    for (final (status, code) in [
      (402, 'insufficient_balance'),
      (404, 'model_not_found'),
      (422, 'invalid_request')
    ]) {
      test('${viaBackend ? '代理' : '直连'}明确$status错误正文脱敏且不重试', () async {
        respond = (request) async {
          request.response.statusCode = status;
          request.response
              .write('SECRET API key response from private endpoint');
          await request.response.close();
        };
        final service =
            viaBackend ? backend() as ChatService : direct() as ChatService;
        Object? error;
        try {
          await service
              .chatStreamEventsWithOptions(
                  prompt: 'test', history: const [], options: fast)
              .drain<void>();
        } catch (value) {
          error = value;
        }
        expect(
            error,
            isA<ChatTransportException>()
                .having((e) => e.safeCode, 'code', code));
        expect(error.toString(), isNot(contains('SECRET')));
        expect(requests, 1);
      });
    }

    test('${viaBackend ? '代理' : '直连'}隐藏工具分片和heartbeat之后断网禁止重放', () async {
      final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(raw.close);
      raw.listen((socket) {
        requests++;
        var answered = false;
        socket.listen((_) async {
          if (answered) return;
          answered = true;
          socket.add(utf8.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 99999\r\nConnection: close\r\n\r\n'
              ': heartbeat\n\ndata: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call1","function":{"name":"write_file","arguments":"{"}}]}}]}\n\n'));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          socket.destroy();
        });
      });
      BackendConfig.host = '${raw.address.host}:${raw.port}';
      final service = viaBackend
          ? backend() as ChatService
          : DirectChatService(ProviderConfig(
              apiKey: 'test-key',
              baseUrl: 'http://${raw.address.host}:${raw.port}/chat',
              model: 'test-model')) as ChatService;
      await expectLater(
          service
              .chatStreamEventsWithOptions(
                  prompt: 'test', history: const [], options: fast)
              .drain<void>(),
          throwsA(isA<ChatTransportException>()
              .having((e) => e.responseStarted, 'received bytes', true)));
      expect(requests, 1);
    });

    test(
        '${viaBackend ? '代理' : '直连'}HTTP200不合法JSON给出decode诊断而不是不明request_failed',
        () async {
      respond = (request) async {
        request.response.write('SECRET malformed response');
        await request.response.close();
      };
      final service =
          viaBackend ? backend() as ChatService : direct() as ChatService;
      await expectLater(
          service.chatWithUsageWithOptions(
              prompt: 'test', history: const [], options: fast),
          throwsA(isA<ChatTransportException>()
              .having((e) => e.safeCode, 'code', 'invalid_response')
              .having(
                  (e) => e.failureStage, 'stage', ChatFailureStage.decode)));
      expect(requests, 1);
    });
  }
}

class _Storage implements TokenStorage {
  @override
  String? readTokenSync() => 'test-jwt';
  @override
  Map<String, dynamic>? readProfileSync() =>
      {'accountHash': 'guest', 'userName': 'guest'};
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Future<void> clear() async {}
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}
