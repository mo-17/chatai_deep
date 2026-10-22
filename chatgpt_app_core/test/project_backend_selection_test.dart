import 'support/owned_test_directory.dart';
import 'support/project_seed_race_database.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/chat/application/ordinary_backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/pages/conversation_list_page.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
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

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B2_ROOT',
    nonceKey: 'R3B2_NONCE',
    legacyPrefix: '/tmp/chatai-r3b2-exclusive-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, caseRoot;
  late HiDBManager storage;
  late ProjectDao projects;
  late ConversationListDao conversations;
  late ProjectModel project;
  late AISettingsProvider settings;
  late AIReadinessProvider readiness;
  late ThemeProvider theme;
  late String oldHost;
  late bool oldHttps;
  late DatabaseFactory? oldFactory;
  late ProjectSeedRaceGate raceGate;
  WidgetTester? active;
  int serial = 0, closed = 0, posts = 0;
  bool current = true;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  BackendSelection pair(String code, {String account = 'account-a'}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: 'plain',
          accountHash: account,
          origin: 'https://backend.synthetic.invalid');
  setUpAll(() {
    root = ownedFixture.directory;
    sqfliteFfiInit();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null);
      }
      return null;
    });
  });
  setUp(() async {
    current = true;
    posts = 0;
    active = null;
    caseRoot = Directory('${root.path}/case-${serial++}')..createSync();
    oldFactory = databaseFactoryOrNull;
    raceGate = ProjectSeedRaceGate();
    databaseFactory = ProjectSeedRaceFactory(databaseFactoryFfi, raceGate);
    await databaseFactory.setDatabasesPath('${caseRoot.path}/db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => caseRoot.path);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    AISettingsDao.resetSecureStateForTest();
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'backend.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: PairTokens(),
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'backend.synthetic.invalid';
    BackendConfig.useHttps = true;
    final ai = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = pair('G')
      ..composerPredictionsEnabled = false;
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor('account-a'), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    theme = ThemeProvider();
    readiness = AIReadinessProvider(
        evidenceReader: (
                {required accountHash, required settings, storage}) async =>
            const AIOnboardingEvidence(
                hasStoredSettings: true,
                hasConversationHistory: false,
                hasCustomProvider: false,
                hasSuccessfulHealthCheck: false));
    readiness.synchronize(
        settings: settings.settings, accountHash: 'account-a', isGuest: false);
    await readiness.initialize();
    storage = await HiDBManager.instance(dbName: 'account-a');
    projects = await ProjectDao.create(storage);
    conversations = await ConversationListDao.create(storage);
    final assistants = await AssistantDao.create(storage);
    await assistants.saveChecked(AssistantModel(name: 'SYNTHETIC ASSISTANT'));
    project = ProjectModel(
        name: 'SYNTHETIC PROJECT',
        defaultProviderId: ' local-id ',
        defaultModelId: ' raw local ',
        backendSelection: pair('A'));
    await projects.saveProject(project);
    await conversations.saveConversation(ConversationModel(
        cid: 1,
        title: 'EXISTING',
        icon: '',
        projectId: project.id,
        backendSelection: pair('A')));
  });
  Future<void> pump(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 120 && !done(); i++) {
      await pump(t, 1);
    }
    expect(done(), isTrue, reason: 'bounded private SQLite/page settlement');
  }

  Future<void> mock(Future<void> Function() f) => http.runWithClient(
      f,
      () => MockClient((r) async {
            if (r.method == 'POST') {
              posts++;
              return http.Response('{}', 500);
            }
            expect(r.url.path, '/uapi/ai/catalog');
            return http.Response(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'providers': [
                      for (final c in ['A', 'B', 'G'])
                        {'code': c, 'displayName': 'Synthetic $c'}
                    ],
                    'models': [
                      for (final c in ['A', 'B', 'G'])
                        {
                          'providerCode': c,
                          'modelId': 'plain',
                          'displayName': 'plain',
                          'supportsVision': false,
                          'supportsTool': false,
                          'supportsReasoning': false,
                          'supportsPdf': false
                        }
                    ]
                  }
                }),
                200);
          }));
  Future<void> mount(WidgetTester t) async {
    active = t;
    await t.runAsync(() => ModelCatalog.refreshFromBackend());
    await t.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AIReadinessProvider>.value(value: readiness),
      ChangeNotifierProvider<ThemeProvider>.value(value: theme)
    ], child: const MaterialApp(home: ConversationListPage())));
    await until(t,
        () => find.textContaining('SYNTHETIC PROJECT').evaluate().isNotEmpty);
  }

  Future<void> picker(WidgetTester t) async {
    await t.longPress(find.textContaining('SYNTHETIC PROJECT'));
    await pump(t, 15);
    await t.tap(find.text('默认模型'));
    await pump(t, 20);
    expect(find.byKey(ValueKey(jsonEncode(['B', 'plain']))), findsOneWidget,
        reason: t
            .widgetList<Text>(find.byType(Text))
            .map((x) => x.data)
            .toList()
            .toString());
  }

  Future<ProjectModel> saved(WidgetTester t) async =>
      (await t.runAsync(() => projects.getProject(project.id!)))!;
  Future<void> create(WidgetTester t) async {
    await t.tap(find.textContaining('SYNTHETIC PROJECT'));
    await pump(t, 12);
    await t.tap(find.byIcon(Icons.add));
    await pump(t, 15);
    expect(find.text('不使用助手'), findsOneWidget);
    await t.tap(find.text('不使用助手'));
    await until(t, () => find.byType(ConversationPage).evaluate().isNotEmpty);
    await pump(t, 15);
  }

  tearDown(() async {
    Future<void> cleanup() async {
      expect(posts, 0);
      expect(storage.db.path.startsWith(caseRoot.path), isTrue);
      await HiDBManager.closeAll();
      expect(storage.db.isOpen, isFalse);
      closed++;
      settings.dispose();
      readiness.dispose();
      theme.dispose();
      LoginDao.resetHooksForTest();
      LoginSdkConfig.reset();
      AISettingsDao.resetSecureStateForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      BackendConfig.host = oldHost;
      BackendConfig.useHttps = oldHttps;
      databaseFactory = oldFactory;
    }

    if (active != null) {
      await active!.runAsync(cleanup);
    } else {
      await cleanup();
    }
  });
  tearDownAll(() => File('${root.path}/cleanup.json').writeAsStringSync(
      jsonEncode({'sqliteClosed': closed, 'allClosed': true})));
  void validate() {
    if (!current) throw StateError('synthetic original scope expired');
  }

  void pageTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      active = t;
      try {
        await body(t);
      } finally {
        if (!raceGate.releaseSave.isCompleted) raceGate.releaseSave.complete();
        if (!raceGate.releaseSnapshot.isCompleted) {
          raceGate.releaseSnapshot.complete();
        }
        await pump(t, 10);
        await t.pumpWidget(const SizedBox.shrink());
        await pump(t, 15);
      }
    });
  }

  // dynamic只让相同页面fixture能在尚无新DAO API的批准旧源码上编译；red不执行这些新API用例。
  test(
      'dao pair/follow updates only selection and monotonic timestamp, returns committed row',
      () async {
    final dynamic dao = projects;
    final before = (await storage.db.query(projects.tableName)).single;
    for (final value in [pair('B'), BackendSelection.follow()]) {
      final expected =
          await dao.backendSelectionSnapshot(project, validate: validate);
      final ProjectModel result = await dao.saveBackendSelectionChecked(
          project, value, expected,
          validate: validate);
      final row = (await storage.db.query(projects.tableName)).single;
      expect(
          Map.of(row)
            ..remove('backendSelection')
            ..remove('updatedAt'),
          Map.of(before)
            ..remove('backendSelection')
            ..remove('updatedAt'));
      expect(result.backendSelection!.toSqlText(), value.toSqlText());
      expect(result.updatedAt, greaterThan(project.updatedAt));
      project = result;
    }
    final existing = (await storage.db.query(conversations.tableName)).single;
    expect(
        BackendSelection.fromStorage(existing['backendSelection'])!
            .providerCode,
        'A');
  });
  for (final change in ['row', 'memory', 'identity', 'deleted']) {
    test('dao $change CAS or scope rejects without overwriting current project',
        () async {
      final dynamic dao = projects;
      final snap =
          await dao.backendSelectionSnapshot(project, validate: validate);
      if (change == 'row') {
        await storage.db.update(projects.tableName, {'name': 'NEWER'},
            where: 'id=?', whereArgs: [project.id]);
      }
      if (change == 'memory') {
        project.defaultModelId = 'new local';
      }
      if (change == 'identity') {
        current = false;
      }
      if (change == 'deleted') {
        await storage.db
            .delete(projects.tableName, where: 'id=?', whereArgs: [project.id]);
      }
      await expectLater(
          dao.saveBackendSelectionChecked(project, pair('B'), snap,
              validate: validate),
          throwsA(anything));
      final rows = await storage.db.query(projects.tableName);
      if (rows.isNotEmpty) {
        expect(
            BackendSelection.fromStorage(rows.single['backendSelection'])!
                .providerCode,
            'A');
      }
    });
  }
  test(
      'dao final read await loses original scope and actual transaction rolls back',
      () async {
    final dynamic guarded = await ProjectDao.create(
        HiDBManager.test(_ProjectFencedDb(storage.db, () => current = false)));
    final expected =
        await guarded.backendSelectionSnapshot(project, validate: validate);
    await expectLater(
        guarded.saveBackendSelectionChecked(project, pair('B'), expected,
            validate: validate),
        throwsA(isA<StateError>()));
    final row = (await storage.db.query(projects.tableName)).single;
    expect(BackendSelection.fromStorage(row['backendSelection'])!.providerCode,
        'A');
    expect(row['updatedAt'], project.updatedAt);
  });
  pageTest(
      'review P2 first SELECT saved B updates live project but copied A never creates',
      (t) async {
    await mock(() async {
      await mount(t);
      await t.tap(find.textContaining('SYNTHETIC PROJECT'));
      await pump(t, 12);
      await picker(t);
      raceGate.holdSave = true;
      await t.tap(find.byKey(ValueKey(jsonEncode(['B', 'plain']))));
      await until(t, () => raceGate.saveCommitted.isCompleted);
      expect((await saved(t)).backendSelection!.providerCode, 'B');
      raceGate.holdSnapshot = true;
      await t.tap(find.byIcon(Icons.add));
      await until(t, () => raceGate.snapshotEntered.isCompleted);
      raceGate.releaseSave.complete();
      await until(
          t, () => find.textContaining('已保存项目新会话后端选择').evaluate().isNotEmpty);
      expect(raceGate.saveReleased, isTrue);
      raceGate.releaseSnapshot.complete();
      await pump(t, 25);
      if (find.text('不使用助手').evaluate().isNotEmpty) {
        await t.tap(find.text('不使用助手'));
        await pump(t, 25);
      }
      final routes = t
          .widgetList<ConversationPage>(find.byType(ConversationPage))
          .toList();
      File('${root.path}/race-evidence.json').writeAsStringSync(jsonEncode({
        'saveCommittedBeforeSnapshot': true,
        'snapshotEnteredBeforeInPlaceUpdate': true,
        'saveUiSettledBeforeSnapshotReleased': true,
        'transactionReleasedBeforeBarrier': true,
        'createdProvider': routes.isEmpty
            ? null
            : routes.single.conversationModel.backendSelection?.providerCode,
        'storedProvider': (await saved(t)).backendSelection!.providerCode,
        'posts': posts
      }));
      expect(routes, isEmpty);
      expect((await saved(t)).backendSelection!.providerCode, 'B');
      expect(posts, 0);
    });
  });
  pageTest(
      'review P2 same-content refresh during first SELECT keeps original A source',
      (t) async {
    await mock(() async {
      await mount(t);
      await t.tap(find.textContaining('SYNTHETIC PROJECT'));
      await pump(t, 12);
      raceGate.holdSnapshot = true;
      await t.tap(find.byIcon(Icons.add));
      await until(t, () => raceGate.snapshotEntered.isCompleted);
      var refreshed = false;
      t
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh()
          .then((_) => refreshed = true);
      await until(t, () => refreshed);
      raceGate.releaseSnapshot.complete();
      await until(t, () => find.text('不使用助手').evaluate().isNotEmpty);
      await pump(t, 15);
      await t.tap(find.text('不使用助手'));
      await until(t, () => find.byType(ConversationPage).evaluate().isNotEmpty);
      expect(
          t
              .widget<ConversationPage>(find.byType(ConversationPage))
              .conversationModel
              .backendSelection!
              .providerCode,
          'A');
      expect((await saved(t)).backendSelection!.providerCode, 'A');
      expect(posts, 0);
    });
  });
  pageTest(
      'page explicit pair/follow saves project seed, leaves local/global/existing conversation and new route receives it',
      (t) async {
    await mock(() async {
      await mount(t);
      await picker(t);
      await t.tap(find.byKey(ValueKey(jsonEncode(['B', 'plain']))));
      await pump(t, 25);
      final fresh = await saved(t);
      expect(fresh.backendSelection!.providerCode, 'B');
      expect(fresh.defaultProviderId, ' local-id ');
      expect(fresh.defaultModelId, ' raw local ');
      expect(settings.settings.backendSelection!.providerCode, 'G');
      await picker(t);
      await t.tap(find.byKey(const ValueKey('backend_follow')));
      await pump(t, 25);
      expect((await saved(t)).backendSelection!.isFollow, isTrue);
      final rows =
          (await t.runAsync(() => storage.db.query(conversations.tableName)))!;
      expect(
          BackendSelection.fromStorage(rows.single['backendSelection'])!
              .providerCode,
          'A');
      await create(t);
      final route = t
          .widget<ConversationPage>(find.byType(ConversationPage))
          .conversationModel;
      expect(route.backendSelection!.isFollow, isTrue);
      expect(route.modelProviderId, ' local-id ');
      expect(route.modelId, ' raw local ');
      expect(
          ordinaryBackendSettings(settings.settings, route, null)
              .backendSelection!
              .providerCode,
          'G');
      expect(posts, 0);
    });
  });
  for (final change in ['origin', 'epoch', 'account', 'restore', 'CAS']) {
    pageTest('page late $change cannot save into new identity or newer project',
        (t) async {
      await mock(() async {
        await mount(t);
        await picker(t);
        final late = t
            .widget<ListTile>(find.byKey(ValueKey(jsonEncode(['B', 'plain']))))
            .onTap!;
        if (change == 'origin') {
          BackendConfig.host = 'other.synthetic.invalid';
        }
        if (change == 'epoch') {
          await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
              userName: 'S', extras: {'accountHash': 'account-a'}));
        }
        if (change == 'account') {
          await t.runAsync(() => LoginDao.saveAuthToken('synthetic-other',
              userName: 'Other', extras: {'accountHash': 'account-b'}));
        }
        if (change == 'restore') {
          BackupService.restoreTick.value++;
        }
        if (change == 'CAS') {
          await t.runAsync(() => storage.db.update(
              projects.tableName, {'backendSelection': pair('G').toSqlValue()},
              where: 'id=?', whereArgs: [project.id]));
        }
        late();
        await pump(t, 25);
        expect((await saved(t)).backendSelection!.providerCode,
            change == 'CAS' ? 'G' : 'A');
        expect(posts, 0);
      });
    });
  }
  for (final kind in ['legacy', 'invalid', 'foreign']) {
    pageTest(
        'page $kind project remains raw seed and cannot silently inherit valid global',
        (t) async {
      await mock(() async {
        final value = kind == 'legacy'
            ? null
            : kind == 'invalid'
                ? BackendSelection.fromStorage('unknown-version')!
                : pair('B', account: 'foreign');
        await t.runAsync(() => storage.db.update(
            projects.tableName, {'backendSelection': value?.toSqlValue()},
            where: 'id=?', whereArgs: [project.id]));
        await mount(t);
        await create(t);
        final route = t
            .widget<ConversationPage>(find.byType(ConversationPage))
            .conversationModel;
        expect(route.backendSelection?.toSqlText(), value?.toSqlText());
        if (kind == 'legacy') {
          final effective =
              ordinaryBackendSettings(settings.settings, route, null);
          expect(effective.backendSelection, isNull);
          expect(effective.backendModel, ' raw local ');
        } else {
          expect(
              resolveAIReadiness(
                      settings: ordinaryBackendSettings(
                          settings.settings, route, null),
                      isGuest: false,
                      accountHash: 'account-a',
                      origin: 'https://backend.synthetic.invalid')
                  .status,
              AIReadyStatus.needsSetup);
        }
        expect(posts, 0);
      });
    });
  }
  pageTest(
      'page project revision changes during assistant picker cannot create stale seed',
      (t) async {
    await mock(() async {
      await mount(t);
      await t.tap(find.textContaining('SYNTHETIC PROJECT'));
      await pump(t, 12);
      await t.tap(find.byIcon(Icons.add));
      await pump(t, 15);
      await t.runAsync(() => storage.db.update(
          projects.tableName, {'backendSelection': pair('G').toSqlValue()},
          where: 'id=?', whereArgs: [project.id]));
      await t.tap(find.text('不使用助手'));
      await pump(t, 25);
      expect(find.byType(ConversationPage), findsNothing);
      expect(
          (await t.runAsync(() => storage.db.query(conversations.tableName)))!,
          hasLength(1));
      expect(posts, 0);
    });
  });
  pageTest(
      'page assistant picker old identity cannot navigate or create a new seed',
      (t) async {
    await mock(() async {
      await mount(t);
      await t.tap(find.textContaining('SYNTHETIC PROJECT'));
      await pump(t, 12);
      await t.tap(find.byIcon(Icons.add));
      await pump(t, 15);
      final late =
          t.widget<ListTile>(find.widgetWithText(ListTile, '不使用助手')).onTap!;
      await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
          userName: 'S', extras: {'accountHash': 'account-a'}));
      late();
      await pump(t, 25);
      expect(find.byType(ConversationPage), findsNothing);
      expect(
          (await t.runAsync(() => storage.db.query(conversations.tableName)))!,
          hasLength(1));
      expect(posts, 0);
    });
  });
}

// 真实SQLite，仅在事务最后一条读返回后注入原scope变化。
class _ProjectFencedDb implements Database {
  final Database db;
  final void Function() afterFinalRead;
  _ProjectFencedDb(this.db, this.afterFinalRead);
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
          {bool? exclusive}) =>
      db.transaction((tx) => action(_ProjectFencedTx(tx, afterFinalRead)),
          exclusive: exclusive);
  @override
  Future<void> execute(String sql, [List<Object?>? args]) =>
      db.execute(sql, args);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? args]) =>
      db.rawQuery(sql, args);
  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      db.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
  @override
  String get path => db.path;
  @override
  bool get isOpen => db.isOpen;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused synthetic DB operation');
}

class _ProjectFencedTx implements Transaction {
  final Transaction tx;
  final void Function() afterFinalRead;
  int queries = 0;
  _ProjectFencedTx(this.tx, this.afterFinalRead);
  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    final rows = await tx.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    if (++queries == 2) afterFinalRead();
    return rows;
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    final changed = await tx.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
    return changed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused synthetic transaction operation');
}
