import 'dart:convert';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_inbox.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/backend_transfer_test_support.dart';

void main() {
  final fx = TransferFixture();
  setUpAll(fx.init);
  tearDownAll(fx.finish);
  for (final entity in transferTables.keys) {
    for (final selection in [pairA, BackendSelection.follow()]) {
      test(
          '$entity ${selection.kind.name}: missing and explicit NULL preserve stored choice',
          () async {
        final db = await fx.db();
        await fx.seed(db, selection: selection.toSqlText());
        final sync = LocalSyncService(db,
            accountHash: 'fixture',
            roleCardAssetDirectoryResolver: () async => fx.root);
        var row =
            (await sync.exportChanges()).singleWhere((c) => c.entity == entity);
        for (final explicitNull in [false, true]) {
          final payload = Map<String, dynamic>.from(row.payload);
          if (explicitNull) {
            payload['backendSelection'] = null;
          } else {
            payload.remove('backendSelection');
          }
          final time = row.updatedAt + 1;
          payload[entity == 'conversation' ? 'updateAt' : 'updatedAt'] = time;
          payload[entity == 'conversation' || entity == 'story_room'
              ? 'title'
              : 'name'] = 'remote edit';
          final result = await sync.applyRemoteChanges([
            SyncChange(
                entity: entity,
                id: row.id,
                op: SyncOp.upsert,
                updatedAt: time,
                payload: payload)
          ]);
          expect(result.accepted.length, 1);
          row = (await sync.exportChanges())
              .singleWhere((c) => c.entity == entity);
          expect(row.payload['backendSelection'], selection.toSqlText());
        }
        final same = Map<String, dynamic>.from(row.payload)
          ..remove('backendSelection');
        final noConflict = await sync.applyRemoteChanges([
          SyncChange(
              entity: entity,
              id: row.id,
              op: SyncOp.upsert,
              updatedAt: row.updatedAt,
              payload: same)
        ]);
        expect(noConflict.conflicts, isEmpty);
        final other = Map<String, dynamic>.from(row.payload)
          ..['backendSelection'] = pairB.toSqlText();
        final conflict = await sync.applyRemoteChanges([
          SyncChange(
              entity: entity,
              id: row.id,
              op: SyncOp.upsert,
              updatedAt: row.updatedAt,
              payload: other)
        ]);
        expect(conflict.conflicts, contains(row.key));
        expect(conflict.accepted, isEmpty);
      });
    }
  }
  for (final entity in transferTables.keys) {
    test(
        '$entity: valid foreign map, explicit follow, legacy NULL and malformed batch boundaries',
        () async {
      final db = await fx.db();
      await fx.seed(db);
      final sync = LocalSyncService(db,
          accountHash: 'account-B',
          roleCardAssetDirectoryResolver: () async => fx.root);
      var row =
          (await sync.exportChanges()).singleWhere((c) => c.entity == entity);
      final payload = Map<String, dynamic>.from(row.payload)
        ..['backendSelection'] = pairB.toSafeJson();
      payload[entity == 'conversation' ? 'updateAt' : 'updatedAt'] = 11;
      await sync.applyRemoteChanges([
        SyncChange(
            entity: entity,
            id: row.id,
            op: SyncOp.upsert,
            updatedAt: 11,
            payload: payload)
      ]);
      row = (await sync.exportChanges()).singleWhere((c) => c.entity == entity);
      expect(row.payload['backendSelection'], pairB.toSqlText());
      final bad = Map<String, dynamic>.from(row.payload)
        ..['backendSelection'] = '{"version":9,"secret":"synthetic"}';
      bad[entity == 'conversation' ? 'updateAt' : 'updatedAt'] = 12;
      await expectLater(
          sync.applyRemoteChanges([
            SyncChange(
                entity: entity,
                id: row.id,
                op: SyncOp.upsert,
                updatedAt: 12,
                payload: bad)
          ]),
          throwsFormatException);
      expect(
          (await db.db.query(transferTables[entity]!))
              .single['backendSelection'],
          pairB.toSqlText());
      final follow = Map<String, dynamic>.from(row.payload)
        ..['backendSelection'] = BackendSelection.follow().toSqlText();
      follow[entity == 'conversation' ? 'updateAt' : 'updatedAt'] = 13;
      await sync.applyRemoteChanges([
        SyncChange(
            entity: entity,
            id: row.id,
            op: SyncOp.upsert,
            updatedAt: 13,
            payload: follow)
      ]);
      expect(
          (await db.db.query(transferTables[entity]!))
              .single['backendSelection'],
          BackendSelection.follow().toSqlText());
      await db.db.update(transferTables[entity]!, {'backendSelection': null});
      final legacy = Map<String, dynamic>.from(follow)
        ..['backendSelection'] = null;
      legacy[entity == 'conversation' ? 'updateAt' : 'updatedAt'] = 14;
      await sync.applyRemoteChanges([
        SyncChange(
            entity: entity,
            id: row.id,
            op: SyncOp.upsert,
            updatedAt: 14,
            payload: legacy)
      ]);
      expect(
          (await db.db.query(transferTables[entity]!))
              .single['backendSelection'],
          isNull);
    });
  }
  test(
      'unknown current raw survives unrelated NULL update; safe export rejects instead of leaking',
      () async {
    final db = await fx.db();
    await fx.seed(db);
    const raw = '{"version":99,"secret":"synthetic-secret"}';
    await db.db.update('tb_project', {'backendSelection': raw});
    final sync = LocalSyncService(db,
        accountHash: 'fixture',
        roleCardAssetDirectoryResolver: () async => fx.root);
    final payload =
        Map<String, dynamic>.from((await db.db.query('tb_project')).single)
          ..['name'] = 'updated'
          ..['updatedAt'] = 11
          ..['backendSelection'] = null;
    await sync.applyRemoteChanges([
      SyncChange(
          entity: 'project',
          id: '1',
          op: SyncOp.upsert,
          updatedAt: 11,
          payload: payload)
    ]);
    expect((await db.db.query('tb_project')).single['backendSelection'], raw);
    await expectLater(sync.exportChanges(), throwsFormatException);
  });
  test(
      'new legacy NULL stays NULL; invalid consumed input rejects whole batch before writes',
      () async {
    final db = await fx.db();
    await fx.seed(db);
    final sync = LocalSyncService(db,
        accountHash: 'fixture',
        roleCardAssetDirectoryResolver: () async => fx.root);
    final before = (await db.db.query('tb_project')).single;
    await expectLater(
        sync.applyRemoteChanges([
          const SyncChange(
              entity: 'project',
              id: '2',
              op: SyncOp.upsert,
              updatedAt: 20,
              payload: {
                'id': 2,
                'name': 'new',
                'updatedAt': 20,
                'backendSelection': null
              }),
          const SyncChange(
              entity: 'project',
              id: '1',
              op: SyncOp.upsert,
              updatedAt: 21,
              payload: {
                'id': 1,
                'name': 'bad',
                'updatedAt': 21,
                'backendSelection': 'bad'
              })
        ]),
        throwsFormatException);
    expect(await db.db.query('tb_project'), [before]);
    await sync.applyRemoteChanges([
      const SyncChange(
          entity: 'project',
          id: '2',
          op: SyncOp.upsert,
          updatedAt: 20,
          payload: {
            'id': 2,
            'name': 'new',
            'updatedAt': 20,
            'backendSelection': null
          })
    ]);
    expect(
        (await db.db.query('tb_project', where: 'id=2'))
            .single['backendSelection'],
        isNull);
  });
  test(
      'delete ignores payload selection; existing tombstone and v2 opaque payload retain contracts',
      () async {
    final db = await fx.db();
    await fx.seed(db);
    final sync = LocalSyncService(db,
        accountHash: 'fixture',
        roleCardAssetDirectoryResolver: () async => fx.root);
    final deleted = await sync.applyRemoteChanges([
      const SyncChange(
          entity: 'conversation',
          id: '71',
          op: SyncOp.delete,
          updatedAt: 20,
          payload: {'backendSelection': 'bad'})
    ]);
    expect(deleted.accepted.length, 1);
    expect(await db.db.query('tb_conversation_list'), isEmpty);
    await SyncTombstoneStore.record(db.db,
        entity: 'conversation', id: 71, updatedAt: 20);
    final tombstone = (await sync.exportChanges())
        .singleWhere((c) => c.entity == 'conversation');
    expect(tombstone.op, SyncOp.delete);
    expect(tombstone.payload, isEmpty);
    await SyncV2Schema.ensure(db.db);
    final inbox = SyncV2Inbox(nowProvider: () => 30);
    final pair = pairA.toSafeJson();
    await inbox.persist(db.db, [
      SyncV2RemoteChange(
          sequence: 1,
          changeId: '00000000-0000-4000-8000-000000000001',
          entity: SyncV2Entity.conversation,
          syncId: '00000000-0000-4000-8000-000000000002',
          parentChangeId: null,
          revision: 1,
          operation: SyncV2Operation.upsert,
          payload: {'backendSelection': pair},
          deviceId: '00000000-0000-4000-8000-000000000003')
    ]);
    final restored = (await inbox.loadAll(db.db)).single;
    expect(restored.payload!['backendSelection'], pair);
    expect(jsonEncode(restored.payload), isNot(contains('account-B')));
  });
}
