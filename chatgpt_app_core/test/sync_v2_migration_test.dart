import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_migration.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  var uuidCounter = 0;
  String nextUuid() {
    uuidCounter++;
    return '40000000-0000-4000-8000-${uuidCounter.toString().padLeft(12, '0')}';
  }

  Future<HiDBManager> newDb() async {
    uuidCounter = 0;
    return HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
    );
  }

  Future<Set<String>> tables(HiDBManager storage) async =>
      (await storage.db.rawQuery(
        "select name from sqlite_master where type = 'table'",
      ))
          .map((row) => '${row['name']}')
          .toSet();

  const enabled = SyncV2ShadowGate(
    enabled: true,
    shadowSupported: true,
  );

  test('默认 unsupported 及 guest 均保持数据库零 sidecar 写入', () async {
    final unsupported = await newDb();
    final migration = SyncV2ShadowMigration(uuidGenerator: nextUuid);
    final unsupportedResult = await migration.prepare(unsupported);
    expect(unsupportedResult.status, SyncV2ShadowMigrationStatus.unsupported);
    expect(await tables(unsupported), isNot(contains(SyncV2Schema.stateTable)));

    final guest = await newDb();
    final guestResult = await migration.prepare(
      guest,
      gate: enabled,
      isGuest: true,
    );
    expect(guestResult.status, SyncV2ShadowMigrationStatus.guestSkipped);
    expect(await tables(guest), isNot(contains(SyncV2Schema.stateTable)));
    await unsupported.db.close();
    await guest.db.close();
  });

  test('空库事务化创建 sidecar 并最后写 shadow ready marker', () async {
    final storage = await newDb();
    final result = await SyncV2ShadowMigration(
      uuidGenerator: nextUuid,
    ).prepare(storage, gate: enabled, isGuest: false);

    expect(result.status, SyncV2ShadowMigrationStatus.ready);
    expect(result.createdIdentities, 0);
    expect(await tables(storage), containsAll(SyncV2Schema.tableNames));
    final marker = (await storage.db.query(
      SyncV2Schema.stateTable,
      where: 'key = ?',
      whereArgs: [SyncV2ShadowMigration.readyKey],
    ))
        .single;
    expect(marker['value'], '1');
    await storage.db.close();
  });

  test(' populated core rows 只回填 sidecar identity，不修改业务行', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table tb_assistant (id integer primary key, name text)',
    );
    await storage.db.execute(
      'create table tb_project (id integer primary key, name text, defaultAssistantId integer)',
    );
    await storage.db.execute(
      'create table tb_conversation_list (cid integer primary key, title text, assistantId integer, projectId integer)',
    );
    await storage.db.execute(
      'create table tb_messages (id integer primary key, cid integer, content text)',
    );
    await storage.db.insert('tb_assistant', {'id': 1, 'name': '助手'});
    await storage.db.insert('tb_project', {
      'id': 2,
      'name': '项目',
      'defaultAssistantId': 1,
    });
    await storage.db.insert('tb_conversation_list', {
      'cid': 3,
      'title': '会话',
      'assistantId': 1,
      'projectId': 2,
    });
    await storage.db.insert('tb_messages', {
      'id': 4,
      'cid': 3,
      'content': '消息',
    });
    final before = await storage.db.query('tb_messages');

    final result = await SyncV2ShadowMigration(
      uuidGenerator: nextUuid,
    ).prepare(storage, gate: enabled, isGuest: false);

    expect(result.createdIdentities, 4);
    expect(
      await storage.db.query(SyncV2Schema.entityStateTable),
      hasLength(4),
    );
    expect(await storage.db.query('tb_messages'), before);
    expect(
      (await storage.db.rawQuery('pragma table_info(tb_messages)'))
          .map((row) => row['name']),
      isNot(contains('syncId')),
    );
    await storage.db.close();
  });

  for (final failurePoint in SyncV2ShadowMigrationPoint.values) {
    test(
      '在 ${failurePoint.name} 中断会回滚 schema、identity 与 ready marker',
      () async {
        final storage = await newDb();
        await storage.db.execute(
          'create table tb_project (id integer primary key, name text)',
        );
        await storage.db.insert('tb_project', {'id': 1, 'name': '项目'});
        final interrupted = SyncV2ShadowMigration(
          uuidGenerator: nextUuid,
          failureHook: (point) {
            if (point == failurePoint) throw StateError('interrupted');
          },
        );

        await expectLater(
          interrupted.prepare(storage, gate: enabled, isGuest: false),
          throwsStateError,
        );
        expect(
          await tables(storage),
          isNot(contains(SyncV2Schema.stateTable)),
        );

        final recovered = await SyncV2ShadowMigration(
          uuidGenerator: nextUuid,
        ).prepare(storage, gate: enabled, isGuest: false);
        expect(recovered.status, SyncV2ShadowMigrationStatus.ready);
        expect(recovered.createdIdentities, 1);
        await storage.db.close();
      },
    );
  }

  for (final failurePoint in SyncV2ShadowMigrationPoint.values) {
    test(
      'rerun 在 ${failurePoint.name} 中断后旧 ready marker 保持不可见',
      () async {
        final storage = await newDb();
        addTearDown(storage.db.close);
        await storage.db.execute(
          'create table tb_project (id integer primary key, name text)',
        );
        await storage.db.insert('tb_project', {'id': 1, 'name': '项目'});
        await SyncV2ShadowMigration(uuidGenerator: nextUuid)
            .prepare(storage, gate: enabled, isGuest: false);
        final identityBefore = (await storage.db.query(
          SyncV2Schema.entityStateTable,
          where: 'entity = ? and localKey = ?',
          whereArgs: ['project', '1'],
        ))
            .single['syncId'];
        expect(
          await storage.db.query(
            SyncV2Schema.stateTable,
            where: 'key = ? and value = ?',
            whereArgs: [SyncV2ShadowMigration.readyKey, '1'],
          ),
          hasLength(1),
        );
        final interrupted = SyncV2ShadowMigration(
          uuidGenerator: nextUuid,
          failureHook: (point) {
            if (point == failurePoint) throw StateError('rerun interrupted');
          },
        );

        await expectLater(
          interrupted.prepare(storage, gate: enabled, isGuest: false),
          throwsStateError,
        );

        final identityAfter = (await storage.db.query(
          SyncV2Schema.entityStateTable,
          where: 'entity = ? and localKey = ?',
          whereArgs: ['project', '1'],
        ))
            .single['syncId'];
        expect(identityAfter, identityBefore);
        expect(
          await storage.db.query(
            SyncV2Schema.stateTable,
            where: 'key = ?',
            whereArgs: [SyncV2ShadowMigration.readyKey],
          ),
          isEmpty,
        );
      },
    );
  }

  test('rerun 幂等保留原 syncId，仅为新增行分配 identity', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table tb_project (id integer primary key, name text)',
    );
    await storage.db.insert('tb_project', {'id': 1, 'name': '项目1'});
    final migration = SyncV2ShadowMigration(uuidGenerator: nextUuid);
    await migration.prepare(storage, gate: enabled, isGuest: false);
    final firstRows = await storage.db.query(SyncV2Schema.entityStateTable);
    final firstSyncId = firstRows.single['syncId'];

    await storage.db.insert('tb_project', {'id': 2, 'name': '项目2'});
    final rerun =
        await migration.prepare(storage, gate: enabled, isGuest: false);
    final rows = await storage.db.query(
      SyncV2Schema.entityStateTable,
      orderBy: 'localKey',
    );
    expect(rerun.createdIdentities, 1);
    expect(rows, hasLength(2));
    expect(rows.first['syncId'], firstSyncId);
    await storage.db.close();
  });

  test('rerun 保留 live row 的历史 identity 并重新发布 ready', () async {
    final storage = await newDb();
    addTearDown(storage.db.close);
    await storage.db.execute(
      'create table tb_project (id integer primary key, name text)',
    );
    await storage.db.insert('tb_project', {'id': 1, 'name': '项目1'});
    final migration = SyncV2ShadowMigration(uuidGenerator: nextUuid);
    await migration.prepare(storage, gate: enabled, isGuest: false);
    final first = (await storage.db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ? and localKey = ?',
      whereArgs: ['project', '1'],
    ))
        .single;
    const serverChangeId = '50000000-0000-4000-8000-000000000010';
    const localChangeId = '50000000-0000-4000-8000-000000000011';
    await storage.db.update(
      SyncV2Schema.entityStateTable,
      {
        'serverRevision': 1,
        'serverChangeId': serverChangeId,
        'localRevision': 2,
        'localHeadChangeId': localChangeId,
      },
      where: 'entity = ? and localKey = ?',
      whereArgs: ['project', '1'],
    );

    final rerun =
        await migration.prepare(storage, gate: enabled, isGuest: false);
    final preserved = (await storage.db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ? and localKey = ?',
      whereArgs: ['project', '1'],
    ))
        .single;

    expect(rerun.status, SyncV2ShadowMigrationStatus.ready);
    expect(rerun.createdIdentities, 0);
    expect(preserved['syncId'], first['syncId']);
    expect(preserved['serverRevision'], 1);
    expect(preserved['serverChangeId'], serverChangeId);
    expect(preserved['localRevision'], 2);
    expect(preserved['localHeadChangeId'], localChangeId);
    expect(
      await storage.db.query(
        SyncV2Schema.stateTable,
        where: 'key = ? and value = ?',
        whereArgs: [SyncV2ShadowMigration.readyKey, '1'],
      ),
      hasLength(1),
    );
  });

  test('rerun 清理已删除行的 rev0 identity，复用 local key 时分配新 syncId', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table tb_project (id integer primary key, name text)',
    );
    await storage.db.insert('tb_project', {'id': 1, 'name': '项目1'});
    final migration = SyncV2ShadowMigration(uuidGenerator: nextUuid);
    await migration.prepare(storage, gate: enabled, isGuest: false);
    final firstSyncId = (await storage.db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ? and localKey = ?',
      whereArgs: ['project', '1'],
    ))
        .single['syncId'];

    await storage.db.delete('tb_project', where: 'id = ?', whereArgs: [1]);
    await migration.prepare(storage, gate: enabled, isGuest: false);
    expect(
      await storage.db.query(
        SyncV2Schema.entityStateTable,
        where: 'entity = ?',
        whereArgs: ['project'],
      ),
      isEmpty,
    );

    await storage.db.insert('tb_project', {'id': 1, 'name': '复用后的项目'});
    await migration.prepare(storage, gate: enabled, isGuest: false);
    final reusedSyncId = (await storage.db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ? and localKey = ?',
      whereArgs: ['project', '1'],
    ))
        .single['syncId'];

    expect(reusedSyncId, isNot(firstSyncId));
    await storage.db.close();
  });

  test('rerun 遇到非零 revision 孤儿时拒绝 ready 且保留身份待恢复', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table tb_project (id integer primary key, name text)',
    );
    await storage.db.insert('tb_project', {'id': 1, 'name': '项目1'});
    final migration = SyncV2ShadowMigration(uuidGenerator: nextUuid);
    await migration.prepare(storage, gate: enabled, isGuest: false);
    const changeId = '50000000-0000-4000-8000-000000000001';
    await storage.db.update(
      SyncV2Schema.entityStateTable,
      {
        'localRevision': 1,
        'localHeadChangeId': changeId,
      },
      where: 'entity = ? and localKey = ?',
      whereArgs: ['project', '1'],
    );
    await storage.db.delete('tb_project', where: 'id = ?', whereArgs: [1]);

    await expectLater(
      migration.prepare(storage, gate: enabled, isGuest: false),
      throwsStateError,
    );

    expect(
      await storage.db.query(
        SyncV2Schema.entityStateTable,
        where: 'entity = ? and localKey = ?',
        whereArgs: ['project', '1'],
      ),
      hasLength(1),
    );
    expect(
      await storage.db.query(
        SyncV2Schema.stateTable,
        where: 'key = ? and value = ?',
        whereArgs: [SyncV2ShadowMigration.readyKey, '1'],
      ),
      isEmpty,
    );
    await storage.db.close();
  });

  test('硬依赖缺失时事务失败且 marker 不落盘', () async {
    final storage = await newDb();
    await storage.db.execute(
      'create table tb_kb_doc (id integer primary key, title text)',
    );
    await storage.db.execute(
      'create table tb_kb_chunk (id integer primary key, docId integer, content text)',
    );
    await storage.db.insert('tb_kb_chunk', {
      'id': 1,
      'docId': 999,
      'content': 'orphan',
    });

    await expectLater(
      SyncV2ShadowMigration(uuidGenerator: nextUuid)
          .prepare(storage, gate: enabled, isGuest: false),
      throwsStateError,
    );
    expect(await tables(storage), isNot(contains(SyncV2Schema.stateTable)));
    await storage.db.close();
  });
}
