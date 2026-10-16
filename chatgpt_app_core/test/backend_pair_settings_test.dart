import 'dart:convert';
import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
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
import 'support/backend_pair_tokens.dart';

class _Store extends AISettingsProvider {
  int writes = 0;
  bool fail = false;
  @override
  Future<void> update(AISettings s,
      {bool notify = true, String? expectedAccountHash}) {
    writes++;
    if (fail) throw StateError('synthetic-private-save-error');
    return super
        .update(s, notify: notify, expectedAccountHash: expectedAccountHash);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PairTokens tokens;
  late String oldHost;
  late bool oldHttps;
  int posts = 0;
  List<Map<String, Object>> rows = [];
  Map<String, Object> row(String provider, String model) => {
        'providerCode': provider,
        'modelId': model,
        'displayName': model,
        'supportsVision': false,
        'supportsTool': false,
        'supportsReasoning': false,
        'supportsPdf': false,
      };
  Future<void> pump(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.pump();
      await t.pump(const Duration(milliseconds: 10));
    }
  }

  Future<_Store> page(WidgetTester t) async {
    final store = _Store();
    await t.runAsync(
        () => store.update(store.settings.clone()..mode = AIMode.backend));
    await t.pumpWidget(ChangeNotifierProvider<AISettingsProvider>.value(
        value: store, child: const MaterialApp(home: AISettingsPage())));
    await pump(t);
    return store;
  }

