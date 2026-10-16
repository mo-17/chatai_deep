import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStorage implements TokenStorage {
  Map<String, dynamic>? value;
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => value?['boardingPass'] as String?;
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() =>
      value == null ? null : Map.of(value!);
  @override
  Future<void> clear() async => value = null;
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    value = {'boardingPass': token, 'userName': userName, ...extras};
  }
}

class _CountingSettingsProvider extends AISettingsProvider {
  int writes = 0;
  @override
  Future<void> update(AISettings next,
      {bool notify = true, String? expectedAccountHash}) {
    writes++;
    return super
        .update(next, notify: notify, expectedAccountHash: expectedAccountHash);
  }
}

http.Response _catalog({String id = 'deepseek-v4-pro', bool empty = false}) =>
    http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'models': empty
                ? []
                : [
                    {
                      'modelId': id,
                      'displayName': 'Synthetic V4 Pro',
                      'providerCode': 'deepseek',
                      'supportsVision': false,
                      'supportsTool': true,
                      'supportsReasoning': true,
                      'supportsPdf': false
                    }
                  ]
          }
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<AISettingsProvider> _page(WidgetTester tester,
    {bool backend = true, AISettingsProvider? provider}) async {
  final p = provider ?? AISettingsProvider();
  if (backend) {
    final s = p.settings.clone()..mode = AIMode.backend;
    await tester.runAsync(() => p.update(s));
  }
  await tester.pumpWidget(ChangeNotifierProvider.value(
      value: p, child: const MaterialApp(home: AISettingsPage())));
  await _pump(tester);
  return p;
}

