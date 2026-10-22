import 'support/owned_test_directory.dart';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/application/legacy_backend_profile_binding.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R2C_SQLITE_ROOT',
    nonceKey: 'R2C_SQLITE_NONCE',
    legacyPrefix: '/tmp/chatai-r2c-sqlite-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final connections = <Database>[];
  final resources = <Map<String, Object?>>[];
  final network = _NoNetwork();
  late String current;
  late int epoch, probes;
  BackendSelectionBindingScope scope() => BackendSelectionBindingScope.test(
      AgentWorkflowScope(
          accountHash: current,
          currentAccount: () => current,
          currentLoginEpoch: () => epoch,
          currentRestoreRevision: () => 0,
          stableOperation: (action) => action()),
      origin: 'http://127.0.0.1:39991',
      currentOrigin: () => 'http://127.0.0.1:39991');
  BackendSelection pair(BackendSelectionBindingScope s) =>
      BackendSelection.pair(
          providerCode: 'fixture',
          modelId: 'same',
          accountHash: s.accountHash,
          origin: s.origin);
  setUpAll(() {
    sqfliteFfiInit();
    root = ownedFixture.directory;
    HttpOverrides.global = network;
  });
  setUp(() {
    current = 'account-a';
    epoch = 1;
    probes = 0;
  });
  tearDownAll(() async {
    for (final db in connections) {
      if (db.isOpen) await db.close();
    }
    for (final r in resources) {
      r['closed'] = true;
    }
    expect(network.calls, 0);
    HttpOverrides.global = null;
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'databases': resources,
      'sutHttpClientCalls': network.calls,
      'probeEvidence':
          'injected synthetic read-only resolver callback; no real HTTP/JWT'
    }));
  });
  Future<
      (
        StoryTemplateTranslationTaskDao,
        _Reads,
        StoryTemplateTranslationTaskModel
      )> prepare(String? owner) async {
    final path = '${root.path}/owner-${connections.length}.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    connections.add(db);
    resources.add({'path': path, 'createdOwner': owner, 'closed': false});
    final counted = _Reads(db);
    final storage = HiDBManager.test(counted);
    StoryTemplateTranslationTaskDao dao;
    if (owner == null) {
      dao = await StoryTemplateTranslationTaskDao.create(storage);
    } else {
      // 旧基线没有可选标签参数，仍使用它真实的旧工厂；不替换生产绑定实现。
      try {
        dao = await Function.apply(
            StoryTemplateTranslationTaskDao.create,
            [storage],
            {#accountHash: owner}) as StoryTemplateTranslationTaskDao;
      } on NoSuchMethodError {
        dao = await StoryTemplateTranslationTaskDao.create(storage);
      }
    }
    final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'account-a source',
        sourcePayload: '{}',
        requestProfile: jsonEncode({
          'version': 1,
          'mode': 'backend',
          'providerId': null,
          'modelId': 'same',
          'reasoningPolicy': 'providerDefault',
          'reasoningControlSuppressed': false
        }));
    await dao.saveTask(task);
    return (dao, counted, task);
  }

  for (final owner in ['account-a', null]) {
    for (final direct in [false, true]) {
      test(
          'wrong/unowned DAO refuses before reads/probe/transaction, owner=$owner direct=$direct',
          () async {
        final (dao, counted, task) = await prepare(owner);
        final before = (await counted.inner.query(dao.tableName)).single;
        // 真实保留 A DAO，再切到 B，并捕获一个完全有效的 B scope。
        if (owner != null) {
          current = 'account-b';
          epoch++;
        }
        final original = scope();
        original.verify();
        counted.reset();
        final operation = Future.sync(() => direct
            ? dao.bindLegacyBackendProfile(original,
                expected: before, selection: pair(original))
            : LegacyBackendProfileBinding(probe: (s, m) async {
                probes++;
                return pair(s);
              }).translation(dao, original, task.id!));
        await expectLater(operation, throwsA(isA<WorkflowStale>()));
        expect(counted.reads, 0);
        expect(counted.transactions, 0);
        expect(probes, 0);
        expect((await counted.inner.query(dao.tableName)).single, before);
      });
    }
  }
  for (final direct in [false, true]) {
    test(
        'same immutable account binds through ${direct ? 'direct DAO' : 'coordinator'}',
        () async {
      final (dao, counted, task) = await prepare('account-a');
      final before = (await counted.inner.query(dao.tableName)).single;
      final original = scope();
      counted.reset();
      final bound = direct
          ? await dao.bindLegacyBackendProfile(original,
              expected: before, selection: pair(original))
          : await LegacyBackendProfileBinding(probe: (s, m) async {
              probes++;
              return pair(s);
            }).translation(dao, original, task.id!);
      expect(jsonDecode(bound.requestProfile)['backendSelection'],
          pair(original).toSafeJson());
      expect(counted.transactions, 1);
      expect(counted.reads, greaterThan(0));
      expect(probes, direct ? 0 : 1);
    });
  }
  test('untagged DAO still supports old save/claim behavior', () async {
    final (dao, counted, task) = await prepare(null);
    expect(
        await dao.claimTask(task.id!,
            leaseOwner: 'synthetic', leaseDuration: const Duration(seconds: 5)),
        isTrue);
    final row = (await counted.inner.query(dao.tableName)).single;
    expect(row['attempts'], 1);
    expect(jsonDecode(row['requestProfile'] as String)['version'], 1);
  });
  final modernShapes = <String>[
    jsonEncode([
      {
        'version': 2,
        'backendSelection': {'version': 1, 'mode': 'follow'}
      }
    ]),
    jsonEncode([
      [
        {
          'backendSelection': {'version': 1}
        }
      ]
    ]),
    jsonEncode('{"version":2,"backendSelection":{}}'),
    r'[{"\u0076ersion":2}]',
    jsonEncode(['backendSelection']),
    jsonEncode('version'),
  ];
  for (var i = 0; i < modernShapes.length; i++) {
    test(
        'nonobject modern shape $i unavailable/raw unchanged and no global snapshot',
        () {
      final raw = modernShapes[i], kv = _Memory();
      final key = TranslationModelPreferenceStore.keyFor('account-a');
      kv.values[key] = raw;
      final store = TranslationModelPreferenceStore(
          storage: kv, currentAccountHash: () => current);
      final preference = store.read('account-a');
      expect(preference.mode, TranslationModelPreferenceMode.backend);
      expect(() => preference.toJson(), throwsFormatException);
      final global = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = 'global-only';
      expect(() => TranslationModelResolver.snapshot(global, preference),
          throwsFormatException);
      expect(kv.values[key], raw);
      expect(kv.writes, 0);
    });
  }
  for (final raw in [
    '{',
    '[]',
    'null',
    jsonEncode([
      {'mode': 'local'}
    ])
  ]) {
    test('legacy shape without modern marker keeps previous fallback: $raw',
        () {
      final kv = _Memory(),
          key = TranslationModelPreferenceStore.keyFor('account-a');
      kv.values[key] = raw;
      final p = TranslationModelPreferenceStore(
          storage: kv, currentAccountHash: () => current).read('account-a');
      expect(p.mode, TranslationModelPreferenceMode.followGlobal);
      final global = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = 'global-only';
      expect(
          TranslationModelResolver.snapshot(global, p).modelId, 'global-only');
      expect(kv.values[key], raw);
      expect(kv.writes, 0);
    });
  }
}

class _Memory implements TranslationPreferenceKeyValueStore {
  final values = <String, Object?>{};
  int writes = 0;
  @override
  Object? read(String key) => values[key];
  @override
  Future<bool> writeString(String key, String value) async {
    writes++;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    writes++;
    values.remove(key);
    return true;
  }
}

class _NoNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('SUT real HTTP forbidden');
  }
}

class _Reads implements Database {
  final Database inner;
  int reads = 0, transactions = 0;
  _Reads(this.inner);
  void reset() {
    reads = 0;
    transactions = 0;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) {
    transactions++;
    return inner.transaction(
        (tx) => action(_ReadTransaction(tx, () => reads++)),
        exclusive: exclusive);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      inner.execute(sql, arguments);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      inner.rawUpdate(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) {
    reads++;
    return inner.rawQuery(sql, arguments);
  }

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
      int? offset}) {
    reads++;
    return inner.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
  }

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      inner.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      inner.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReadTransaction implements Transaction {
  final Transaction inner;
  final void Function() read;
  _ReadTransaction(this.inner, this.read);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      inner.rawUpdate(sql, arguments);
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
      int? offset}) {
    read();
    return inner.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      inner.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
