import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/pages/story_room_list_page.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_list_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/widget/translation_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

Object? preparedOf(TranslationSettingsResult r) {
  try {
    return (r as dynamic).preparedSession;
  } on NoSuchMethodError {
    return null;
  }
}

Future<void> saveResult(TranslationSettingsResult r) async {
  final run = preparedOf(r);
  final store = TranslationModelPreferenceStore();
  if (run == null) {
    await store.save(r.preference, expectedAccountHash: 'account-a');
  } else {
    await Function.apply(store.save, [
      r.preference
    ], {
      #expectedAccountHash: 'account-a',
      #isOriginalSessionCurrent: () => (run as dynamic).isCurrent as bool
    });
  }
}

class PreferenceGate implements TranslationPreferenceKeyValueStore {
  final Map<String, Object?> values = {};
  final started = Completer<void>(), release = Completer<void>();
  bool held = true;
  @override
  Object? read(String key) => values[key];
  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> writeString(String key, String value) async {
    if (held) {
      held = false;
      started.complete();
      await release.future;
    }
    values[key] = value;
    return true;
  }
}

Future<void> guardedPreferenceSave(TranslationModelPreferenceStore store,
    TranslationModelPreference preference, bool Function() guard) async {
  try {
    await Function.apply(store.save, [preference],
        {#expectedAccountHash: 'account-a', #isOriginalSessionCurrent: guard});
  } on NoSuchMethodError {
    await store.save(preference, expectedAccountHash: 'account-a');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, owned;
  late DatabaseFactory? oldFactory;
  late String oldHost;
  late bool oldHttps;
  late PairTokens tokens;
  late AISettingsProvider provider;
  late ThemeProvider theme;
  late HiDBManager storage;
  late AssistantDao dao;
  late StoryTemplateTranslationTaskDao taskDao;
  int? historyId;
  Map<String, Object?>? historyRow;
  WidgetTester? active;
  TranslationSettingsResult? result;
  final posts = <Map<String, dynamic>>[], cleanup = <Map<String, Object?>>[];
  int probes = 0, catalogGets = 0, serial = 0;
  bool legacyUnique = false, save = true;
  Completer<void>? getGate, getEntered, postGate, postEntered;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  BackendSelection pair(String code,
          {String account = 'account-a', String? model}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: model ?? 'same',
          accountHash: account,
          origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
  TranslationModelPreference pref(String code,
          {String account = 'account-a'}) =>
      TranslationModelPreference(
          mode: TranslationModelPreferenceMode.backend,
          modelId: 'same',
          backendSelection: pair(code, account: account),
          reasoningPolicy: ChatReasoningPolicy.offIfSupported);
  setUpAll(() {
    root = Directory(Platform.environment['R3B4_ROOT']!);
    expect(root.path,
        '/tmp/chatai-r3b4-owned-${Platform.environment['R3B4_NONCE']}');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': Platform.environment['R3B4_NONCE']});
    sqfliteFfiInit();
  });
  setUp(() async {
    owned = Directory('${root.path}/case-${serial++}')..createSync();
    oldFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath('${owned.path}/db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => owned.path);
    final card = File('${owned.path}/role.json');
    card.writeAsStringSync(AssistantRoleCardService.exportJson(AssistantModel(
        name: 'Original Card',
        prompt: 'Please answer clearly in English.',
        useTools: false)));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            picker,
            (call) async => call.method == 'pickFiles'
                ? [card.path]
                : [
                    {
                      'path': card.path,
                      'name': 'role.json',
                      'size': card.lengthSync(),
                      'bytes': null
                    }
                  ]);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    AISettingsDao.resetSecureStateForTest();
    LoginDao.resetHooksForTest();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'translation.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'translation.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
    result = null;
    posts.clear();
    probes = 0;
    catalogGets = 0;
    legacyUnique = false;
    save = true;
    getGate = getEntered = postGate = postEntered = null;
  });
  Future<void> pump(WidgetTester t, [int n = 5]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> until(WidgetTester t, bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await pump(t, 1);
    }
    expect(condition(), isTrue,
        reason: 'bounded actual widget/SQLite settlement');
  }

  Future<void> mocked(Future<void> Function() body) =>
      http.runWithClient(() async {
        try {
          await body();
        } finally {
          if (getGate?.isCompleted == false) getGate!.complete();
          if (postGate?.isCompleted == false) postGate!.complete();
          if (active != null) {
            final t = active!;
            await t.pumpWidget(const SizedBox.shrink());
            await pump(t, 5);
            await t.runAsync(() => HiDBManager.closeAll());
            expect(t.takeException(), isNull);
            active = null;
          }
        }
      },
          () => MockClient((r) async {
                expect(r.url.host, 'translation.synthetic.invalid');
                expect(r.headers['Authorization'], 'Bearer synthetic-jwt');
                if (r.url.path == '/uapi/ai/catalog') {
                  catalogGets++;
                  return http.Response(
                      jsonEncode({
                        'code': 0,
                        'data': {
                          'providers': [
                            for (final p in legacyUnique ? ['A'] : ['A', 'B'])
                              {'code': p, 'displayName': 'Synthetic $p'}
                          ],
                          'models': [
                            for (final p in legacyUnique ? ['A'] : ['A', 'B'])
                              {
                                'providerCode': p,
                                'modelId': 'same',
                                'displayName': 'same',
                                'supportsTool': false,
                                'supportsVision': false,
                                'supportsPdf': false,
                                'supportsReasoning': false
                              }
                          ]
                        }
                      }),
                      200);
                }
                if (r.url.path == '/uapi/ai/model-selection') {
                  probes++;
                  if (getEntered?.isCompleted == false) getEntered!.complete();
                  if (getGate != null) await getGate!.future;
                  return http.Response(
                      jsonEncode(legacyUnique
                          ? {
                              'code': 0,
                              'data': {
                                'providerCode': 'A',
                                'modelId': r.url.queryParameters['modelId']
                              }
                            }
                          : {
                              'safeCode': 'model_ambiguous',
                              'message': 'synthetic secret SQL token'
                            }),
                      legacyUnique ? 200 : 409);
                }
                expect(r.method, 'POST');
                expect(r.url.path, '/uapi/chat/completions/stream');
                posts.add(jsonDecode(r.body) as Map<String, dynamic>);
                if (postEntered?.isCompleted == false) postEntered!.complete();
                if (postGate != null) await postGate!.future;
                final content = jsonEncode({
                  'name': '译文',
                  'prompt': '请清楚回答。',
                  'description': '译后描述',
                  'personality': '友好',
                  'scenario': '场景',
                  'openingMessage': '你好',
                  'translation': '早上好'
                });
                return http.Response(
                  'data: ${jsonEncode({
                        'choices': [
                          {
                            'delta': {'content': content}
                          }
                        ]
                      })}\n\ndata: [DONE]\n\n',
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }));
  Future<void> init(WidgetTester t,
      {bool assistant = false,
      bool history = false,
      TranslationModelPreference? initial,
      bool legacy = false}) async {
    active = t;
    await t.binding.setSurfaceSize(const Size(900, 1400));
    await t.runAsync(() async {
      final s = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = 'same'
        ..backendSelection = legacy ? null : pair('A');
      await HiCache.getInstance()
          .setString(AISettingsDao.keyFor('account-a'), jsonEncode(s.toJson()));
      provider = AISettingsProvider();
      theme = ThemeProvider();
      storage = await HiDBManager.instance(dbName: 'account-a');
      dao = await AssistantDao.create(storage);
      if (history) {
        taskDao = await StoryTemplateTranslationTaskDao.create(storage,
            accountHash: 'account-a');
        final task = StoryTemplateTranslationTaskModel(
            sourceTitle: 'History task',
            sourcePayload: '{}',
            status: StoryTemplateTranslationTaskStatus.failed,
            attempts: 2,
            partialPayload: '{"kept":"old"}',
            requestProfile: jsonEncode(TranslationRequestProfile(
                    mode: TranslationExecutionMode.backend,
                    modelId: 'same',
                    reasoningPolicy: ChatReasoningPolicy.offIfSupported,
                    reasoningControlSuppressed: false)
                .toJson()),
            log: 'old attempt remains',
            error: 'unknown_send');
        historyId = await taskDao.saveTask(task);
        historyRow = (await storage.db.query(taskDao.tableName,
                where: 'id=?', whereArgs: [historyId]))
            .single;
      }
      await ModelCatalog.refreshFromBackend();
    });
    await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AISettingsProvider>.value(value: provider),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme)
        ],
        child: MaterialApp(
            home: history
                ? const StoryRoomListPage()
                : assistant
                    ? const AssistantListPage()
                    : Scaffold(
                        body: Builder(
                            builder: (context) => TextButton(
                                onPressed: () async {
                                  final r = await showTranslationSettingsDialog(
                                      context,
                                      readSnapshot: () =>
                                          TranslationSettingsSnapshot(
                                              settings:
                                                  provider.settings.clone(),
                                              accountHash:
                                                  LoginDao.getAccountHash() ??
                                                      'guest',
                                              eligibilityEnvironment:
                                                  TranslationEligibilityEnvironment
                                                      .current()),
                                      initialValue: initial ?? pref('B'),
                                      estimatedRunes: 20,
                                      probeService:
                                          TranslationModelProbeService.shared);
                                  if (r != null) {
                                    result = r;
                                    if (save) {
                                      try {
                                        await saveResult(r);
                                      } catch (_) {}
                                    }
                                  }
                                },
                                child: const Text('打开设置')))))));
    await pump(t, 8);
  }

  Future<void> open(WidgetTester t) async {
    await t.tap(find.text('打开设置'));
    await pump(t);
  }

  Future<void> confirm(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('translation_settings_confirm')));
    await pump(t, 8);
    if (find
        .byKey(const ValueKey('translation_warning_continue'))
        .evaluate()
        .isNotEmpty) {
      await t.tap(find.byKey(const ValueKey('translation_warning_continue')));
      await pump(t, 8);
    }
  }

  Future<void> seedVerifiedPair(WidgetTester t) async {
    await t.runAsync(() async {
      final profile = TranslationRequestProfile(
          mode: TranslationExecutionMode.backend,
          modelId: 'same',
          backendSelection: pair('A'),
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          reasoningControlSuppressed: false);
      final identity = TranslationModelProbeService.shared.identify(
          accountHash: 'account-a',
          settings: provider.settings,
          profile: profile);
      expect(
          await TranslationModelProbeCache.shared.put(
              TranslationModelProbeRecord(
                  fingerprint: identity.fingerprint,
                  status: TranslationModelProbeStatus.verified,
                  checkedAt: DateTime.now(),
                  reasoningControlSuppressed: false),
              expectedAccountHash: 'account-a',
              providerId: null,
              expectedToken: identity.cacheToken),
          isTrue);
    });
  }

  Future<void> awaitPairConfirmation(WidgetTester t, bool cached,
      {bool explicitLegacy = false}) async {
    legacyUnique = true;
    await init(t,
        legacy: true,
        initial: TranslationModelPreference(
            mode: explicitLegacy
                ? TranslationModelPreferenceMode.backend
                : TranslationModelPreferenceMode.followGlobal,
            modelId: explicitLegacy ? 'same' : null,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported));
    if (cached) await seedVerifiedPair(t);
    await open(t);
    await t.tap(find.byKey(const ValueKey('translation_settings_confirm')));
    await pump(t, 8);
    expect(probes, 1);
    expect(posts, isEmpty);
    expect(result, isNull, reason: 'first click must not hand off the pair');
    expect(
        HiCache.getInstance()
            .prefs!
            .getString(TranslationModelPreferenceStore.keyFor('account-a')),
        isNull,
        reason: 'no preference persistence before explicit pair confirmation');
    expect(find.text('确认后端翻译模型'), findsOneWidget);
    expect(
        find.textContaining('本次翻译将使用：Synthetic A (A) · same'), findsOneWidget);
    expect(find.byKey(const ValueKey('translation_warning_continue')),
        findsOneWidget);
    if (cached) {
      expect(find.text('已验证'), findsOneWidget);
      expect(find.textContaining('该模型尚未完成预检。'), findsNothing);
    } else {
      expect(find.textContaining('该模型尚未完成预检。'), findsOneWidget);
    }
  }

  Future<void> importCard(WidgetTester t) async {
    await until(
        t,
        () =>
            find
                .byTooltip('导入角色卡（.json/.png/.zip/.charx）')
                .evaluate()
                .isNotEmpty &&
            t
                    .widget<IconButton>(find.widgetWithIcon(
                        IconButton, Icons.file_upload_outlined))
                    .onPressed !=
                null);
    await t.tap(find.byTooltip('导入角色卡（.json/.png/.zip/.charx）'));
    await pump(t, 10);
    await t.ensureVisible(find.text('使用当前 AI 配置翻译为简体中文'));
    await t.tap(find.text('使用当前 AI 配置翻译为简体中文'));
    await t.tap(find.widgetWithText(FilledButton, '导入'));
    await pump(t, 8);
    await confirm(t);
  }

  tearDown(() async {
    expect(active, isNull);
    await HiDBManager.closeAll();
    cleanup.add({
      'case': owned.path,
      'sqliteClosed': !storage.db.isOpen,
      'posts': posts.length,
      'probes': probes,
      'catalogGets': catalogGets,
      'logout': tokens.clears
    });
    databaseFactory = oldFactory;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
    LoginSdkConfig.reset();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() {
    File('${root.path}/page-evidence.json')
        .writeAsStringSync(jsonEncode(cleanup));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'allSqliteClosed': cleanup.every((x) => x['sqliteClosed'] == true),
      'cases': cleanup.length,
      'modelOnlySyntheticHttp': true,
      'nativePickerMocked': true
    }));
  });
  for (final cached in [false, true]) {
    testWidgets(
        'legacy pair confirmation cached=$cached before handoff/save',
        (t) async => mocked(() async {
              await awaitPairConfirmation(t, cached, explicitLegacy: !cached);
              await t.tap(
                  find.byKey(const ValueKey('translation_warning_continue')));
              await pump(t, 8);
              expect(result?.profile.backendSelection?.providerCode, 'A');
              expect(result?.profile.modelId, 'same');
              expect(preparedOf(result!), isNotNull);
              final raw = HiCache.getInstance().prefs!.getString(
                  TranslationModelPreferenceStore.keyFor('account-a'));
              expect(raw, isNotNull);
              final saved =
                  TranslationModelPreference.fromJson(jsonDecode(raw!));
              if (cached) {
                expect(saved.mode, TranslationModelPreferenceMode.followGlobal);
              } else {
                expect(saved.backendSelection?.providerCode, 'A');
              }
              expect(probes, 1);
              expect(posts, isEmpty);
              expect(tokens.clears, 0);
            }));
    testWidgets(
        'legacy pair confirmation cached=$cached cancel reuses GET',
        (t) async => mocked(() async {
              await awaitPairConfirmation(t, cached);
              await t
                  .tap(find.byKey(const ValueKey('translation_warning_back')));
              await pump(t);
              expect(result, isNull);
              await t.tap(
                  find.byKey(const ValueKey('translation_settings_confirm')));
              await pump(t, 8);
              expect(find.text('确认后端翻译模型'), findsOneWidget);
              expect(probes, 1);
              await t
                  .tap(find.byKey(const ValueKey('translation_warning_back')));
              await pump(t);
              await t.tap(
                  find.byKey(const ValueKey('translation_settings_cancel')));
              await pump(t);
              expect(result, isNull);
              expect(
                  HiCache.getInstance().prefs!.getString(
                      TranslationModelPreferenceStore.keyFor('account-a')),
                  isNull);
              expect(posts, isEmpty);
              expect(tokens.clears, 0);
            }));
    testWidgets(
        'legacy pair confirmation cached=$cached original identity fence',
        (t) async => mocked(() async {
              await awaitPairConfirmation(t, cached);
              if (cached) {
                tokens.account = 'account-b';
              } else {
                BackendConfig.host = 'other.synthetic.invalid';
              }
              await t.tap(
                  find.byKey(const ValueKey('translation_warning_continue')));
              await pump(t, 8);
              expect(result, isNull);
              expect(
                  HiCache.getInstance().prefs!.getString(
                      TranslationModelPreferenceStore.keyFor('account-a')),
                  isNull);
              expect(
                  HiCache.getInstance().prefs!.getString(
                      TranslationModelPreferenceStore.keyFor('account-b')),
                  isNull);
              expect(probes, 1);
              expect(posts, isEmpty);
              expect(tokens.clears, 0);
            }));
  }
  testWidgets(
      'actual dialog preserves explicit B same model and saves typed pair, no model request',
      (t) async => mocked(() async {
            await init(t);
            await open(t);
            await confirm(t);
            expect(result?.profile.backendSelection?.providerCode, 'B');
            expect(result?.preference.backendSelection?.providerCode, 'B');
            expect(preparedOf(result!), isNotNull);
            final raw = HiCache.getInstance()
                .prefs!
                .getString(TranslationModelPreferenceStore.keyFor('account-a'));
            expect(jsonDecode(raw!)['backendSelection']['providerCode'], 'B');
            expect(posts, isEmpty);
            expect(probes, 0);
          }));
  testWidgets(
      'actual typed nested picker selects B and labels provider, cancel/save has no POST',
      (t) async => mocked(() async {
            await init(t, initial: pref('A'));
            await open(t);
            await t.tap(find.byKey(const ValueKey('translation_model_button')));
            await pump(t);
            expect(find.byKey(const ValueKey('configured_backend_pair_picker')),
                findsOneWidget);
            await t.tap(
                find.byKey(const ValueKey('configured_backend_pair_picker')));
            await pump(t);
            await t.tap(find.textContaining('Synthetic B').last);
            await pump(t);
            await confirm(t);
            expect(result?.profile.backendSelection?.providerCode, 'B');
            expect(provider.settings.backendSelection?.providerCode, 'A');
            expect(posts, isEmpty);
          }));
  testWidgets(
      'foreign scope preference remains visible blocked, not auto followGlobal',
      (t) async => mocked(() async {
            final p = pref('B', account: 'foreign');
            final raw = jsonEncode(p.toJson());
            await HiCache.getInstance().setString(
                TranslationModelPreferenceStore.keyFor('account-a'), raw);
            await init(t, initial: p);
            await open(t);
            expect(
                t
                    .widget<FilledButton>(find
                        .byKey(const ValueKey('translation_settings_confirm')))
                    .onPressed,
                isNull);
            expect(result, isNull);
            expect(
                HiCache.getInstance().prefs!.getString(
                    TranslationModelPreferenceStore.keyFor('account-a')),
                raw);
            expect(posts, isEmpty);
          }));
  testWidgets(
      'shape-invalid preference is not replaced by followGlobal',
      (t) async => mocked(() async {
            await init(t,
                initial: const TranslationModelPreference.unavailable());
            await open(t);
            expect(find.textContaining('无法识别'), findsWidgets);
            expect(
                t
                    .widget<FilledButton>(find
                        .byKey(const ValueKey('translation_settings_confirm')))
                    .onPressed,
                isNull);
            expect(posts, isEmpty);
          }));
  testWidgets(
      'legacy followGlobal GET once fixed profile while preference remains follow',
      (t) async => mocked(() async {
            legacyUnique = true;
            await init(t,
                legacy: true,
                initial: const TranslationModelPreference(
                    mode: TranslationModelPreferenceMode.followGlobal,
                    reasoningPolicy: ChatReasoningPolicy.offIfSupported));
            await open(t);
            await confirm(t);
            expect(result?.profile.backendSelection?.providerCode, 'A');
            expect(result?.preference.mode,
                TranslationModelPreferenceMode.followGlobal);
            expect(probes, 1);
            expect(posts, isEmpty);
          }));
  for (final change in ['origin', 'account', 'epoch', 'restore']) {
    testWidgets(
        'late legacy GET $change cannot confirm or save into new scope',
        (t) async => mocked(() async {
              legacyUnique = true;
              getGate = Completer();
              getEntered = Completer();
              await init(t,
                  legacy: true,
                  initial: const TranslationModelPreference(
                      mode: TranslationModelPreferenceMode.followGlobal,
                      reasoningPolicy: ChatReasoningPolicy.offIfSupported));
              await open(t);
              await t.tap(
                  find.byKey(const ValueKey('translation_settings_confirm')));
              await pump(t, 8);
              switch (change) {
                case 'origin':
                  BackendConfig.host = 'other.synthetic.invalid';
                case 'account':
                  tokens.account = 'account-b';
                case 'epoch':
                  ModelCatalog.resetExecutionForTest();
                case 'restore':
                  BackupService.agentExecutionRevision++;
              }
              getGate!.complete();
              await pump(t, 8);
              for (var i = 0; i < 2; i++) {
                if (find
                    .byKey(const ValueKey('translation_warning_continue'))
                    .evaluate()
                    .isNotEmpty) {
                  await t.tap(find
                      .byKey(const ValueKey('translation_warning_continue')));
                  await pump(t, 5);
                }
              }
              expect(result, isNull);
              expect(
                  HiCache.getInstance().prefs!.getString(
                      TranslationModelPreferenceStore.keyFor('account-a')),
                  isNull);
              expect(posts, isEmpty);
            }));
  }
  testWidgets(
      'actual assistant import uses captured A after global selection changes',
      (t) async => mocked(() async {
            postGate = Completer();
            postEntered = Completer();
            await init(t, assistant: true);
            await importCard(t);
            await until(t, () => posts.isNotEmpty);
            provider.settings.backendSelection = pair('B');
            postGate!.complete();
            await until(
                t,
                () =>
                    find.text('Original Card').evaluate().isNotEmpty &&
                    !find.text('正在保存').evaluate().isNotEmpty);
            await pump(t, 12);
            final rows = await t.runAsync(() => dao.getAssistants());
            expect(rows!.length, 1);
            expect(rows.single.prompt, contains('清楚'));
            expect(posts.single['providerCode'], 'A');
            expect(posts.single['model'], 'same');
            expect(probes, 0);
          }));
  testWidgets(
      'actual assistant late origin response has no import/save or pair reassignment',
      (t) async => mocked(() async {
            postGate = Completer();
            postEntered = Completer();
            await init(t, assistant: true);
            await importCard(t);
            await until(t, () => posts.isNotEmpty);
            BackendConfig.host = 'other.synthetic.invalid';
            postGate!.complete();
            await pump(t, 18);
            final rows = await t.runAsync(() => dao.getAssistants());
            expect(rows, isEmpty);
            expect(posts.length, 1);
            expect(posts.single['providerCode'], 'A');
            expect(probes, 0);
          }));
  for (final action in ['继续使用原模型', '更换模型后继续']) {
    testWidgets(
        'actual story history $action preserves profile/attempt/partial and performs no model request',
        (t) async => mocked(() async {
              await init(t, history: true);
              await until(
                  t, () => find.text('History task').evaluate().isNotEmpty);
              await t.tap(find.byTooltip('任务操作').first);
              await pump(t);
              await t.tap(find.text('重试'));
              await pump(t);
              if (action == '更换模型后继续') {
                provider.settings.backendModel = 'other';
                provider.settings.backendSelection = pair('B', model: 'other');
              }
              await t.tap(find.text(action));
              await pump(t, 7);
              if (find
                  .byKey(const ValueKey('translation_settings_confirm'))
                  .evaluate()
                  .isNotEmpty) {
                await confirm(t);
              }
              await pump(t, 8);
              final row = await t.runAsync(() async => (await storage.db.query(
                      taskDao.tableName,
                      where: 'id=?',
                      whereArgs: [historyId]))
                  .single);
              expect(row, historyRow);
              expect(posts, isEmpty);
              expect(probes, 0);
              expect(
                  HiCache.getInstance().prefs!.getString(
                      TranslationModelPreferenceStore.keyFor('account-a')),
                  isNull);
            }));
  }
  testWidgets(
      'confirmed backend preference native wait restores old bytes after origin change',
      (t) async => mocked(() async {
            save = false;
            await init(t);
            await open(t);
            await confirm(t);
            final chosen = result!;
            final run = preparedOf(chosen);
            final kv = PreferenceGate();
            final key = TranslationModelPreferenceStore.keyFor('account-a');
            final before = jsonEncode(pref('A').toJson());
            kv.values[key] = before;
            final store = TranslationModelPreferenceStore(
                storage: kv, currentAccountHash: () => 'account-a');
            Object? failure;
            final future = guardedPreferenceSave(store, chosen.preference,
                    () => run != null && (run as dynamic).isCurrent as bool)
                .catchError((Object e) {
              failure = e;
            });
            await t.runAsync(
                () => kv.started.future.timeout(const Duration(seconds: 2)));
            BackendConfig.host = 'other.synthetic.invalid';
            kv.release.complete();
            await t.runAsync(() => future);
            expect(failure, isNotNull);
            expect(kv.values[key], before);
            expect(store.read('account-a').backendSelection?.providerCode, 'A');
            expect(posts, isEmpty);
          }));
}
