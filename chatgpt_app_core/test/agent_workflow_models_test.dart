import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/personal_memory_test_support.dart';

// 本文件的真实HTTP仅访问回环服务，不安装widget测试的HTTP代理。
void main() {
  late HttpServer server;
  late AISettings settings;
  late PersonalMemoryTestAccount auth;
  late String oldHost;
  late bool oldHttps;
  late int epoch, restore;
  late List<Map<String, dynamic>> posts;
  late Future<void> Function(HttpRequest) respond;
  final evidence = <Map<String, dynamic>>[];
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'a',
      currentAccount: () => auth.account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => restore);
  WorkflowModelProfile profile(bool backend) => backend
      ? WorkflowModelProfile(
          'backend', 'backend', ModelCatalog.backendAll().first.id)
      : const WorkflowModelProfile('local', 'fixture', 'analysis');
  AgentWorkflowModels models(AgentWorkflowScope s,
          {ChatService Function(AISettings)? create}) =>
      AgentWorkflowModels(s,
          settings: () async => settings.clone(),
          visibleSettings: () => settings,
          createService: create);
  Future<Object?> request(
          ChatService service, bool stream, ChatRequestOptions options) =>
      stream
          ? service
              .chatStreamEventsWithOptions(
                  prompt: '合成任务', history: [], options: options)
              .toList()
          : service.chatWithUsageWithOptions(
              prompt: '合成任务', history: [], options: options);
  Future<void> success(HttpRequest r) async {
    final stream =
        posts.last['stream'] == true || r.uri.path.endsWith('/stream');
    if (stream) {
      r.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      r.response.write('data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '合成回复'}
              }
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          })}\n\ndata: [DONE]\n\n');
    } else {
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(r.uri.path.startsWith('/uapi/')
          ? {
              'code': 0,
              'data': {
                'content': '合成回复',
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
              }
            }
          : {
              'choices': [
                {
                  'message': {'content': '合成回复'}
                }
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
            }));
    }
    await r.response.close();
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    auth = PersonalMemoryTestAccount('a')..install();
    epoch = 1;
    restore = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = '${server.address.host}:${server.port}';
    BackendConfig.useHttps = false;
    settings = AISettings.defaults()
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '合成服务',
            type: 'openai',
            apiKey: 'synthetic-key',
            apiHost: 'http://${server.address.host}:${server.port}/v1',
            enabled: true,
            models: [AiModel(id: 'analysis')])
      ]
      ..activeProviderId = 'fixture';
    settings.setActiveModel('analysis');
    posts = [];
    respond = success;
    server.listen((r) async {
      posts.add((jsonDecode(await utf8.decoder.bind(r).join()) as Map)
          .cast<String, dynamic>());
      await respond(r);
    });
  });
  tearDown(() async {
    evidence.add({'case': evidence.length + 1, 'posts': posts});
    await server.close(force: true);
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    AISettingsDao.resetSecureStateForTest();
    LoginSdkConfig.reset();
  });
  tearDownAll(() async {
    const path = String.fromEnvironment('CHATAI_WORKFLOW_PAYLOAD_PATH');
    if (path.isNotEmpty) await File(path).writeAsString(jsonEncode(evidence));
  });
  test('配置价格仅在实际dispatch后估算；未配置/零价格保持未知', () async {
    final p = profile(false);
    final m = models(scope());
    expect(m.estimateCost(p, 10, 5), null);
    const rate = UsageCostRate(inputCostPer1K: 10, outputCostPer1K: 20);
    settings.usageCostConfig =
        const UsageCostConfig(overrides: {'fixture/analysis': rate});
    await request(
        await m.service(p), false, const ChatRequestOptions(maxAutoRetries: 0));
    expect(m.estimateCost(p, 10, 5),
        rate.costFor(promptTokens: 10, completionTokens: 5));
    settings.usageCostConfig = const UsageCostConfig.zero();
    await request(
        await m.service(p), false, const ChatRequestOptions(maxAutoRetries: 0));
    expect(m.estimateCost(p, 10, 5), null);
    expect(posts, hasLength(2));
  });
  test('配置引用严格匹配，不借activeProvider兜底；持久引用不含凭据', () async {
    final m = models(scope());
    expect(await m.available(profile(false)), true);
    for (final invalid in [
      const WorkflowModelProfile('local', 'gone', 'analysis'),
      const WorkflowModelProfile('local', 'fixture', 'gone'),
      const WorkflowModelProfile('backend', 'fixture', 'analysis'),
    ]) {
      expect(await m.available(invalid), false);
    }
    settings.providers.single.enabled = false;
    expect(await m.available(profile(false)), false);
    settings.providers.single.enabled = true;
    settings.providers.single.apiKey = '';
    expect(await m.available(profile(false)), false);
    expect(
        jsonEncode(profile(false).toJson()), isNot(contains('synthetic-key')));
  });
  test('默认resolver从捕获账号安全存储读取，UI未保存配置变更也拒绝旧client', () async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    AISettingsDao.resetSecureStateForTest();
    final store = _Secrets();
    AISettingsDao.configureSecretStore(store);
    await AISettingsDao.saveFor('a', settings);
    final m = AgentWorkflowModels(scope(), visibleSettings: () => settings);
    expect(await m.available(profile(false)), true);
    expect(HiCache.getInstance().prefs?.getString(AISettingsDao.keyFor('a')),
        isNot(contains('synthetic-key')));
    settings.providers.single.apiKey = 'different-synthetic-key';
    expect(await m.available(profile(false)), false);
    final unavailable = AgentWorkflowModels(scope(),
        settings: () async => throw const AISecretsUnavailableException('a'),
        visibleSettings: () => null);
    expect(await unavailable.available(profile(false)), false);
  });
  for (final backend in [false, true]) {
    for (final stream in [false, true]) {
      final label =
          '${backend ? 'backend' : 'direct'} ${stream ? 'stream' : 'nonstream'}';
      test('$label 最末发送保留独立动态消息与预算hook，强制输出上限', () async {
        var reservations = 0;
        final chat = await models(scope()).service(profile(backend));
        await request(
            chat,
            stream,
            ChatRequestOptions(
                maxAutoRetries: 0,
                maxOutputTokensOverride: 2048,
                messagesForAttempt: (messages) async => [
                      ...messages,
                      {'role': 'system', 'content': '合成动态数据'}
                    ],
                beforeDispatch: (messages) async {
                  expect(jsonEncode(messages), contains('合成动态数据'));
                  reservations++;
                }));
        expect(reservations, 1);
        expect(posts.length, 1);
        expect(posts.single['model'], profile(backend).modelId);
        expect(posts.single['max_tokens'], 2048);
        expect(jsonEncode(posts.single), contains('合成动态数据'));
      });
      test('$label 503后配置撤销不发第二次POST，不改换模型', () async {
        var reservations = 0;
        respond = (r) async {
          r.response.statusCode = 503;
          await r.response.close();
        };
        final chat = await models(scope()).service(profile(backend));
        await expectLater(
            request(
                chat,
                stream,
                ChatRequestOptions(
                    maxAutoRetries: 1,
                    retryBaseDelay: const Duration(milliseconds: 1),
                    onRetry: (_) {
                      settings.providers.single.enabled = false;
                      restore++;
                    },
                    beforeDispatch: (_) async {
                      reservations++;
                    })),
            throwsA(anything));
        expect(posts.length, 1);
        expect(reservations, 1);
      });
      test('$label 组装等待中账号/restore/取消与预算拒绝均零POST', () async {
        for (final invalidate in [
          'account',
          'restore',
          'cancel',
          'budget',
          'config'
        ]) {
          final s = scope();
          final gate = Completer<void>();
          final entered = Completer<void>();
          final chat = await models(s,
                  create: (value) =>
                      _GatedChat(ChatService.from(value), gate.future, entered))
              .service(profile(backend));
          var reserved = 0;
          final outcome = expectLater(
              request(
                  chat,
                  stream,
                  ChatRequestOptions(
                      maxAutoRetries: 0,
                      beforeDispatch: (_) async {
                        reserved++;
                        if (invalidate == 'budget') {
                          throw const WorkflowStale('预算拒绝');
                        }
                      })),
              throwsA(anything));
          await entered.future.timeout(const Duration(seconds: 3));
          switch (invalidate) {
            case 'account':
              auth.account = 'b';
            case 'restore':
              restore++;
            case 'cancel':
              s.cancel();
            case 'config':
              settings.temperature = (settings.temperature ?? 0.7) + 0.1;
          }
          gate.complete();
          await outcome;
          expect(posts, isEmpty, reason: invalidate);
          expect(reserved, invalidate == 'budget' ? 1 : 0, reason: invalidate);
          auth.account = 'a';
          settings.providers.single.apiKey = 'synthetic-key';
        }
      });
    }
  }
}

class _Secrets implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _GatedChat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService,
        OptionsAwareChatService {
  final ChatService inner;
  final Future<void> gate;
  final Completer<void> entered;
  _GatedChat(this.inner, this.gate, this.entered);
  @override
  ModelCapabilities get capabilities => inner.capabilities;
  Future<void> wait() async {
    entered.complete();
    await gate;
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    await wait();
    return inner.chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: options);
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await wait();
    yield* inner.chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
