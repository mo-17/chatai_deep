import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PairHttpOverrides extends HttpOverrides {}

class PairTokens implements TokenStorage {
  String account = 'account-a', token = 'synthetic-jwt';
  int clears = 0;
  @override
  Future<void> clear() async {
    clears++;
    token = '';
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() =>
      {'accountHash': account, 'userName': 'synthetic'};
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => token.isEmpty ? null : token;
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    this.token = token;
    account = extras['accountHash']?.toString() ?? account;
  }
}

Future<Object?> errorOf(Future<Object?> value) async {
  try {
    await value;
    return null;
  } catch (e) {
    return e;
  }
}

Future<BackendSelection?> prepare(BackendChatService service) async {
  try {
    return await (service as dynamic).prepareBackendSelection()
        as BackendSelection;
  } on NoSuchMethodError {
    return null;
  } // 旧实际实现没有接点，仅作差分 fixture 兼容。
}

bool pairAvailable(String provider, String model) {
  try {
    return Function.apply(ModelCatalog.backendProfileAvailable, [model],
        {#account: 'account-a', #providerCode: provider}) as bool;
  } on NoSuchMethodError {
    return ModelCatalog.backendProfileAvailable(model, account: 'account-a');
  }
}

String keyOf(ModelOption option) {
  try {
    return (option as dynamic).pairKey as String;
  } on NoSuchMethodError {
    return option.id;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late PairTokens tokens;
  late String oldHost;
  late bool oldHttps;
  late Directory owned;
  HttpOverrides? previousOverrides;
  final resources = <Map<String, Object?>>[];
  late List<Map<String, dynamic>> posts;
  int probes = 0;
  int catalogRequests = 0;
  String resolvedProvider = 'A';
  int probeStatus = 200;
  String probeCode = 'model_unavailable';
  List<dynamic> catalogRows = [];
  int catalogStatus = 200;
  String? failureCode;
  String failureWire = 'nonstream';
  int failureStatus = 409;
  Completer<void>? probeGate, probeEntered, catalogGate, catalogEntered;
  final gates = <Completer<void>>[];
  Map<String, dynamic> row(String provider, String model,
          {bool vision = false, bool pdf = false}) =>
      {
        'providerCode': provider,
        'modelId': model,
        'displayName': model,
        'supportsVision': vision,
        'supportsPdf': pdf,
        'supportsTool': false,
        'supportsReasoning': false
      };
  setUpAll(() async {
    final nonce = Platform.environment['R3A_HTTP_NONCE']!;
    owned = Directory(Platform.environment['R3A_HTTP_ROOT']!);
    expect(owned.path, '/tmp/chatai-r3a1-http-$nonce');
    expect(
        jsonDecode(
            await File('${owned.path}/fixture-sentinel.json').readAsString()),
        {'nonce': nonce});
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = PairHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
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
    posts = [];
    probes = 0;
    catalogRequests = 0;
    resolvedProvider = 'A';
    probeStatus = 200;
    probeCode = 'model_unavailable';
    catalogRows = [];
    catalogStatus = 200;
    failureCode = null;
    failureWire = 'nonstream';
    failureStatus = 409;
    probeGate = null;
    probeEntered = null;
    catalogGate = null;
    catalogEntered = null;
    gates.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    resources.add({'port': server.port, 'loopback': true, 'closed': false});
    BackendConfig.host = '127.0.0.1:${server.port}';
    BackendConfig.useHttps = false;
    server.listen((request) async {
      try {
        final response = request.response;
        response.headers.contentType = ContentType.json;
        if (request.uri.path == '/uapi/ai/model-selection') {
          probes++;
          expect(request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer synthetic-jwt');
          final provider = resolvedProvider;
          final status = probeStatus;
          final code = probeCode;
          probeEntered?.complete();
          await probeGate?.future;
          response.statusCode = status;
          response.write(jsonEncode(status == 200
              ? {
                  'code': 0,
                  'data': {
                    'providerCode': provider,
                    'modelId': request.uri.queryParameters['modelId']
                  }
                }
              : {'safeCode': code, 'message': 'synthetic-secret SQL token'}));
        } else if (request.uri.path == '/uapi/ai/catalog') {
          catalogRequests++;
          final rows = List<dynamic>.from(catalogRows);
          final status = catalogStatus;
          final gate = catalogGate;
          catalogGate = null;
          catalogEntered?.complete();
          catalogEntered = null;
          await gate?.future;
          response.statusCode = status;
          response.write(jsonEncode({
            'code': 0,
            'data': {'models': rows}
          }));
        } else {
          final body = jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
          posts.add(body);
          if (request.uri.path.startsWith('/direct')) {
            response.write(jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok'}
                }
              ]
            }));
          } else if (failureCode != null) {
            final payload = {
              'safeCode': failureCode,
              'statusCode': failureStatus,
              'message': 'synthetic-secret SQL token'
            };
            if (failureWire == 'sse') {
              response.headers.contentType =
                  ContentType('text', 'event-stream');
              response.write('event: error\ndata: ${jsonEncode(payload)}\n\n');
            } else {
              response.statusCode = failureStatus;
              response.write(jsonEncode(payload));
            }
          } else if (request.uri.path.endsWith('/stream')) {
            response.headers.contentType = ContentType('text', 'event-stream');
            response.write(
                'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n');
          } else {
            response.write(jsonEncode({
              'code': 0,
              'data': {'content': 'ok'}
            }));
          }
        }
        await response.close();
      } catch (_) {/* 客户端取消时只清理自有 socket；不重复发送。 */}
    });
  });
  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await server.close(force: true);
    resources.last['closed'] = true;
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() async {
    expect(resources.every((r) => r['closed'] == true), isTrue);
    HttpOverrides.global = previousOverrides;
    await File('${owned.path}/cleanup.json').writeAsString(jsonEncode({
      'httpListeners': resources,
      'allClosed': true,
      'networkScope':
          'synthetic owned loopback only; no PG/SQLite or real model'
    }));
  });
  BackendSelection pair(String provider,
          {String model = 'same', String? account, String? origin}) =>
      BackendSelection.pair(
          providerCode: provider,
          modelId: model,
          accountHash: account ?? 'account-a',
          origin: origin ?? 'http://127.0.0.1:${server.port}');
  AISettings settings([String? provider]) => AISettings.defaults()
    ..mode = AIMode.backend
    ..backendModel = 'same'
    ..backendSelection = provider == null ? null : pair(provider);
  Future<Object?> send(BackendChatService service,
          {bool stream = false,
          ChatRequestOptions options = const ChatRequestOptions()}) =>
      stream
          ? service
              .chatStreamEventsWithOptions(
                  prompt: 'test', history: const [], options: options)
              .toList()
          : service.chatWithUsageWithOptions(
              prompt: 'test', history: const [], options: options);
  for (final provider in ['A', 'B']) {
    for (final stream in [false, true]) {
      test('$provider same model exact pair stream=$stream', () async {
        await send(BackendChatService(settings(provider)), stream: stream);
        expect(posts.single['providerCode'], provider);
        expect(posts.single['model'], 'same');
        expect(probes, 0);
      });
    }
  }
  test(
      'legacy resolves once before provider messages and all repeated/child requests keep pair',
      () async {
    final service = BackendChatService(settings());
    final fixed = await prepare(service);
    expect(fixed?.providerCode, 'A');
    expect(fixed?.modelId, 'same');
    expect(jsonEncode(fixed?.toSafeJson()), isNot(contains('token')));
    resolvedProvider = 'B';
    await send(service);
    await send(service, stream: true);
    await service.chatStreamEvents(
        prompt: 'tool-round',
        history: const [],
        extraMessages: const [
          {'role': 'tool', 'content': 'result'}
        ]).toList();
    expect(probes, 1);
    expect(posts.map((p) => p['providerCode']), everyElement('A'));
  });
  test('settings edit after construction cannot change run pair or model',
      () async {
    final chosen = settings('A');
    final service = BackendChatService(chosen);
    chosen.backendSelection = pair('B', model: 'other');
    chosen.backendModel = 'other';
    await send(service);
    await send(service, stream: true);
    expect(posts.map((p) => p['providerCode']), everyElement('A'));
    expect(posts.map((p) => p['model']), everyElement('same'));
  });
  for (final code in [
    'model_ambiguous',
    'model_unavailable',
    'provider_unavailable',
    'catalog_not_public'
  ]) {
    test('legacy $code refuses POST, no automatic/repeated parse or logout',
        () async {
      probeStatus = code == 'catalog_not_public' ? 403 : 409;
      probeCode = code;
      final service = BackendChatService(settings());
      for (final stream in [false, true]) {
        final error = await errorOf(send(service, stream: stream));
        expect(
            error,
            isA<ChatTransportException>()
                .having((e) => e.safeCode, 'code', code));
      }
      expect(probes, 1);
      expect(posts, isEmpty);
      expect(tokens.clears, 0);
    });
  }
  test('unknown probe error fixed generic and failure not re-resolved',
      () async {
    probeStatus = 500;
    probeCode = 'synthetic-secret SQL token';
    final service = BackendChatService(settings());
    final error = await errorOf(send(service));
    expect(error, isA<ChatTransportException>());
    expect(error.toString(), isNot(contains('synthetic-secret')));
    await errorOf(send(service));
    expect(probes, 1);
    expect(posts, isEmpty);
  });
  for (final kind in [
    'malformed',
    'foreignAccount',
    'foreignOrigin',
    'follow'
  ]) {
    test('explicit $kind never falls back to backendModel', () async {
      final value = settings('A');
      value.backendSelection = switch (kind) {
        'malformed' =>
          BackendSelection.fromStorage({'version': 9, 'secret': 'synthetic'}),
        'foreignAccount' => pair('A', account: 'other'),
        'foreignOrigin' => pair('A', origin: 'https://other.example'),
        _ => BackendSelection.follow()
      };
      final error = await errorOf(send(BackendChatService(value)));
      expect(error, isA<ChatTransportException>());
      expect(posts, isEmpty);
      expect(probes, 0);
    });
  }
  Future<void> change(String kind) async {
    switch (kind) {
      case 'account':
        tokens.account = 'other';
        break;
      case 'token':
        tokens.token = 'new-token';
        break;
      case 'aba':
        await LoginDao.saveAuthToken('other-token',
            userName: 'synthetic', extras: {'accountHash': 'other'});
        await LoginDao.saveAuthToken('synthetic-jwt',
            userName: 'synthetic', extras: {'accountHash': 'account-a'});
        break;
      case 'origin':
        BackendConfig.host = '127.0.0.1:1';
        break;
      case 'restore':
        BackupService.agentExecutionRevision++;
        break;
    }
  }

  for (final stage in ['GET', 'lastHook']) {
    for (final kind in [
      'account',
      'token',
      'aba',
      'origin',
      'restore',
      'cancel'
    ]) {
      test('$kind during $stage refuses model POST', () async {
        final entered = Completer<void>(),
            gate = Completer<void>(),
            abort = Completer<void>();
        gates.add(gate);
        if (stage == 'GET') {
          probeEntered = entered;
          probeGate = gate;
        }
        final service =
            BackendChatService(settings(stage == 'GET' ? null : 'A'));
        final request = errorOf(send(service,
            options: ChatRequestOptions(
                abortTrigger: abort.future,
                beforeDispatch: stage == 'lastHook'
                    ? (_) {
                        entered.complete();
                        return gate.future;
                      }
                    : null)));
        final reached = await Future.any(
            [entered.future.then((_) => true), request.then((_) => false)]);
        expect(reached, isTrue);
        if (kind == 'cancel') {
          abort.complete();
        } else {
          await change(kind);
        }
        gate.complete();
        final error = await request;
        expect(error, isA<ChatTransportException>());
        expect(posts, isEmpty);
        expect(tokens.clears, 0);
      });
    }
  }
  test('one cancelled waiting sender cannot cancel another shared lookup',
      () async {
    final entered = Completer<void>(),
        gate = Completer<void>(),
        abort = Completer<void>();
    gates.add(gate);
    probeEntered = entered;
    probeGate = gate;
    final service = BackendChatService(settings());
    final first = errorOf(send(service,
        stream: true, options: ChatRequestOptions(abortTrigger: abort.future)));
    final second = errorOf(send(service));
    final reached = await Future.any(
        [entered.future.then((_) => true), first.then((_) => false)]);
    expect(reached, isTrue);
    abort.complete();
    gate.complete();
    expect(
        await first,
        isA<ChatTransportException>()
            .having((e) => e.safeCode, 'code', 'cancelled'));
    expect(await second, isNull);
    expect(probes, 1);
    expect(posts.length, 1);
    expect(posts.single['providerCode'], 'A');
  });
  test(
      'backend remote bits are exact scoped pairs; unresolved legacy borrows no bits',
      () async {
    catalogRows = [row('A', 'same', vision: true), row('B', 'same', pdf: true)];
    await ModelCatalog.refreshFromBackend();
    expect(catalogRequests, 1);
    final a = ChatService.capabilitiesFor(settings('A')),
        b = ChatService.capabilitiesFor(settings('B'));
    expect(a.image, isTrue);
    expect(a.pdf, isFalse);
    expect(b.image, isFalse);
    expect(b.pdf, isTrue);
    expect(ChatService.capabilitiesFor(settings()).image, isFalse);
    expect(ModelCatalog.optionFor('same'), isNull);
    final foreign = settings('A')
      ..backendSelection = pair('A', account: 'other');
    expect(ChatService.capabilitiesFor(foreign).image, isFalse);
  });
  test(
      'unowned or even scoped cache cannot grant backend remote bits/execution proof',
      () async {
    final data = {
      'models': [row('A', 'same', vision: true)]
    };
    await HiCache.getInstance()
        .prefs!
        .setString('ai_catalog_v1', jsonEncode(data));
    ModelCatalog.loadFromCache();
    expect(ChatService.capabilitiesFor(settings('A')).image, isFalse);
    await HiCache.getInstance()
        .prefs!
        .setString(AiCatalogIdentity.capture().cacheKey, jsonEncode(data));
    ModelCatalog.loadFromCache();
    expect(ChatService.capabilitiesFor(settings('A')).image, isFalse);
    expect(pairAvailable('A', 'same'), isTrue); // 未知，发送仍实时核验；不是 cache 授许可。
  });
  for (final bad in [
    <dynamic>[
      {'modelId': 'same'}
    ],
    <dynamic>[
      {'providerCode': ' ', 'modelId': 'same'}
    ],
    <dynamic>[
      {'providerCode': 'A', 'modelId': 'same'},
      {'providerCode': 'A', 'modelId': 'same'}
    ],
    <dynamic>['bad'],
    <dynamic>[
      {'providerCode': 'A', 'modelId': 'same', 'supportsVision': 'bad'}
    ]
  ]) {
    test(
        'malformed nonempty catalog retains previous exact success instead of empty permission',
        () async {
      catalogRows = [row('A', 'same', vision: true)];
      await ModelCatalog.refreshFromBackend();
      catalogRows = bad;
      await ModelCatalog.refreshFromBackend();
      expect(ModelCatalog.displaySnapshot.status, CatalogDisplayStatus.invalid);
      expect(ChatService.capabilitiesFor(settings('A')).image, isTrue);
      expect(pairAvailable('A', 'same'), isTrue);
    });
  }
  test(
      'failed catalog retains, success empty revokes; no substitution to another same model',
      () async {
    catalogRows = [row('A', 'same', vision: true), row('B', 'same')];
    await ModelCatalog.refreshFromBackend();
    final service = BackendChatService(settings('A'));
    await prepare(service);
    catalogStatus = 503;
    await ModelCatalog.refreshFromBackend();
    expect(ChatService.capabilitiesFor(settings('A')).image, isTrue);
    catalogStatus = 200;
    catalogRows = [row('B', 'same')];
    await ModelCatalog.refreshFromBackend();
    expect(pairAvailable('A', 'same'), isFalse);
    expect(await errorOf(send(service)), isA<ChatTransportException>());
    expect(posts, isEmpty);
    catalogRows = [];
    await ModelCatalog.refreshFromBackend();
    expect(pairAvailable('B', 'same'), isFalse);
  });
  test('late old identity success cannot replace newer pair snapshot',
      () async {
    final gate = Completer<void>(), entered = Completer<void>();
    gates.add(gate);
    catalogGate = gate;
    catalogEntered = entered;
    catalogRows = [row('A', 'same', vision: true)];
    final old = ModelCatalog.refreshFromBackend();
    await entered.future;
    await LoginDao.saveAuthToken('new-token',
        userName: 'synthetic', extras: {'accountHash': 'account-a'});
    catalogRows = [row('B', 'same', pdf: true)];
    await ModelCatalog.refreshFromBackend();
    gate.complete();
    await old;
    expect(ChatService.capabilitiesFor(settings('B')).pdf, isTrue);
    expect(ChatService.capabilitiesFor(settings('A')).image, isFalse);
  });
  test(
      'same model and slash-containing identifiers use collision-free tuple keys',
      () {
    const a = ModelOption('same', null, providerCode: 'A'),
        b = ModelOption('same', null, providerCode: 'B');
    expect(keyOf(a), isNot(keyOf(b)));
    const slashA = ModelOption('C', null, providerCode: 'A/B'),
        slashB = ModelOption('B/C', null, providerCode: 'A');
    expect(keyOf(slashA), jsonEncode(['A/B', 'C']));
    expect(keyOf(slashB), jsonEncode(['A', 'B/C']));
    expect(keyOf(slashA), isNot(keyOf(slashB)));
  });
  for (final code in [
    'model_ambiguous',
    'model_unavailable',
    'provider_unavailable',
    'catalog_not_public'
  ]) {
    for (final wire in ['nonstream', 'httpStream', 'sse']) {
      test(
          '$code $wire safe diagnosis roundtrip has no retry/logout even status503',
          () async {
        failureCode = code;
        failureStatus = code == 'catalog_not_public' ? 403 : 503;
        failureWire = wire == 'sse' ? 'sse' : 'nonstream';
        final error = await errorOf(send(BackendChatService(settings('A')),
            stream: wire != 'nonstream'));
        expect(
            error,
            isA<ChatTransportException>()
                .having((e) => e.safeCode, 'code', code));
        final typed = error as ChatTransportException;
        expect(typed.safeMessage, isNot('请求失败'));
        expect(typed.safeMessage, isNot(contains('synthetic-secret')));
        final diagnosis = ChatFailureDiagnosis.from(typed);
        expect(diagnosis.code, code);
        expect(diagnosis.action, isNot(ChatFailureAction.retry));
        expect(ChatFailureDiagnosis.fromJson(diagnosis.toJson())?.code, code);
        expect(posts.length, 1);
        expect(tokens.clears, 0);
      });
    }
  }
  test('unknown raw/prefix payload remains generic', () async {
    failureCode = 'model_unavailable synthetic-secret SQL token';
    failureStatus = 409;
    final error = await errorOf(send(BackendChatService(settings('A'))));
    expect(error, isA<ChatTransportException>());
    final typed = error as ChatTransportException;
    expect(typed.safeCode, 'request_failed');
    expect(typed.safeMessage, '请求失败');
    expect(jsonEncode(ChatFailureDiagnosis.from(typed).toJson()),
        isNot(contains('synthetic-secret')));
    expect(posts.length, 1);
  });
  test(
      'direct request never sends backend providerCode or changes local endpoint/model',
      () async {
    final value = AISettings.defaults();
    value.activeProvider.models.add(AiModel(id: 'local-model'));
    value.activeProvider
      ..apiKey = 'synthetic-key'
      ..apiHost = 'http://127.0.0.1:${server.port}/direct'
      ..selectedModelId = 'local-model';
    await ChatService.from(value).chat(prompt: 'test', history: const []);
    expect(posts.single['model'], 'local-model');
    expect(posts.single.containsKey('providerCode'), isFalse);
    expect(probes, 0);
  });
}
