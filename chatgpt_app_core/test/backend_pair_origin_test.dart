import 'support/owned_test_directory.dart';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backend_pair_transport_test.dart'
    show PairTokens, PairHttpOverrides, errorOf, pairAvailable;

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3A_HTTP_ROOT',
    nonceKey: 'R3A_HTTP_NONCE',
    legacyPrefix: '/tmp/chatai-r3a1-http-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer origin, sibling;
  late PairTokens storage;
  late String oldHost;
  late bool oldHttps;
  int siblingRequests = 0;
  int originPosts = 0;
  bool redirectCatalog = true;
  List<Map<String, Object>> catalogRows = [], siblingCatalogRows = [];
  HttpOverrides? previousOverrides;
  late Directory owned;
  final resources = <Map<String, Object?>>[];
  Map<String, Object> row(String provider,
          {bool vision = false, bool pdf = false}) =>
      {
        'providerCode': provider,
        'modelId': 'same',
        'displayName': 'Synthetic $provider',
        'supportsVision': vision,
        'supportsPdf': pdf,
        'supportsTool': false,
        'supportsReasoning': false,
      };
  setUpAll(() async {
    owned = ownedFixture.directory;
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = PairHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  setUp(() async {
    await HiCache.getInstance().prefs?.clear();
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    storage = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: storage,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    siblingRequests = 0;
    originPosts = 0;
    redirectCatalog = true;
    catalogRows = [];
    siblingCatalogRows = [];
    sibling = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    BackendConfig.host = '127.0.0.1:${origin.port}';
    BackendConfig.useHttps = false;
    resources.add({
      'originPort': origin.port,
      'siblingPort': sibling.port,
      'closed': false
    });
    sibling.listen((request) async {
      siblingRequests++;
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'code': 0,
        'data': request.uri.path == '/redirected-catalog'
            ? {
                'models': siblingCatalogRows,
              }
            : {
                'providerCode': 'sibling',
                'modelId': 'same',
                'content': 'wrong-origin'
              }
      }));
      await request.response.close();
    });
    origin.listen((request) async {
      await request.drain<void>();
      if (request.method == 'POST') originPosts++;
      if (request.uri.path == '/uapi/ai/catalog') {
        expect(request.method, 'GET');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer synthetic-jwt');
        if (!redirectCatalog) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'code': 0,
            'data': {'models': catalogRows},
          }));
          await request.response.close();
          return;
        }
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader,
            'http://127.0.0.1:${sibling.port}/redirected-catalog');
        await request.response.close();
        return;
      }
      request.response.statusCode = request.method == 'GET' ? 302 : 303;
      request.response.headers.set(HttpHeaders.locationHeader,
          'http://127.0.0.1:${sibling.port}/redirected');
      await request.response.close();
    });
  });
  tearDown(() async {
    await origin.close(force: true);
    await sibling.close(force: true);
    resources.last['closed'] = true;
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
  });
  tearDownAll(() {
    HttpOverrides.global = previousOverrides;
    expect(resources.every((r) => r['closed'] == true), isTrue);
    File('${owned.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'httpListenerPairs': resources,
      'allClosed': true,
      'scope': 'owned loopback redirect sentry only'
    }));
  });
  for (final siblingEmpty in [false, true]) {
    test(
        'catalog refresh refuses foreign ${siblingEmpty ? 'empty' : 'capability'} snapshot and preserves origin authority',
        () async {
      redirectCatalog = false;
      catalogRows = [row('A', vision: true)];
      await ModelCatalog.refreshFromBackend();
      expect(ModelCatalog.displaySnapshot.status, CatalogDisplayStatus.success);
      final identity = AiCatalogIdentity.capture();
      final cacheBefore = HiCache.getInstance().get(identity.cacheKey);
      expect(cacheBefore, isA<String>());
      final notificationsBefore = ModelCatalog.executionChanges.value;
      bool visionA() => ModelCatalog.backendCapabilitiesFor('same',
              providerCode: 'A',
              accountHash: 'account-a',
              origin: identity.endpoint.origin)
          .image;
      expect(visionA(), isTrue);
      expect(pairAvailable('A', 'same'), isTrue);
      expect(pairAvailable('B', 'same'), isFalse);

      redirectCatalog = true;
      siblingCatalogRows = siblingEmpty ? [] : [row('B', pdf: true)];
      await ModelCatalog.refreshFromBackend();
      final observed = <String, Object?>{
        'siblingEmpty': siblingEmpty,
        'siblingRequests': siblingRequests,
        'cacheUnchanged':
            HiCache.getInstance().get(identity.cacheKey) == cacheBefore,
        'visionA': visionA(),
        'pairA': pairAvailable('A', 'same'),
        'pairB': pairAvailable('B', 'same'),
        'executionNotificationsUnchanged':
            ModelCatalog.executionChanges.value == notificationsBefore,
        'displayStatus': ModelCatalog.displaySnapshot.status.name,
        'originalIdentityCurrent': identity.current,
        'originPosts': originPosts,
      };
      File('${owned.path}/catalog-redirect-$siblingEmpty.json')
          .writeAsStringSync(jsonEncode(observed));

      // 原 origin 直接成功仍可更新能力和集合，真正空目录仍撤权。
      redirectCatalog = false;
      catalogRows = [row('B', pdf: true)];
      final beforeDirect = ModelCatalog.executionChanges.value;
      await ModelCatalog.refreshFromBackend();
      expect(ModelCatalog.displaySnapshot.status, CatalogDisplayStatus.success);
      expect(
          ModelCatalog.backendCapabilitiesFor('same',
                  providerCode: 'B',
                  accountHash: 'account-a',
                  origin: identity.endpoint.origin)
              .pdf,
          isTrue);
      expect(pairAvailable('A', 'same'), isFalse);
      expect(pairAvailable('B', 'same'), isTrue);
      expect(ModelCatalog.executionChanges.value, beforeDirect + 1);
      catalogRows = [];
      await ModelCatalog.refreshFromBackend();
      expect(ModelCatalog.displaySnapshot.status, CatalogDisplayStatus.empty);
      expect(pairAvailable('B', 'same'), isFalse);
      expect(ModelCatalog.executionChanges.value, beforeDirect + 2);
      expect(originPosts, 0);
      expect(storage.clears, 0);
      expect(observed, {
        'siblingEmpty': siblingEmpty,
        'siblingRequests': 0,
        'cacheUnchanged': true,
        'visionA': true,
        'pairA': true,
        'pairB': false,
        'executionNotificationsUnchanged': true,
        'displayStatus': 'failed',
        'originalIdentityCurrent': true,
        'originPosts': 0,
      });
    });
  }
  test('shared R1 selection GET refuses redirected authority/sibling origin',
      () async {
    final scope = BackendSelectionBindingScope.capture(
        AgentWorkflowScope(accountHash: 'account-a'));
    final error = await errorOf(BackendSelectionProbeClient(
            headers: () => {'Authorization': 'Bearer synthetic-jwt'})
        .resolve(scope, 'same'));
    expect(error, isA<BackendSelectionProbeFailure>());
    expect(siblingRequests, 0);
  });
  for (final stream in [false, true]) {
    test('completion redirect refused stream=$stream without sibling request',
        () async {
      final settings = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendSelection = BackendSelection.pair(
            providerCode: 'A',
            modelId: 'same',
            accountHash: 'account-a',
            origin: 'http://127.0.0.1:${origin.port}');
      final service = BackendChatService(settings);
      final error = await errorOf(stream
          ? service.chatStreamEvents(prompt: 'test', history: const []).toList()
          : service.chat(prompt: 'test', history: const []));
      expect(error, isNotNull);
      expect(siblingRequests, 0);
      expect(storage.clears, 0);
    });
  }
}
