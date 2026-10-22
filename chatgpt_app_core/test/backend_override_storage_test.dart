import 'support/owned_test_directory.dart';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/assistant_management_session.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B1_ROOT',
    nonceKey: 'R3B1_NONCE',
    legacyPrefix: '/tmp/chatai-r3b1-exclusive-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HiDBManager storage;
  late ConversationListDao dao;
  late AssistantDao assistants;
  int serial = 0;
  int closed = 0;
  bool current = true;
  BackendSelection pair(String code) => BackendSelection.pair(
      providerCode: code,
      modelId: 'same',
      accountHash: 'account-a',
      origin: 'https://backend.synthetic.invalid');
  setUpAll(() {
    root = ownedFixture.directory;
    sqfliteFfiInit();
  });
  setUp(() async {
    current = true;
    LoginDao.resetHooksForTest();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'backend.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: PairTokens(),
        onLogoutNavigate: () {}));
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        '${root.path}/storage-${serial++}.sqlite',
        options: OpenDatabaseOptions(singleInstance: false)));
    dao = await ConversationListDao.create(storage);
    assistants = await AssistantDao.create(storage);
  });
  tearDown(() async {
    await storage.db.close();
    expect(storage.db.isOpen, isFalse);
    closed++;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
  });
  tearDownAll(() {
    File('${root.path}/cleanup.json').writeAsStringSync(
        jsonEncode({'sqliteClosed': closed, 'allClosed': true}));
  });
  void check() {
    if (!current) throw StateError('synthetic original identity expired');
  }

  Future<ConversationModel> conversation() async {
    final m = ConversationModel(
        cid: 1,
        title: 'S',
        icon: '',
        modelProviderId: 'local',
        modelId: ' raw local ',
        backendSelection: pair('A'));
    m.id = await dao.saveConversation(m);
    return m;
  }

  test(
      'explicit pair/follow save only backend column and can reopen, original local fields unchanged',
      () async {
    final m = await conversation();
    final before = Map.of((await storage.db.query(dao.tableName)).single);
    for (final value in [pair('B'), BackendSelection.follow()]) {
      final snapshot = await dao.backendSelectionSnapshot(m, validate: check);
      await dao.saveBackendSelectionChecked(m, value, snapshot,
          validate: check);
      final row = (await storage.db.query(dao.tableName)).single;
      final other = Map.of(row)..remove('backendSelection');
      expect(other, Map.of(before)..remove('backendSelection'));
      m.backendSelection = value;
      final reopened = ConversationModel.fromJson(row);
      expect(reopened.backendSelection!.toSqlText(), value.toSqlText());
      expect(m.modelProviderId, 'local');
      expect(m.modelId, ' raw local ');
    }
  });
  for (final mutation in ['row', 'memory', 'identity', 'deleted']) {
    test(
        'conversation $mutation race rejects without replacing current backend selection',
        () async {
      final m = await conversation();
      final snapshot = await dao.backendSelectionSnapshot(m, validate: check);
      if (mutation == 'row') {
        await storage.db.update(dao.tableName, {'modelId': 'new-local'},
            where: 'id=?', whereArgs: [m.id]);
      }
      if (mutation == 'memory') m.backendSelection = pair('C');
      if (mutation == 'identity') current = false;
      if (mutation == 'deleted') {
        await storage.db
            .delete(dao.tableName, where: 'id=?', whereArgs: [m.id]);
      }
      await expectLater(
          dao.saveBackendSelectionChecked(m, pair('B'), snapshot,
              validate: check),
          throwsA(anything));
      final rows = await storage.db.query(dao.tableName);
      if (rows.isNotEmpty) {
        expect(
            BackendSelection.fromStorage(rows.single['backendSelection'])!
                .providerCode,
            'A');
      }
    });
  }
  test(
      'actual SQLite update rolled back when original identity changes after final update await',
      () async {
    final m = await conversation();
    final wrapped =
        HiDBManager.test(_FencedDb(storage.db, () => current = false));
    final guarded = await ConversationListDao.create(wrapped);
    final snapshot = await guarded.backendSelectionSnapshot(m, validate: check);
    await expectLater(
        guarded.saveBackendSelectionChecked(m, pair('B'), snapshot,
            validate: check),
        throwsA(anything));
    final row = (await storage.db.query(dao.tableName)).single;
    expect(BackendSelection.fromStorage(row['backendSelection'])!.providerCode,
        'A');
  });
  test(
      'unsaved conversation cannot adopt same-cid row created while selector open',
      () async {
    final m = ConversationModel(cid: 4, icon: '', modelId: 'local');
    final snap = await dao.backendSelectionSnapshot(m, validate: check);
    await storage.db.insert(
        dao.tableName,
        ConversationModel(cid: 4, icon: '', title: 'other').toJson()
          ..remove('id'));
    await expectLater(
        dao.saveBackendSelectionChecked(m, pair('B'), snap, validate: check),
        throwsA(isA<ConversationBackendSelectionStale>()));
  });
  test(
      'assistant committed pair carried into accepted model and CAS stale rejects second editor',
      () async {
    final m = AssistantModel(
        name: 'S',
        providerId: 'local',
        model: ' raw local ',
        backendSelection: pair('A'));
    final first = await assistants.saveChecked(m);
    final original = first.assistant;
    final next = AssistantModel.fromJson(original.toJson())
      ..backendSelection = BackendSelection.follow();
    final saved = await assistants.saveChecked(next, expected: first.snapshot);
    acceptSavedAssistant(original, saved.assistant);
    expect(original.backendSelection!.isFollow, isTrue);
    expect(original.providerId, 'local');
    expect(original.model, ' raw local ');
    expect(saved.snapshot.matchesModel(original), isTrue);
    await expectLater(
        assistants.saveChecked(next..backendSelection = pair('C'),
            expected: first.snapshot),
        throwsA(isA<AssistantMutationStale>()));
  });
  test(
      'untouched malformed/foreign storage retains bytes, modern update does not become legacy',
      () async {
    for (final raw in [
      'unknown-version',
      BackendSelection.pair(
              providerCode: 'foreign',
              modelId: 'same',
              accountHash: 'other-account',
              origin: 'https://other.synthetic.invalid')
          .toSqlText()
    ]) {
      final m = ConversationModel(
          cid: 10 + serial,
          title: 'S',
          icon: '',
          backendSelection: BackendSelection.fromStorage(raw));
      m.id = await dao.saveConversation(m);
      final snap = await dao.backendSelectionSnapshot(m, validate: check);
      await dao.saveBackendSelectionChecked(m, BackendSelection.follow(), snap,
          validate: check);
      expect(m.backendSelection!.toSqlText(), raw);
      final row = (await storage.db
              .query(dao.tableName, where: 'id=?', whereArgs: [m.id]))
          .single;
      expect(BackendSelection.fromStorage(row['backendSelection'])!.isFollow,
          isTrue);
      serial++;
    }
  });
}

// SQL本身真实执行，只注入UPDATE返回后的原身份变化。
class _FencedDb implements Database {
  final Database db;
  final void Function() afterUpdate;
  _FencedDb(this.db, this.afterUpdate);
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
          {bool? exclusive}) =>
      db.transaction((tx) => action(_FencedTx(tx, afterUpdate)),
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

class _FencedTx implements Transaction {
  final Transaction tx;
  final void Function() afterUpdate;
  _FencedTx(this.tx, this.afterUpdate);
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
      tx.query(table,
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
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    final changed = await tx.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
    afterUpdate();
    return changed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused synthetic transaction operation');
}
