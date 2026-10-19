import 'support/fake_composer_chat.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:chatgpt_app_core/pages/usage_stats_page.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens, PairHttpOverrides;

class _Preparation implements ConversationTurnPreparation {
  final Future<PreparedConversationTurn> Function(ConversationGenerationRun)
      prepareRun;
  _Preparation(this.prepareRun);
  @override
  Future<PreparedConversationTurn> prepare(ConversationGenerationRun run) =>
      prepareRun(run);
  @override
  Future<void> release() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory owned;
  HttpOverrides? previous;
  late String oldHost;
  late bool oldHttps;
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late UsageDao usage;
  late HttpServer server, otherServer;
  late PairTokens tokens;
  late AISettings selected;
  late ConversationGenerationService service;
  late int rowId;
  int serial = 0, created = 100, probes = 0;
  int probeStatus = 200;
  bool search = false, tools = false;
  List<Map<String, Object>> catalogRows = [];
  final requests = <Map<String, dynamic>>[];
  final evidence = <Object>[], cleanup = <Object>[];
  Completer<void>? probeEntered, probeGate;
  String origin() => BackendConfig.buildUri('/uapi/ai/catalog').origin;
  BackendSelection pair(String code) => BackendSelection.pair(
      providerCode: code,
      modelId: 'plain',
      accountHash: 'account-a',
      origin: origin());
  Map<String, Object> row(String code) => {
        'providerCode': code,
        'modelId': 'plain',
        'displayName': 'plain',
        'supportsTool': code == 'B',
        'supportsPdf': code == 'A',
        'supportsVision': false,
        'supportsReasoning': false
      };
  Future<void> handler(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (request.method == 'GET') {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/uapi/ai/catalog') {
        request.response.write(jsonEncode({
          'code': 0,
          'data': {'models': catalogRows}
        }));
      } else {
        probes++;
        expect(request.uri.path, '/uapi/ai/model-selection');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer synthetic-jwt');
        if (probeEntered?.isCompleted == false) probeEntered!.complete();
        if (probeGate != null) await probeGate!.future;
        request.response.statusCode = probeStatus;
        request.response.write(jsonEncode(probeStatus == 200
            ? {
                'code': 0,
                'data': {
                  'providerCode': 'B',
                  'modelId': request.uri.queryParameters['modelId']
                }
              }
            : {'safeCode': 'model_ambiguous', 'message': 'synthetic-hidden'}));
      }
      await request.response.close();
      return;
    }
    expect(request.method, 'POST');
    final body = jsonDecode(raw) as Map<String, dynamic>;
    requests.add({
      'origin': 'http://127.0.0.1:${request.connectionInfo!.localPort}',
      ...body
    });
    final isClassification = search && requests.length == 1;
    if (request.uri.path.endsWith('/stream')) {
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      final firstTool = tools &&
          body['extraMessages'] == null &&
          !(body['messages'] as List).any((m) => m['role'] == 'tool');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': firstTool
                    ? {
                        'tool_calls': [
                          {
                            'index': 0,
                            'id': 'call1',
                            'type': 'function',
                            'function': {
                              'name': 'fixture_read',
                              'arguments': '{}'
                            }
                          }
                        ]
                      }
                    : {'content': 'FINAL'}
              }
            ]
          })}\n\n');
      request.response.write('data: ${jsonEncode({
            'choices': [],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          })}\n\n');
      request.response.write('data: [DONE]\n\n');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'code': 0,
        'data': {
          'content': isClassification
              ? ' {"needSearch":false,"queries":[]} '
              : 'FINAL',
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
        }
      }));
    }
    await request.response.close();
  }

  ConversationGenerationRun start(
          {bool stream = false, ConversationTurnPreparation? preparation}) =>
      service.start(
          scope: ConversationGenerationScope(account: 'account-a'),
          dao: dao,
          profile: ConversationGenerationProfile(selected, 'account-a',
              loadSettings: () async => selected,
              visibleSettings: () => selected),
          input: ConversationGenerationInput(
              cid: 1,
              conversationRowId: rowId,
              user: MessageModel(
                  ownerType: OwnerType.sender,
                  content: 'SYNTHETIC_INPUT',
                  createdAt: ++created),
              stream: stream,
              webSearch: search),
          preparation: preparation ??
              ReadyConversationTurn(
                  PreparedConversationTurn(prompt: 'SYNTHETIC_INPUT')));
  setUpAll(() async {
    owned = Directory(Platform.environment['R3A2_ROOT']!);
    final nonce = Platform.environment['R3A2_NONCE']!;
    expect(owned.path, '/tmp/chatai-r3a2-owned-$nonce');
    expect(
        jsonDecode(
            File('${owned.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    previous = HttpOverrides.current;
    HttpOverrides.global = PairHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    sqfliteFfiInit();
  });
  setUp(() async {
    await HiCache.getInstance().prefs?.clear();
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    otherServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    otherServer.listen(handler);
    BackendConfig.host = '127.0.0.1:${server.port}';
    BackendConfig.useHttps = false;
    requests.clear();
    probes = 0;
    probeStatus = 200;
    probeEntered = null;
    probeGate = null;
    search = false;
    tools = false;
    catalogRows = [row('A'), row('B'), row('deepseek')];
    await ModelCatalog.refreshFromBackend();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        '${owned.path}/db-${serial++}.sqlite',
        options: OpenDatabaseOptions(singleInstance: false)));
    rowId = (await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 1, title: 'Synthetic', icon: '')))!;
    dao = await ConversationGenerationDao.create(storage);
    usage = await UsageDao.create(storage);
    selected = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendModel = 'plain';
    service = ConversationGenerationService(
        observeApplication: false, createMemory: (_) async => null);
  });
  tearDown(() async {
    if (probeGate?.isCompleted == false) probeGate!.complete();
    for (final run in service.runs) {
      if (run.busy) await run.stop('fixture cleanup');
      await run.finished.timeout(const Duration(seconds: 4));
    }
    service.dispose();
    await storage.db.close();
    await server.close(force: true);
    await otherServer.close(force: true);
    cleanup.add({'sqliteClosed': true, 'listenersClosed': true});
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
  });
  tearDownAll(() {
    HttpOverrides.global = previous;
    File('${owned.path}/generation-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('${owned.path}/cleanup.json').writeAsStringSync(
        jsonEncode({'allClosed': true, 'resources': cleanup}));
  });
  for (final kind in ['nonstream', 'stream', 'search', 'tool']) {
    test(
        'ordinary $kind fixes pair before preparation and all child requests; global change cannot rebind',
        () async {
      search = kind == 'search';
      tools = kind == 'tool';
      if (search) {
        selected.tavilyApiKey = 'synthetic';
        selected.webSearchEnabled = true;
      }
      BackendSelection? atPreparation;
      bool? toolCap;
      final run = start(
          stream: kind == 'stream' || tools,
          preparation: _Preparation((run) async {
            atPreparation = run.profile.settings.backendSelection;
            toolCap = ChatService.capabilitiesFor(run.profile.settings).tool;
            selected = selected.clone()..backendSelection = pair('A');
            return PreparedConversationTurn(
                prompt: 'SYNTHETIC_INPUT',
                tools: tools
                    ? ToolRegistry([
                        ChatTool(
                            name: 'fixture_read',
                            description: '合成只读工具',
                            parameters: {'type': 'object'},
                            execute: (_) async =>
                                const ToolOutcome(content: 'OK'))
                      ])
                    : null);
          }));
      await run.finished.timeout(const Duration(seconds: 5));
      expect(run.stage, ConversationGenerationStage.complete);
      expect(probes, 1);
      expect(atPreparation?.providerCode, 'B');
      expect(toolCap, isTrue);
      expect(run.profile.settings.backendSelection!.providerCode, 'B');
      expect(run.completion!.capabilities.tool, isTrue);
      expect(requests.length, tools || search ? 2 : 1);
      expect(
          requests
              .every((r) => r['providerCode'] == 'B' && r['model'] == 'plain'),
          isTrue);
      final rows = await storage.db.query('tb_usage');
      expect(rows, hasLength(1));
      expect(
          rows.single['providerId'], 'backend:${jsonEncode([origin(), 'B'])}');
      expect(rows.single['estimated'], 0);
      expect(rows.single['modelId'], 'plain');
      evidence.add({
        'kind': kind,
        'probeCount': probes,
        'requests': requests.toList(),
        'usage': rows,
        'prepared': atPreparation?.toSafeJson()
      });
    });
  }
  test(
      'directory removes original pair while same model stays; no later tool dispatch or replacement',
      () async {
    selected.backendSelection = pair('B');
    tools = true;
    final run = start(
        stream: true,
        preparation: _Preparation((run) async => PreparedConversationTurn(
            prompt: 'SYNTHETIC_INPUT',
            tools: ToolRegistry([
              ChatTool(
                  name: 'fixture_read',
                  description: '合成只读工具',
                  parameters: {'type': 'object'},
                  execute: (_) async {
                    catalogRows = [row('A')];
                    await ModelCatalog.refreshFromBackend();
                    return const ToolOutcome(content: 'OK');
                  })
            ]))));
    await run.finished.timeout(const Duration(seconds: 5));
    expect(requests, hasLength(1));
    expect(run.record!.attempts, 1);
    expect(run.profile.visiblyCurrent, isFalse);
    expect(run.profile.settings.backendSelection!.providerCode, 'B');
  });
  test(
      'backend transport without prepared-pair capability fails before journal or model-only call',
      () async {
    service.dispose();
    final fake = FakeComposerChat();
    service = ConversationGenerationService(
        observeApplication: false,
        createMemory: (_) async => null,
        createChat: (_) => fake);
    selected.backendSelection = pair('A');
    final run = start();
    await run.finished.timeout(const Duration(seconds: 5));
    expect(fake.calls, 0);
    expect(run.record, isNull);
    expect(requests, isEmpty);
  });
  test('ambiguous prepare fails before journal/attempt/model POST', () async {
    probeStatus = 409;
    final run = start();
    await run.finished.timeout(const Duration(seconds: 5));
    expect(probes, 1);
    expect(requests, isEmpty);
    expect(run.record, isNull);
    expect(run.profile.settings.backendSelection, isNull);
    expect((await storage.db.query('tb_usage')), isEmpty);
  });
  for (final change in ['token', 'origin', 'cancel']) {
    test('ordinary pending GET $change cannot bind or dispatch', () async {
      probeEntered = Completer();
      probeGate = Completer();
      final run = start();
      await probeEntered!.future.timeout(const Duration(seconds: 3));
      if (change == 'token') tokens.token = 'new-token';
      if (change == 'origin') {
        BackendConfig.host = '127.0.0.1:${otherServer.port}';
      }
      if (change == 'cancel') await run.stop('explicit fixture cancel');
      probeGate!.complete();
      await run.finished.timeout(const Duration(seconds: 5));
      expect(requests, isEmpty);
      expect(run.record, isNull);
      expect(run.profile.settings.backendSelection, isNull);
    });
  }
  test(
      'usage namespace separates providers, origins and local; generic pricing and export preserve historical rows',
      () async {
    selected.usageCostConfig = const UsageCostConfig(
        defaultRate: UsageCostRate(inputCostPer1K: 1),
        overrides: {'deepseek/*': UsageCostRate(inputCostPer1K: 999)});
    final keys = <String>[];
    for (final code in ['A', 'B', 'deepseek']) {
      selected.backendSelection = pair(code);
      final run = start();
      await run.finished.timeout(const Duration(seconds: 5));
      expect(run.stage, ConversationGenerationStage.complete);
      keys.add(
          (await storage.db.query('tb_usage', orderBy: 'id desc', limit: 1))
              .single['providerId'] as String);
    }
    BackendConfig.host = '127.0.0.1:${otherServer.port}';
    ModelCatalog.resetExecutionForTest();
    selected.backendSelection = pair('deepseek');
    final run = start();
    await run.finished.timeout(const Duration(seconds: 5));
    keys.add((await storage.db.query('tb_usage', orderBy: 'id desc', limit: 1))
        .single['providerId'] as String);
    expect(keys.toSet(), hasLength(4));
    expect(keys.every((k) => k.startsWith('backend:')), isTrue);
    for (final legacy in ['deepseek', 'backend', null]) {
      await usage.insert(UsageRecord(
          modelId: 'plain',
          providerId: legacy,
          promptTokens: 10,
          completionTokens: 5,
          createdAt: 500));
    }
    final aggregate = await usage.aggregateByProvider();
    expect(aggregate, hasLength(6));
    final records = await storage.db.query('tb_usage');
    final backend = records.where(
        (r) => (r['providerId'] as String?)?.startsWith('backend:') == true);
    for (final record in backend) {
      final rate = selected.usageCostConfig.rateFor(
          providerId: record['providerId'] as String,
          modelId: record['modelId'] as String);
      expect(rate.inputCostPer1K, 1);
      expect(
          record['cost'],
          closeTo(
              rate.costFor(
                  promptTokens: 10, cachedPromptTokens: 0, completionTokens: 5),
              1e-12));
    }
    final text = UsageStatsExportFormatter.buildText(
        UsageStatsSnapshot(byProvider: aggregate));
    expect(text, contains('后端 deepseek（'));
    expect(text, contains('后端（历史记录）'));
    expect(text, isNot(contains('backend:[')));
    evidence.add({
      'usageKeys': keys,
      'aggregateCount': aggregate.length,
      'export': text
    });
  });
}