  Future<void> mocked(Future<void> Function() action) => http.runWithClient(
      action,
      () => MockClient((request) async {
            if (request.method == 'POST') posts++;
            return http.Response(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'models': rows,
                    'providers': [
                      {'code': 'A', 'displayName': 'Synthetic Alpha'},
                      {'code': 'B', 'displayName': 'Synthetic Beta'}
                    ]
                  }
                }),
                200);
          }));
  Future<void> custom(WidgetTester t) async {
    await t.tap(find.text('后端模型'));
    await t.pumpAndSettle();
    final tile = find.textContaining('自定义');
    await t.scrollUntilVisible(tile, 160,
        scrollable: find
            .descendant(
                of: find.byType(BottomSheet), matching: find.byType(Scrollable))
            .first);
    await t.tap(tile);
    await t.pumpAndSettle();
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    AISettingsDao.configureSecretStore(null);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    tokens = PairTokens();
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
    posts = 0;
    rows = [
      row('A', 'same'),
      row('B', 'same'),
      row('a/b', 'c'),
      row('a', 'b/c')
    ];
  });
  tearDown(() {
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    expect(posts, 0);
  });
  testWidgets(
      'actual picker identifies same models and tuple collisions; only explicit selection saves pair',
      (t) async {
    await mocked(() async {
      final store = await page(t);
      final before = store.writes;
      await t.tap(find.text('刷新模型清单'));
      await pump(t);
      expect(store.writes, before);
      await t.tap(find.text('后端模型'));
      await t.pumpAndSettle();
      expect(find.text('Synthetic Alpha (A) · same'), findsOneWidget);
      expect(find.text('Synthetic Beta (B) · same'), findsOneWidget);
      expect(find.byKey(ValueKey(jsonEncode(['a/b', 'c']))), findsOneWidget);
      expect(find.byKey(ValueKey(jsonEncode(['a', 'b/c']))), findsOneWidget);
      await t.tap(find.byKey(ValueKey(jsonEncode(['B', 'same']))));
      await pump(t);
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await pump(t);
      expect(store.writes, before + 1);
      final pair = store.settings.backendSelection!;
      expect(pair.providerCode, 'B');
      expect(pair.modelId, 'same');
      expect(pair.accountHash, 'account-a');
      expect(pair.origin, 'https://catalog.synthetic.invalid');
      expect(store.settings.backendModel, 'deepseek-chat');
      expect(
          (await t.runAsync(() => AISettingsDao.loadForAsync('account-a')))!
              .backendSelection!
              .pairKey,
          pair.pairKey);
    });
  });
  testWidgets(
      'custom validates both identifiers, preserves original text, cancel and failed save are explicit',
      (t) async {
    await mocked(() async {
      final store = await page(t);
      final before = store.writes;
      await custom(t);
      expect(
          find
              .byType(TextField)
              .evaluate()
              .where((e) =>
                  e.widget.key == const ValueKey('backend_provider_code'))
              .length,
          1);
      await t.enterText(
          find.byKey(const ValueKey('backend_model_id')), ' model / ');
      await t.tap(find.text('确定'));
      await pump(t);
      expect(store.writes, before);
      expect(find.text('请输入服务商 code'), findsOneWidget);
      await t.enterText(
          find.byKey(const ValueKey('backend_provider_code')), ' provider / ');
      await t.tap(find.text('确定'));
      await pump(t);
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await pump(t);
      expect(store.settings.backendSelection!.providerCode, ' provider / ');
      expect(store.settings.backendSelection!.modelId, ' model / ');
      final saved = store.settings.backendSelection!.pairKey;
      await custom(t);
      await t.tap(find.text('取消'));
      await pump(t);
      expect(store.writes, before + 1);
      store.fail = true;
      await custom(t);
      await t.enterText(
          find.byKey(const ValueKey('backend_provider_code')), 'new');
      await t.tap(find.text('确定'));
      await pump(t);
      expect(store.settings.backendSelection!.pairKey, saved);
      expect(find.text('后端选择未保存，请稍后重试'), findsOneWidget);
      expect(find.textContaining('synthetic-private'), findsNothing);
    });
  });
  for (final change in ['epoch', 'origin', 'account', 'mode']) {
    testWidgets('custom dialog refuses old $change; zero late save', (t) async {
      await mocked(() async {
        final store = await page(t);
        await custom(t);
        // 旧页仍有一个模型输入框，红轮也能执行身份 fence 正例。
        final provider = find.byKey(const ValueKey('backend_provider_code'));
        if (provider.evaluate().isNotEmpty) await t.enterText(provider, 'A');
        final model = find.byKey(const ValueKey('backend_model_id'));
        await t.enterText(
            model.evaluate().isNotEmpty
                ? model
                : find.descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(TextField)),
            'same');
        if (change == 'origin') BackendConfig.host = 'other.synthetic.invalid';
        if (change == 'account') tokens.account = 'account-b';
        if (change == 'epoch') {
          await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
              userName: 'Synthetic', extras: {'accountHash': 'account-a'}));
        }
        if (change == 'mode') {
          await t.runAsync(
              () => store.update(store.settings.clone()..mode = AIMode.local));
        }
        final before = store.writes;
        await t.tap(find.text('确定'));
        await pump(t);
        expect(store.writes, before);
        expect(store.settings.backendSelection, isNull);
      });
    });
  }
  test(
      'modern readiness never uses legacy model for invalid or foreign selection',
      () {
    for (final raw in [
      {'version': 99},
      BackendSelection.pair(
              providerCode: 'A',
              modelId: 'same',
              accountHash: 'other',
              origin: 'https://catalog.synthetic.invalid')
          .toSafeJson()
    ]) {
      final settings = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = 'legacy-fallback'
        ..backendSelection =
            BackendSelection.fromStorage(raw, allowFollow: false);
      // dynamic named arguments 兼容红轮旧签名，缺新合同记为旧状态而非 fixture setup failure。
      AIReadyState state;
      try {
        state = Function.apply(resolveAIReadiness, [], {
          #settings: settings,
          #isGuest: false,
          #accountHash: 'account-a',
          #origin: 'https://catalog.synthetic.invalid'
        }) as AIReadyState;
      } on NoSuchMethodError {
        state = resolveAIReadiness(settings: settings, isGuest: false);
      }
      expect(state.status, AIReadyStatus.needsSetup);
      expect(settings.backendModel, 'legacy-fallback');
    }
  });
  test(
      'actual readiness provider responds to exact removal and origin change without settings rewrite',
      () async {
    await mocked(() async {
      final pair = BackendSelection.pair(
          providerCode: 'A',
          modelId: 'same',
          accountHash: 'account-a',
          origin: 'https://catalog.synthetic.invalid');
      final settings = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendSelection = pair;
      final provider = AIReadinessProvider(
          evidenceReader: (
                  {required accountHash, required settings, storage}) async =>
              AIOnboardingEvidence.empty);
      addTearDown(provider.dispose);
      provider.synchronize(
          settings: settings, accountHash: 'account-a', isGuest: false);
      await provider.initialize();
      expect(provider.state.status, AIReadyStatus.configuredUnverified);
      await ModelCatalog.refreshFromBackend();
      expect(provider.state.status, AIReadyStatus.configuredUnverified);
      rows = [row('B', 'same')];
      await ModelCatalog.refreshFromBackend();
      expect(provider.state.reasonCode, 'model_unavailable');
      BackendConfig.host = 'other.synthetic.invalid';
      expect(provider.state.reasonCode, 'backend_scope_changed');
      expect(settings.backendSelection!.pairKey, pair.pairKey);
    });
  });
}
