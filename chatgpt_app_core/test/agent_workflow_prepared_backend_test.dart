import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_usage_identity.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

Future<ChatService> prepared(AgentWorkflowModels m, WorkflowModelProfile p,
    {Future<void>? abort}) async {
  try {
    return await (m as dynamic).prepareBackend(p, abortTrigger: abort)
        as ChatService;
  } on NoSuchMethodError {
    return m.service(p);
  }
}

Future<Object?> failure(Future<Object?> f) async {
  try {
    await f;
    return null;
  } catch (e) {
    return e;
  }
}

class CountedBackend
    implements
        ChatService,
        BackendSelectionPreparingChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService,
        OptionsAwareChatService {
  final ChatService actual;
  final void Function() onPrepare;
  final Future<void>? gate;
  final Completer<void>? entered;
  final BackendSelection? wrong;
  CountedBackend(this.actual, this.onPrepare,
      {this.gate, this.entered, this.wrong});
  @override
  ModelCapabilities get capabilities => actual.capabilities;
  @override
  Future<BackendSelection> prepareBackendSelection(
      {Future<void>? abortTrigger}) async {
    onPrepare();
    final p = await (actual as BackendSelectionPreparingChatService)
        .prepareBackendSelection(abortTrigger: abortTrigger);
    if (entered?.isCompleted == false) {
      entered!.complete();
    }
    if (gate != null) {
      await gate!;
    }
    return wrong ?? p;
  }

  @override
  void verifyPreparedBackendSelection(BackendSelection p) =>
      (actual as BackendSelectionPreparingChatService)
          .verifyPreparedBackendSelection(p);
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          required ChatRequestOptions options}) =>
      actual.chatWithUsageWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: options);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const [],
          required ChatRequestOptions options}) =>
      actual.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages,
          options: options);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError('unused');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PairTokens tokens;
  late AISettings settings;
  late AgentWorkflowModels models;
  late String oldHost;
  late bool oldHttps;
  int gets = 0, loads = 0, creates = 0, prepares = 0, hooks = 0, epoch = 0;
  bool empty = false, unknownLoad = false;
  Completer<void>? settingsGate,
      settingsEntered,
      prepareGate,
      prepareEntered,
      hookGate,
      hookEntered;
  BackendSelection? wrong;
  final posts = <Map<String, dynamic>>[], evidence = <Map<String, Object?>>[];
  BackendSelection pair(String code,
          {String? origin, String account = 'account-a'}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: 'same',
          accountHash: account,
          origin: origin ?? BackendConfig.buildUri('/uapi/ai/catalog').origin);
  WorkflowModelProfile profile(String code,
          {String? origin, String account = 'account-a'}) =>
      WorkflowModelProfile.backend(
          pair(code, origin: origin, account: account));
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'account-a',
      currentAccount: () => tokens.account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => BackupService.agentExecutionRevision);
  AgentWorkflowModels build() => AgentWorkflowModels(scope(),
      settings: () async {
        loads++;
        if (settingsEntered?.isCompleted == false) {
          settingsEntered!.complete();
        }
        if (settingsGate != null) {
          await settingsGate!.future;
        }
        if (unknownLoad) {
          throw StateError('synthetic secret SQL token');
        }
        return settings.clone();
      },
      visibleSettings: () => settings,
      createService: (s) {
        creates++;
        return CountedBackend(ChatService.from(s), () => prepares++,
            gate: prepareGate?.future, entered: prepareEntered, wrong: wrong);
      });
  Future<Object?> request(ChatService c,
          {bool stream = false, ChatRequestOptions? options}) async =>
      stream
          ? await c
              .chatStreamEventsWithOptions(
                  prompt: 'synthetic',
                  history: [],
                  options:
                      options ?? const ChatRequestOptions(maxAutoRetries: 0))
              .toList()
          : await c.chatWithUsageWithOptions(
              prompt: 'synthetic',
              history: [],
              options: options ?? const ChatRequestOptions(maxAutoRetries: 0));
  Future<void> mocked(Future<void> Function() body) =>
      http.runWithClient(() async {
        try {
          await ModelCatalog.refreshFromBackend();
          models = build();
          await body();
        } finally {
          for (final c in [settingsGate, prepareGate, hookGate]) {
            if (c?.isCompleted == false) {
              c!.complete();
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
          () => MockClient((r) async {
                expect(r.url.host, 'prepared.synthetic.invalid');
                expect(r.headers['Authorization'], 'Bearer synthetic-jwt');
                if (r.url.path == '/uapi/ai/catalog') {
                  return http.Response(
                      jsonEncode({
                        'code': 0,
                        'data': {
                          'providers': [
                            for (final c
                                in empty ? <String>[] : ['A', 'B', 'deepseek'])
                              {'code': c, 'displayName': 'Synthetic $c'}
                          ],
                          'models': [
                            for (final c
                                in empty ? <String>[] : ['A', 'B', 'deepseek'])
                              {
                                'providerCode': c,
                                'modelId': 'same',
                                'displayName': 'same',
                                'supportsTool': c == 'A',
                                'supportsVision': c == 'A',
                                'supportsReasoning': false,
                                'supportsPdf': false
                              }
                          ]
                        }
                      }),
                      200);
                }
                if (r.url.path == '/uapi/ai/model-selection') {
                  gets++;
                  throw StateError(
                      'modern preparation must not resolve legacy');
                }
                expect(r.method, 'POST');
                final body = jsonDecode(r.body) as Map<String, dynamic>;
                posts.add(body);
                if (r.url.path.endsWith('/stream')) {
                  return http.Response(
                      'data: ${jsonEncode({
                            'choices': [
                              {
                                'delta': {'content': 'ok'}
                              }
                            ]
                          })}\n\ndata: [DONE]\n\n',
                      200,
                      headers: {
                        'content-type': 'text/event-stream; charset=utf-8'
                      });
                }
                return http.Response(
                    jsonEncode({
                      'code': 0,
                      'data': {
                        'content': 'ok',
                        'usage': {'prompt_tokens': 10, 'completion_tokens': 2}
                      }
                    }),
                    200);
              }));
  setUpAll(() {
    root = Directory(Platform.environment['R3B4_ROOT']!);
    expect(root.path,
        '/tmp/chatai-r3b4-owned-${Platform.environment['R3B4_NONCE']}');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': Platform.environment['R3B4_NONCE']});
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'prepared.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'prepared.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
    settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = pair('A')
      ..backendModel = 'same';
    epoch = 1;
    gets = loads = creates = prepares = hooks = 0;
    empty = unknownLoad = false;
    posts.clear();
    settingsGate = settingsEntered =
        prepareGate = prepareEntered = hookGate = hookEntered = null;
    wrong = null;
  });
  tearDown(() {
    evidence.add({
      'posts': posts.length,
      'resolverGets': gets,
      'loads': loads,
      'creates': creates,
      'prepares': prepares,
      'hooks': hooks,
      'logout': tokens.clears
    });
    expect(tokens.clears, 0);
    LoginSdkConfig.reset();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() {
    File('${root.path}/prepared-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'cases': evidence.length,
      'httpSynthetic': true,
      'resolverGET0': evidence.every((e) => e['resolverGets'] == 0)
    }));
  });
  for (final stream in [false, true]) {
    test(
        'same model A/B ${stream ? 'stream' : 'nonstream'} pins exact pair/capabilities',
        () async => mocked(() async {
              final a = await prepared(models, profile('A'));
              final b = await prepared(models, profile('B'));
              expect(a.capabilities.tool, true);
              expect(b.capabilities.tool, false);
              expect(a.capabilities.image, true);
              expect(b.capabilities.image, false);
              await request(a, stream: stream);
              await request(b, stream: stream);
              expect(posts.map((p) => p['providerCode']).toList(), ['A', 'B']);
              expect(posts.every((p) => p['model'] == 'same'), true);
              expect(creates, 2);
              expect(prepares, 2);
              expect(gets, 0);
            }));
  }
  test(
      'same pair shared preparation and fixed transport despite global switch',
      () async => mocked(() async {
            settingsGate = Completer();
            settingsEntered = Completer();
            final a = prepared(models, profile('A'));
            final b = prepared(models, profile('A'));
            await settingsEntered!.future;
            settingsGate!.complete();
            final services = await Future.wait([a, b]);
            expect(identical(services[0], services[1]), true);
            settings.backendSelection = pair('B');
            await request(services[0]);
            await request(services[1], stream: true);
            expect(creates, 1);
            expect(loads, 1);
            expect(prepares, 1);
            expect(posts.every((p) => p['providerCode'] == 'A'), true);
          }));
  test(
      'one cancelled waiter does not cancel other same-pair preparation',
      () async => mocked(() async {
            settingsGate = Completer();
            settingsEntered = Completer();
            final abort = Completer<void>();
            final one =
                failure(prepared(models, profile('A'), abort: abort.future));
            final two = prepared(models, profile('A')).then<Object>(
                (service) => service,
                onError: (Object e, StackTrace _) => e);
            await settingsEntered!.future;
            abort.complete();
            final promptlyCancelled = await Future.any<bool>([
              one.then((_) => true),
              Future<bool>.delayed(
                  const Duration(milliseconds: 50), () => false)
            ]);
            expect(promptlyCancelled, true,
                reason: 'bounded cancellation observer, not test timeout');
            expect(await one, isA<WorkflowStale>());
            settingsGate!.complete();
            final c = await two;
            expect(c, isA<ChatService>());
            await request(c as ChatService);
            expect(creates, 1);
            expect(loads, 1);
            expect(posts.single['providerCode'], 'A');
          }));
  test(
      'preparation failure memoized and unknown error generic, no model calls',
      () async => mocked(() async {
            unknownLoad = true;
            expect(await failure(prepared(models, profile('A'))),
                isA<WorkflowConfigurationMissing>());
            expect(await failure(prepared(models, profile('A'))),
                isA<WorkflowConfigurationMissing>());
            expect(loads, 1);
            expect(creates, 0);
            expect(posts, isEmpty);
          }));
  for (final bad in ['origin', 'account', 'legacy']) {
    test(
        'explicit bad $bad profile never falls back or resolves',
        () async => mocked(() async {
              final p = bad == 'legacy'
                  ? const WorkflowModelProfile('backend', 'backend', 'same')
                  : profile('A',
                      origin: bad == 'origin' ? 'https://other.invalid' : null,
                      account: bad == 'account' ? 'account-b' : 'account-a');
              expect(await failure(prepared(models, p)), isNotNull);
              expect(creates, 0);
              expect(posts, isEmpty);
              expect(gets, 0);
            }));
  }
  test(
      'backend rate keys isolate A/B and do not consume local deepseek price',
      () async => mocked(() async {
            const local =
                UsageCostRate(inputCostPer1K: 100, outputCostPer1K: 100);
            const aRate = UsageCostRate(inputCostPer1K: 1, outputCostPer1K: 2);
            const bRate = UsageCostRate(inputCostPer1K: 3, outputCostPer1K: 4);
            settings.usageCostConfig = UsageCostConfig(overrides: {
              'deepseek/*': local,
              '${backendUsageProviderId(pair('A'))}/*': aRate,
              '${backendUsageProviderId(pair('B'))}/*': bRate
            });
            await prepared(models, profile('A'));
            await prepared(models, profile('B'));
            await prepared(models, profile('deepseek'));
            expect(models.estimateCost(profile('A'), 1000, 1000),
                aRate.costFor(promptTokens: 1000, completionTokens: 1000));
            expect(models.estimateCost(profile('B'), 1000, 1000),
                bRate.costFor(promptTokens: 1000, completionTokens: 1000));
            expect(
                models.estimateCost(profile('deepseek'), 1000, 1000), isNull);
            expect(
                backendUsageProviderId(pair('A')),
                isNot(backendUsageProviderId(
                    pair('A', origin: 'https://other.invalid'))));
            expect(posts, isEmpty);
          }));
  for (final change in [
    'account',
    'token',
    'origin',
    'epoch',
    'restore',
    'storage'
  ]) {
    test(
        'settings await $change cannot mint transport under new scope',
        () async => mocked(() async {
              settingsGate = Completer();
              settingsEntered = Completer();
              final f = failure(prepared(models, profile('A')));
              await settingsEntered!.future;
              switch (change) {
                case 'account':
                  tokens.account = 'account-b';
                case 'token':
                  tokens.token = 'different';
                case 'origin':
                  BackendConfig.host = 'other.invalid';
                case 'epoch':
                  ModelCatalog.resetExecutionForTest();
                case 'restore':
                  BackupService.agentExecutionRevision++;
                case 'storage':
                  LoginSdkConfig.install(LoginSdkConfig(
                      baseUrl: 'prepared.synthetic.invalid',
                      headerProvider: () async => {},
                      syncHeaders: () => {},
                      routes: LoginRoutes.imooc,
                      responseAdapter: ImoocResponseAdapter(),
                      storage: PairTokens(),
                      onLogoutNavigate: () {}));
              }
              settingsGate!.complete();
              expect(await f, isNotNull);
              expect(creates, 0);
              expect(posts, isEmpty);
            }));
  }
  test(
      'actual transport prepare final await scope change refuses returned service',
      () async => mocked(() async {
            prepareGate = Completer();
            prepareEntered = Completer();
            final f = failure(prepared(models, profile('A')));
            final reached = await Future.any<bool>([
              prepareEntered!.future.then((_) => true),
              f.then((_) => false)
            ]);
            expect(reached, true,
                reason:
                    'actual transport preparation reached before scope change');
            BackendConfig.host = 'other.invalid';
            prepareGate!.complete();
            expect(await f, isNotNull);
            expect(creates, 1);
            expect(posts, isEmpty);
          }));
  test(
      'actual transport prepared wrong pair never accepted',
      () async => mocked(() async {
            wrong = pair('B');
            expect(await failure(prepared(models, profile('A'))),
                isA<WorkflowConfigurationMissing>());
            expect(posts, isEmpty);
          }));
  for (final change in ['origin', 'cancel', 'restore']) {
    test(
        'last beforeDispatch await $change has zero POST and no retry',
        () async => mocked(() async {
              final c = await prepared(models, profile('A'));
              hookGate = Completer();
              hookEntered = Completer();
              final abort = Completer<void>();
              final f = failure(request(c,
                  options: ChatRequestOptions(
                      maxAutoRetries: 0,
                      abortTrigger: abort.future,
                      beforeDispatch: (_) async {
                        hooks++;
                        hookEntered!.complete();
                        await hookGate!.future;
                      })));
              await hookEntered!.future;
              switch (change) {
                case 'origin':
                  BackendConfig.host = 'other.invalid';
                case 'cancel':
                  abort.complete();
                case 'restore':
                  BackupService.agentExecutionRevision++;
              }
              hookGate!.complete();
              expect(await f, isNotNull);
              expect(posts, isEmpty);
              expect(hooks, 1);
            }));
  }
  test(
      'successful empty current catalog revokes prepared exact pair without replacement',
      () async => mocked(() async {
            final c = await prepared(models, profile('A'));
            empty = true;
            await ModelCatalog.refreshFromBackend();
            expect(await failure(request(c)), isNotNull);
            expect(posts, isEmpty);
            expect(creates, 1);
          }));
  test(
      'model set origin is shared across pairs and no scope re-sign after A ready',
      () async => mocked(() async {
            await prepared(models, profile('A'));
            tokens.token = 'different';
            expect(await failure(prepared(models, profile('B'))), isNotNull);
            expect(creates, 1);
            expect(posts, isEmpty);
          }));
  test(
      'normal modern service and available remain blocked pending consumer integration',
      () async => mocked(() async {
            await prepared(models, profile('A'));
            expect(await models.available(profile('A')), false);
            expect(await failure(models.service(profile('A'))),
                isA<WorkflowConfigurationMissing>());
            expect(posts, isEmpty);
          }));
}
