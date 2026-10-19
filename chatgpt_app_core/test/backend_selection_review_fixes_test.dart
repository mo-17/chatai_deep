import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final selections = <String, String>{
    'pair': jsonEncode({
      'version': 1,
      'mode': 'pair',
      'providerCode': 'alpha',
      'modelId': 'same/model',
      'scope': {'accountHash': 'account-a', 'origin': 'http://127.0.0.1:39991'},
    }),
    'follow': jsonEncode({'version': 1, 'mode': 'follow'}),
    'unknown': '  {"version":9,"mode":"future","opaque":"preserve"}  ',
  };
  final connections = <Database>[];
  final resources = <Map<String, Object?>>[];
  final network = _NoNetwork();
  late Directory owned;
  int next = 0;
  setUpAll(() {
    sqfliteFfiInit();
    final nonce = Platform.environment['R2B_SQLITE_NONCE']!;
    owned = Directory(Platform.environment['R2B_SQLITE_ROOT']!);
    expect(owned.path, '/tmp/chatai-r2b-sqlite-$nonce');
    expect(
        jsonDecode(
            File('${owned.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    HttpOverrides.global = network;
  });
  tearDownAll(() async {
    for (final db in connections) {
      if (db.isOpen) await db.close();
    }
    for (final resource in resources) {
      resource['closed'] = true;
    }
    expect(network.calls, 0);
    HttpOverrides.global = null;
    File('${owned.path}/cleanup.json').writeAsStringSync(
        jsonEncode({'databases': resources, 'networkCalls': network.calls}));
  });
  Future<HiDBManager> open() async {
    final path = '${owned.path}/review-${next++}.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    connections.add(db);
    resources.add({'path': path, 'closed': false});
    await db.execute('pragma user_version=2');
    return HiDBManager.test(db);
  }

  ConversationModel conversation(int cid, {int? id, String? raw}) =>
      ConversationModel(
          id: id,
          cid: cid,
          icon: 'x',
          title: 'history',
          backendSelection: BackendSelection.fromStorage(raw));

  for (final entry in selections.entries) {
    test('stale id after no-id cid REPLACE preserves ${entry.key}', () async {
      final storage = await open();
      final dao = await ConversationListDao.create(storage);
      final held = conversation(71);
      await dao.saveConversation(held);
      final oldId = held.id;
      final replacement = conversation(71, raw: entry.value);
      await dao.saveConversation(replacement);
      expect(replacement.id, isNot(oldId));
      expect(
          await storage.db
              .query(dao.tableName, where: 'id = ?', whereArgs: [oldId]),
          isEmpty);
      await dao.saveConversation(held);
      final rows = await storage.db.query(dao.tableName);
      expect(rows, hasLength(1));
      expect(rows.single['cid'], 71);
      expect(rows.single['backendSelection'], entry.value);
    });
  }
  for (final targetExists in [false, true]) {
    test('inconsistent id/cid rejects without merging, target=$targetExists',
        () async {
      final storage = await open();
      final dao = await ConversationListDao.create(storage);
      final other = conversation(72, raw: selections['pair']);
      await dao.saveConversation(other);
      if (targetExists) {
        await dao
            .saveConversation(conversation(71, raw: selections['unknown']));
      }
      final before = await storage.db.query(dao.tableName, orderBy: 'id');
      await expectLater(dao.saveConversation(conversation(71, id: other.id)),
          throwsStateError);
      expect(await storage.db.query(dao.tableName, orderBy: 'id'), before);
    });
  }
  for (final noId in [false, true]) {
    test('NULL preserves normal conversation target, noId=$noId', () async {
      final storage = await open();
      final dao = await ConversationListDao.create(storage);
      final original = conversation(71, raw: selections['pair']);
      await dao.saveConversation(original);
      await dao
          .saveConversation(conversation(71, id: noId ? null : original.id));
      final row = (await storage.db.query(dao.tableName)).single;
      expect(row['backendSelection'], selections['pair']);
    });
  }
  for (final kind in ['follow', 'pair']) {
    test('explicit conversation $kind replaces original selection', () async {
      final storage = await open();
      final dao = await ConversationListDao.create(storage);
      final original = conversation(71, raw: selections['unknown']);
      await dao.saveConversation(original);
      await dao.saveConversation(
          conversation(71, id: original.id, raw: selections[kind]));
      expect((await storage.db.query(dao.tableName)).single['backendSelection'],
          selections[kind]);
    });
  }
  for (final entry in selections.entries) {
    test(
        'checked NULL save returns committed ${entry.key} and reusable snapshot',
        () async {
      final storage = await open();
      final dao = await AssistantDao.create(storage);
      final initial = await dao.saveChecked(AssistantModel(
          name: 'role',
          emoji: 'r',
          prompt: 'p',
          backendSelection: BackendSelection.fromStorage(entry.value)));
      final source = AssistantModel.fromJson(initial.assistant.toJson())
        ..backendSelection = null
        ..prompt = 'edited';
      final result = await dao.saveChecked(source, expected: initial.snapshot);
      final row = (await storage.db.query(dao.tableName)).single;
      expect(row['backendSelection'], entry.value);
      expect(result.assistant.backendSelection?.toSqlValue(), entry.value);
      expect(result.snapshot.matches(row), isTrue);
      expect(result.snapshot.matchesModel(result.assistant), isTrue);
      expect(source.backendSelection, isNull);
      final reopened = AssistantModel.fromJson(result.assistant.toJson())
        ..prompt = 'again';
      final again = await dao.saveChecked(reopened, expected: result.snapshot);
      expect(again.snapshot.matchesModel(again.assistant), isTrue);
      expect(again.assistant.backendSelection?.toSqlValue(), entry.value);
    });
  }
  test('checked explicit follow and pair return committed values', () async {
    final storage = await open();
    final dao = await AssistantDao.create(storage);
    var result = await dao
        .saveChecked(AssistantModel(name: 'role', emoji: 'r', prompt: 'p'));
    for (final kind in ['pair', 'follow']) {
      final source = AssistantModel.fromJson(result.assistant.toJson())
        ..backendSelection = BackendSelection.fromStorage(selections[kind]);
      result = await dao.saveChecked(source, expected: result.snapshot);
      expect(result.snapshot.matchesModel(result.assistant), isTrue);
      expect(result.assistant.backendSelection?.toSqlValue(), selections[kind]);
    }
  });
  test('checked validation failure rolls back and original CAS remains valid',
      () async {
    final storage = await open();
    final dao = await AssistantDao.create(storage);
    final initial = await dao.saveChecked(AssistantModel(
        name: 'role',
        emoji: 'r',
        prompt: 'p',
        backendSelection: BackendSelection.fromStorage(selections['pair'])));
    final source = AssistantModel.fromJson(initial.assistant.toJson())
      ..backendSelection = null
      ..prompt = 'rejected';
    await expectLater(
        dao.saveChecked(source,
            expected: initial.snapshot,
            validateBeforeCommit: (_) async =>
                throw StateError('synthetic reject')),
        throwsStateError);
    expect(
        initial.snapshot
            .matches((await storage.db.query(dao.tableName)).single),
        isTrue);
    final result =
        await dao.saveChecked(initial.assistant, expected: initial.snapshot);
    expect(result.snapshot.matchesModel(result.assistant), isTrue);
  });
}

class _NoNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('R2b review fixture forbids SUT network');
  }
}
