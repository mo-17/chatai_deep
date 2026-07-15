import 'dart:convert';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  Future<HiDBManager> newDb() async => HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
      );

  Future<List<String>> columns(Database db, String table) async =>
      (await db.rawQuery('pragma table_info($table)'))
          .map((row) => '${row['name']}')
          .toList();

  test('sidecar schema 幂等创建且不修改任何业务表列', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table tb_project (id integer primary key, name text, updatedAt integer)',
    );
    final before = await columns(storage.db, 'tb_project');

    await SyncV2Schema.ensure(storage.db);
    await SyncV2Schema.ensure(storage.db);

    final tables = (await storage.db.rawQuery(
      "select name from sqlite_master where type = 'table'",
    ))
        .map((row) => '${row['name']}')
        .toSet();
    expect(tables, containsAll(SyncV2Schema.tableNames));
    expect(await columns(storage.db, 'tb_project'), before);

    final indexes = (await storage.db.rawQuery(
      "select name from sqlite_master where type = 'index'",
    ))
        .map((row) => '${row['name']}')
        .toSet();
    expect(indexes, containsAll(SyncV2Schema.indexNames));
    expect(
      await columns(storage.db, SyncV2Schema.outboxTable),
      containsAll(['ackReason', 'expectedRevision', 'ackRemoteEvidence']),
    );
    expect(
      await columns(storage.db, SyncV2Schema.conflictTable),
      containsAll([
        'remoteSequence',
        'remoteChangeId',
        'remoteParentChangeId',
        'remoteDeviceId',
      ]),
    );
    await storage.db.close();
  });

  test('直接传 Database 时 schema 后段失败会回滚已创建的 sidecar', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table ${SyncV2Schema.outboxTable} (changeId text primary key)',
    );

    await expectLater(
      SyncV2Schema.ensure(storage.db),
      throwsA(anyOf(isA<DatabaseException>(), isA<StateError>())),
    );

    final tables = (await storage.db.rawQuery(
      "select name from sqlite_master where type = 'table'",
    ))
        .map((row) => '${row['name']}')
        .toSet();
    expect(tables, contains(SyncV2Schema.outboxTable));
    expect(
      tables.intersection(SyncV2Schema.tableNames.toSet()),
      {SyncV2Schema.outboxTable},
    );
    await storage.db.close();
  });

  test('sidecar 创建前后 v1 导出 request body 完全一致', () async {
    final storage = await newDb();
    final dao = await ProjectDao.create(storage);
    final project = ProjectModel(name: '兼容性项目')
      ..createdAt = 10
      ..updatedAt = 20;
    await dao.saveProject(project);
    await storage.db.update(
      'tb_project',
      {'createdAt': 10, 'updatedAt': 20},
      where: 'id = ?',
      whereArgs: [project.id],
    );
    final sync = LocalSyncService(storage);

    final before = jsonEncode(
      (await sync.exportChanges()).map(_v1WireJson).toList(),
    );
    await SyncV2Schema.ensure(storage.db);
    final after = jsonEncode(
      (await sync.exportChanges()).map(_v1WireJson).toList(),
    );

    expect(after, before);
    expect(after, isNot(contains('syncId')));
    expect(after, isNot(contains('revision')));
    await storage.db.close();
  });

  test('旧 v1 payload 在 sidecar 存在时仍可按旧 schema 应用', () async {
    final storage = await newDb();
    await ConversationListDao.create(storage);
    await SyncV2Schema.ensure(storage.db);

    final result = await LocalSyncService(storage).applyRemoteChanges(const [
      SyncChange(
        entity: 'conversation',
        id: '7',
        op: SyncOp.upsert,
        updatedAt: 11,
        payload: {
          'cid': 7,
          'title': '旧客户端 payload',
          'icon': '',
          'stickTime': 0,
          'updateAt': 11,
        },
      ),
    ]);

    expect(result.accepted, hasLength(1));
    final row = (await storage.db.query(
      'tb_conversation_list',
      where: 'cid = ?',
      whereArgs: [7],
    ))
        .single;
    expect(row['title'], '旧客户端 payload');
    await storage.db.close();
  });

  test('strict baseline 用 CHECK 拒绝终态证据不一致与 remote upsert 缺 payload', () async {
    final storage = await newDb();
    await SyncV2Schema.ensure(storage.db);

    await expectLater(
      storage.db.insert(SyncV2Schema.outboxTable, {
        'changeId': '40000000-0000-4000-8000-000000000001',
        'entity': 'project',
        'syncId': '41000000-0000-4000-8000-000000000001',
        'parentChangeId': null,
        'revision': 1,
        'op': 'upsert',
        'payload': '{}',
        'state': 'pending',
        'attempts': 0,
        'lastError': null,
        'ackReason': 'revision_gap',
        'expectedRevision': 1,
        'createdAt': 1,
        'updatedAt': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      storage.db.insert(SyncV2Schema.outboxTable, {
        'changeId': '40000000-0000-4000-8000-000000000002',
        'entity': 'project',
        'syncId': '41000000-0000-4000-8000-000000000001',
        'parentChangeId': null,
        'revision': 2,
        'op': 'upsert',
        'payload': '{}',
        'state': 'conflict',
        'attempts': 0,
        'lastError': null,
        'ackReason': null,
        'expectedRevision': 1,
        'createdAt': 1,
        'updatedAt': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      storage.db.insert(SyncV2Schema.conflictTable, {
        'changeId': '42000000-0000-4000-8000-000000000001',
        'entity': 'project',
        'syncId': '41000000-0000-4000-8000-000000000001',
        'reason': 'remote_ahead',
        'localPayload': '{}',
        'remoteSequence': 1,
        'remoteChangeId': '43000000-0000-4000-8000-000000000001',
        'remoteParentChangeId': null,
        'remoteRevision': 1,
        'remoteOp': 'upsert',
        'remotePayload': null,
        'remoteDeviceId': '44000000-0000-4000-8000-000000000001',
        'createdAt': 1,
        'resolvedAt': null,
        'resolution': null,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await storage.db.close();
  });

  test('已有实验 conflict 表缺 remoteChangeId 时 ensure 失败关闭且不伪造', () async {
    final storage = await newDb();
    await storage.db.execute('''
      create table ${SyncV2Schema.conflictTable} (
        id integer primary key autoincrement,
        changeId text not null unique
      )
    ''');

    await expectLater(
      SyncV2Schema.ensure(storage.db),
      throwsA(anyOf(isA<DatabaseException>(), isA<StateError>())),
    );
    expect(
      await columns(storage.db, SyncV2Schema.conflictTable),
      isNot(contains('remoteChangeId')),
    );
    await storage.db.close();
  });
}

Map<String, Object?> _v1WireJson(SyncChange change) => {
      'entity': change.entity,
      'id': change.id,
      'op': change.op.name,
      'updatedAt': change.updatedAt,
      'payload': change.payload,
    };
