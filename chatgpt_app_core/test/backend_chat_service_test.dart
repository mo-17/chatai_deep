import 'dart:convert';
import 'dart:io';

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
      bodies.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      if (request.uri.path.endsWith('/stream')) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
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