void main() {
  late _MemoryStorage storage;
  late String oldHost;
  late bool oldHttps;
  var posts = 0;
  final gates = <Completer<http.Response>>[];
  setUp(() async {
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    ModelCatalog.applyRemote({'models': []});
    AISettingsDao.configureSecretStore(null);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    storage = _MemoryStorage();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'catalog.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: storage,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'catalog.synthetic.invalid';
    BackendConfig.useHttps = true;
    posts = 0;
    gates.clear();
  });
  tearDown(() {
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    expect(posts, 0);
  });
  Future<void> login({String account = 'a', String token = 'synthetic-a'}) =>
      LoginDao.saveAuthToken(token,
          userName: 'Synthetic', extras: {'accountHash': account});
  Future<void> mock(
      WidgetTester tester,
      Future<http.Response> Function(http.Request) handler,
      Future<void> Function() action) async {
    await http.runWithClient(() async {
      try {
        await action();
      } finally {
        for (final g in gates) {
          if (!g.isCompleted) g.complete(_catalog());
        }
        await _pump(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(tester);
      }
    },
        () => MockClient((r) {
              if (r.method != 'GET') posts++;
              expectSync(r.method, 'GET');
              expectSync(r.url.path, '/uapi/ai/catalog');
              return handler(r);
            }));
  }

  testWidgets(
      'unauthenticated start skips GET, login then switch backend fetches actual wrapped catalog without switching chosen model',
      (tester) async {
    var gets = 0;
    await mock(tester, (r) async {
      gets++;
      expectSync(r.url.toString(),
          'https://catalog.synthetic.invalid/uapi/ai/catalog');
      expectSync(r.headers['Authorization'], 'Bearer synthetic-a');
      return _catalog();
    }, () async {
      await tester.runAsync(ModelCatalog.refreshFromBackend);
      expect(gets, 0);
      await tester.runAsync(() => login());
      final p = await _page(tester, backend: false);
      expect(gets, 0);
      await tester.tap(find.text('后端代理'));
      await _pump(tester);
      expect(gets, 1);
      expect(p.settings.backendModel, 'deepseek-chat');
      expect(find.textContaining('清单来自后端'), findsOneWidget);
      await tester.tap(find.text('后端模型'));
      await _pump(tester);
      expect(find.textContaining('deepseek-v4-pro'), findsOneWidget);
      expect(p.settings.backendModel, 'deepseek-chat');
    });
  });
  testWidgets(
      'enter an already-backend page refreshes; delayed success updates an open picker and concurrent refresh joins the GET',
      (tester) async {
    await tester.runAsync(() => login());
    var gets = 0;
    final gate = Completer<http.Response>();
    gates.add(gate);
    await mock(tester, (r) {
      gets++;
      return gate.future;
    }, () async {
      await _page(tester);
      expect(gets, 1);
      await tester.tap(find.text('后端模型'));
      await _pump(tester);
      expect(gets, 1);
      gate.complete(_catalog());
      await _pump(tester);
      expect(find.textContaining('deepseek-v4-pro'), findsOneWidget);
      expect(find.textContaining('正在获取后端模型'), findsNothing);
    });
  });
  for (final status in ['401', '403', 'timeout', 'network']) {
    testWidgets(
        '$status has visible safe guidance and explicit retry recovers with no POST',
        (tester) async {
      await tester.runAsync(() => login());
      var gets = 0;
      var fail = true;
      await mock(tester, (r) async {
        gets++;
        if (!fail) return _catalog();
        if (status == 'timeout') throw TimeoutException('synthetic-secret');
        if (status == 'network') throw StateError('synthetic-token');
        return http.Response('synthetic-secret', int.parse(status));
      }, () async {
        final p = await _page(tester);
        expect(gets, 1);
        final hint = status == '401'
            ? '请登录'
            : status == '403'
                ? '未开放模型目录'
                : status == 'timeout'
                    ? '获取模型目录超时'
                    : '获取模型目录失败';
        expect(find.textContaining(hint), findsWidgets);
        expect(find.textContaining('synthetic-secret'), findsNothing);
        fail = false;
        await tester.tap(find.text('刷新模型清单'));
        await _pump(tester);
        expect(gets, 2);
        expect(find.textContaining('清单来自后端'), findsOneWidget);
        expect(p.settings.backendModel, 'deepseek-chat');
      });
    });
  }
  testWidgets(
      'successful empty directory is explicit and still revokes execution; UI cache cannot grant execution permission',
      (tester) async {
    await tester.runAsync(() => login());
    await mock(tester, (r) async => _catalog(empty: true), () async {
      final p = await _page(tester);
      expect(find.textContaining('服务器当前没有可用模型'), findsWidgets);
      expect(
          ModelCatalog.backendProfileAvailable('deepseek-chat', account: 'a'),
          isFalse);
      expect(p.settings.backendModel, 'deepseek-chat');
      ModelCatalog.applyRemote(
          jsonDecode(_catalog().body)['data'] as Map<String, dynamic>);
      expect(
          ModelCatalog.backendProfileAvailable('deepseek-chat', account: 'a'),
          isFalse);
      await tester.tap(find.text('后端模型'));
      await _pump(tester);
      expect(find.textContaining('deepseek-v4-pro'), findsNothing);
    });
  });
  for (final change in ['same-token-new-epoch', 'account', 'origin']) {
    testWidgets(
        'late $change response cannot overwrite current display, cache or execution',
        (tester) async {
      await tester.runAsync(() => login());
      var gets = 0;
      final old = Completer<http.Response>();
      gates.add(old);
      late AiCatalogIdentity oldIdentity;
      await mock(tester, (r) {
        gets++;
        if (gets == 1) {
          oldIdentity = AiCatalogIdentity.capture();
          return old.future;
        }
        return Future.value(_catalog(id: 'fresh-only'));
      }, () async {
        await _page(tester);
        expect(gets, 1);
        if (change == 'origin') {
          BackendConfig.host = 'new-catalog.synthetic.invalid';
        } else {
          await tester
              .runAsync(() => login(account: change == 'account' ? 'b' : 'a'));
        }
        if (change == 'account') {
          await tester.pumpWidget(const SizedBox.shrink());
          await _pump(tester);
          await _page(tester);
        } else {
          await _pump(tester);
        }
        // Ready hook 的请求在真实异步 Zone 创建，先排空该 Zone 再断言缓存。
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await _pump(tester);
        expect(gets, 2);
        final currentKey = AiCatalogIdentity.capture().cacheKey;
        expect(HiCache.getInstance().get(currentKey), contains("fresh-only"));
        old.complete(_catalog(empty: true));
        await _pump(tester);
        expect(HiCache.getInstance().get(oldIdentity.cacheKey),
            change == 'origin' || change == 'account' ? isNull : isNotNull);
        expect(HiCache.getInstance().get(currentKey), contains('fresh-only'));
        await tester.tap(find.text('后端模型'));
        await _pump(tester);
        expect(find.textContaining('fresh-only'), findsOneWidget);
        expect(
            ModelCatalog.backendProfileAvailable('fresh-only',
                account: change == 'account' ? 'b' : 'a'),
            isTrue);
      });
    });
  }

  for (final owned in [false, true]) {
    testWidgets(
        'P2 cache ${owned ? "owned" : "legacy"}: failed GET displays only current account/origin cached models',
        (tester) async {
      await tester.runAsync(() => login(account: 'b', token: 'synthetic-b'));
      HiCache.getInstance().setString('ai_catalog_v1',
          jsonEncode(jsonDecode(_catalog(id: 'legacy-other').body)['data']));
      if (owned) {
        HiCache.getInstance().setString(AiCatalogIdentity.capture().cacheKey,
            jsonEncode(jsonDecode(_catalog(id: 'owned-b-only').body)['data']));
      }
      ModelCatalog.loadFromCache();
      await mock(tester, (r) async => http.Response('synthetic failed', 503),
          () async {
        await _page(tester);
        expect(ModelCatalog.displaySnapshot.hasSnapshot, owned);
        expect(
            find.textContaining(owned ? '当前显示上次清单' : '获取模型目录失败'), findsWidgets);
        await tester.tap(find.text('后端模型'));
        await _pump(tester);
        expect(find.textContaining('legacy-other'), findsNothing);
        expect(find.textContaining('owned-b-only'),
            owned ? findsOneWidget : findsNothing);
      });
    });
  }
  for (final change in ['none', 'same-token-new-epoch', 'origin']) {
    testWidgets(
        'P2 custom dialog $change: confirm saves only in its original identity',
        (tester) async {
      await tester.runAsync(() => login());
      await mock(tester, (r) async => _catalog(), () async {
        final p = _CountingSettingsProvider();
        await _page(tester, provider: p);
        final before = HiCache.getInstance().get(AISettingsDao.keyFor('a'));
        final writes = p.writes;
        await tester.tap(find.text('后端模型'));
        await _pump(tester);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('自定义服务商与模型...'));
        await tester.tap(find.text('自定义服务商与模型...'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('backend_provider_code')), 'deepseek');
        await tester.enterText(find.byKey(const ValueKey('backend_model_id')),
            'custom-original-scope');
        if (change == 'origin') {
          BackendConfig.host = 'new-catalog.synthetic.invalid';
        }
        if (change == 'same-token-new-epoch') {
          await tester.runAsync(() => login());
        }
        await tester.tap(find.text('确定'));
        await _pump(tester);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await _pump(tester);
        expect(p.writes - writes, change == 'none' ? 1 : 0);
        expect(p.settings.backendModel, 'deepseek-chat');
        expect(p.settings.backendSelection?.modelId,
            change == 'none' ? 'custom-original-scope' : null);
        expect(p.settings.backendSelection?.providerCode,
            change == 'none' ? 'deepseek' : null);
        if (change == 'none') {
          expect(HiCache.getInstance().get(AISettingsDao.keyFor('a')),
              contains('custom-original-scope'));
        } else {
          expect(HiCache.getInstance().get(AISettingsDao.keyFor('a')), before);
        }
      });
    });
  }
  testWidgets('guest backend display makes zero GET and asks for login',
      (tester) async {
    storage.value = {
      'boardingPass': LoginDao.kGuestToken,
      'userName': 'guest',
      'accountHash': 'guest',
      'guest': true
    };
    var gets = 0;
    await mock(tester, (r) async {
      gets++;
      return _catalog();
    }, () async {
      await _page(tester);
      expect(gets, 0);
      expect(find.textContaining('请登录'), findsWidgets);
    });
  });
}
