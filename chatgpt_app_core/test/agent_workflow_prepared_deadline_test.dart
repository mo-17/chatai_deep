import 'support/owned_test_directory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
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

class DeadlineClient extends MockClient {
  final void Function() onClose;
  DeadlineClient(super.fn, this.onClose);
  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B4_ROOT',
    nonceKey: 'R3B4_NONCE',
    legacyPrefix: '/tmp/chatai-r3b4-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PairTokens tokens;
  late String oldHost;
  late bool oldHttps;
  final evidence = <Map<String, Object?>>[];
  setUpAll(() {
    root = ownedFixture.directory;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'deadline.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'deadline.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
  });
  tearDown(() {
    expect(tokens.clears, 0);
    LoginSdkConfig.reset();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() {
    File('${root.path}/deadline-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'cases': evidence.length,
      'syntheticTransport': true,
      'actualTimers': true,
      'allResponseTimersSettled': true
    }));
  });

  Future<void> runCase(String name,
      {required Duration? deadline,
      required Duration responseDelay,
      required bool shouldTimeout}) async {
    final pair = BackendSelection.pair(
        providerCode: 'A',
        modelId: 'same',
        accountHash: 'account-a',
        origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
    final settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = pair
      ..backendModel = pair.modelId!;
    var posts = 0, gets = 0, retries = 0, creates = 0, closes = 0;
    final responseDone = Completer<void>();
    final bodies = <Map<String, dynamic>>[];
    Object? outcome;
    final watch = Stopwatch();
    await http.runWithClient(() async {
      try {
        final models = AgentWorkflowModels(
            AgentWorkflowScope(
                accountHash: 'account-a',
                currentAccount: () => tokens.account,
                currentLoginEpoch: () => 1,
                currentRestoreRevision: () =>
                    BackupService.agentExecutionRevision),
            settings: () async => settings.clone(),
            visibleSettings: () => settings,
            createService: (s) {
              creates++;
              return BackendChatService(s);
            });
        final service =
            await models.prepareBackend(WorkflowModelProfile.backend(pair));
        watch.start();
        try {
          outcome = await service.chatWithUsageWithOptions(
              prompt: 'synthetic',
              history: [],
              options: ChatRequestOptions(
                  nonStreamingTimeout: deadline,
                  maxAutoRetries: 0,
                  onRetry: (_) => retries++));
        } catch (e) {
          outcome = e;
        }
        watch.stop();
      } finally {
        // 超时之后也等待已启动的合成响应计时器结束，避免跨测试残留。
        if (posts > 0) await responseDone.future;
        evidence.add({
          'case': name,
          'deadlineMs': deadline?.inMilliseconds,
          'responseDelayMs': responseDelay.inMilliseconds,
          'elapsedMs': watch.elapsedMilliseconds,
          'outcome': outcome is ChatTransportException
              ? (outcome as ChatTransportException).safeCode
              : outcome is ChatCompletionResult
                  ? 'success'
                  : 'unexpected',
          'posts': posts,
          'gets': gets,
          'retries': retries,
          'transportCreates': creates,
          'clientCloses': closes,
          'responseSettled': posts == 0 || responseDone.isCompleted,
          'logout': tokens.clears
        });
      }
    },
        () => DeadlineClient((request) async {
              expect(request.url.host, 'deadline.synthetic.invalid');
              expect(request.headers['Authorization'], 'Bearer synthetic-jwt');
              if (request.method != 'POST') {
                gets++;
                throw StateError('unexpected synthetic GET');
              }
              expect(request.url.path, '/uapi/chat/completions');
              expect(request.followRedirects, false);
              posts++;
              bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
              try {
                await Future<void>.delayed(responseDelay);
                return http.Response(
                    jsonEncode({
                      'code': 0,
                      'data': {'content': 'ok'}
                    }),
                    200);
              } finally {
                if (!responseDone.isCompleted) responseDone.complete();
              }
            }, () => closes++));
    expect(posts, 1);
    expect(gets, 0);
    expect(retries, 0);
    expect(creates, 1);
    expect(closes, 1);
    expect(bodies.single['providerCode'], 'A');
    expect(bodies.single['model'], 'same');
    if (shouldTimeout) {
      expect(outcome, isA<ChatTransportException>());
      expect((outcome as ChatTransportException).safeCode, 'timeout');
      expect(watch.elapsed, lessThan(responseDelay));
    } else {
      expect(outcome, isA<ChatCompletionResult>());
      expect((outcome as ChatCompletionResult).content, 'ok');
      expect(watch.elapsed, greaterThanOrEqualTo(responseDelay));
      if (deadline != null) expect(watch.elapsed, lessThan(deadline));
    }
  }

  test('long20s deadline accepts actual delayed16s response once', () async {
    await runCase('long',
        deadline: const Duration(seconds: 20),
        responseDelay: const Duration(seconds: 16),
        shouldTimeout: false);
  });
  test('short40ms deadline times out before delayed150ms response once',
      () async {
    await runCase('short',
        deadline: const Duration(milliseconds: 40),
        responseDelay: const Duration(milliseconds: 150),
        shouldTimeout: true);
  });
  test('null deadline keeps existing fast-response contract once', () async {
    await runCase('null',
        deadline: null,
        responseDelay: const Duration(milliseconds: 30),
        shouldTimeout: false);
  });
}
