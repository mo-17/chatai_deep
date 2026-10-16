import 'dart:convert';

import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Tokens implements TokenStorage {
  int clears = 0;
  @override
  Future<void> clear() async => clears++;
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => 'synthetic-jwt';
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() =>
      {'accountHash': 'account-a', 'userName': 'synthetic'};
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    throw StateError('unexpected login write');
  }
}

class _Store extends AISettingsProvider {
  int writes = 0;
  @override
  Future<void> update(AISettings settings,
      {bool notify = true, String? expectedAccountHash}) {
    writes++;
    return super.update(settings,
        notify: notify, expectedAccountHash: expectedAccountHash);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String oldHost;
  late bool oldHttps;
  late _Tokens tokens;
  var gets = 0;
  var posts = 0;
  const provider = 'deepseek/provider-original';
  const model = 'deepseek-v4-pro-with-a-very-long-original-model-identifier';
  const displayName = 'Very Long DeepSeek 服务商名称用于窄屏测试';
  const label = '$displayName ($provider) · $model';
  setUp(() async {
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    AISettingsDao.configureSecretStore(null);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    tokens = _Tokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'catalog.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'catalog.synthetic.invalid';
    BackendConfig.useHttps = true;
    gets = 0;
    posts = 0;
  });
  tearDown(() {
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    expect(posts, 0);
    expect(tokens.clears, 0);
  });

  Future<void> pump(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> mocked(Future<void> Function() action, {bool missing = false}) =>
      http.runWithClient(
          action,
          () => MockClient((request) async {
                if (request.method == 'POST') posts++;
                expect(request.method, 'GET');
                expect(request.url.host, 'catalog.synthetic.invalid');
                expect(request.url.path, '/uapi/ai/catalog');
                gets++;
                return http.Response(
                    jsonEncode({
                      'code': 0,
                      'data': {
                        'providers': [
                          {'code': provider, 'displayName': displayName}
                        ],
                        'models': missing
                            ? []
                            : [
                                {
                                  'providerCode': provider,
                                  'modelId': model,
                                  'displayName': '长模型名称',
                                  'supportsVision': false,
                                  'supportsTool': false,
                                  'supportsReasoning': false,
                                  'supportsPdf': false,
                                }
                              ],
                      }
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }));

  Future<_Store> page(WidgetTester tester, double width, double scale) async {
    tester.view.physicalSize = Size(width, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _Store();
    final settings = store.settings.clone()
      ..mode = AIMode.backend
      ..backendSelection = BackendSelection.pair(
          providerCode: provider,
          modelId: model,
          accountHash: 'account-a',
          origin: 'https://catalog.synthetic.invalid');
    await tester.runAsync(() => store.update(settings));
    await tester.pumpWidget(ChangeNotifierProvider<AISettingsProvider>.value(
        value: store,
        child: MaterialApp(
            home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: const AISettingsPage()))));
    await pump(tester);
    return store;
  }

  for (final config in [
    (320.0, 1.0),
    (280.0, 1.0),
    (320.0, 2.0),
    (280.0, 2.0)
  ]) {
    testWidgets('actual backend card uses full-width rows: $config',
        (tester) async {
      await mocked(() async {
        final store = await page(tester, config.$1, config.$2);
        try {
          final writes = store.writes;
          final selected = store.settings.backendSelection!.toStorageJson();
          final title = find.text('后端模型');
          final paragraph = tester.renderObject<RenderParagraph>(title);
          expect(
              paragraph.getBoxesForSelection(
                  const TextSelection(baseOffset: 0, extentOffset: 4)),
              hasLength(1),
              reason: 'title must not wrap into a column of single characters');
          final message =
              find.byKey(const ValueKey('backend-model-catalog-message'));
          final selector = find.byKey(const ValueKey('backend-model-selector'));
          expect(tester.getRect(selector).top,
              greaterThan(tester.getRect(message).bottom));
          final selectedText = tester.widget<Text>(
              find.byKey(const ValueKey('backend-model-selected-label')));
          expect(selectedText.data, label);
          expect(selectedText.maxLines, 2);
          expect(selectedText.overflow, TextOverflow.ellipsis);
          expect(tester.getSize(selector).width, closeTo(config.$1 - 64, 1));
          expect(tester.takeException(), isNull);
          expect(gets, 1);
          expect(store.writes, writes);
          await tester.tap(selector);
          await tester.pumpAndSettle();
          expect(find.text(label), findsWidgets);
          expect(find.text('当前选择：$label'), findsOneWidget);
          expect(find.byKey(ValueKey(jsonEncode([provider, model]))),
              findsOneWidget);
          expect(store.settings.backendSelection!.toStorageJson(), selected);
          expect(store.writes, writes);
          expect(gets, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await pump(tester);
        }
      });
    });
  }

  testWidgets(
      'invalid original selection stays visible; refresh does not save or replace it',
      (tester) async {
    await mocked(() async {
      final store = await page(tester, 320, 1.5);
      try {
        final selected = store.settings.backendSelection!.toStorageJson();
        final writes = store.writes;
        final text = tester.widget<Text>(
            find.byKey(const ValueKey('backend-model-selected-label')));
        expect(text.data, contains(provider));
        expect(text.data, contains(model));
        expect(text.data, contains('已删除或停用'));
        await tester.tap(find.text('刷新模型清单'));
        await pump(tester);
        expect(gets, 2);
        expect(store.writes, writes);
        expect(store.settings.backendSelection!.toStorageJson(), selected);
        await tester.tap(find.byKey(const ValueKey('backend-model-selector')));
        await tester.pumpAndSettle();
        expect(find.text('当前选择：${text.data}'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await pump(tester);
      }
    }, missing: true);
  });
}
