import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_conflict_store.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_entity_state.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_outbox.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const syncId = '10000000-0000-4000-8000-000000000001';
  const independentSyncId = '10000000-0000-4000-8000-000000000002';
  const remoteChangeId = '10000000-0000-4000-8000-000000000009';
  var uuidCounter = 0;
  String nextUuid() {
    uuidCounter++;
    return '20000000-0000-4000-8000-${uuidCounter.toString().padLeft(12, '0')}';
  }

  Future<HiDBManager> newDb() async {
    uuidCounter = 0;
    final storage = HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
    );
    await SyncV2Schema.ensure(storage.db);
    await storage.db.execute(
      'create table tb_test_business (id integer primary key, value text)',
    );
    return storage;
  }

  SyncV2PushAck acceptedAck(
    SyncV2OutboxEntry entry, {
    bool duplicate = false,
    int? revision,
    int sequence = 1,
  }) =>
      SyncV2PushAck(
        changeId: entry.changeId,
        result: SyncV2AckResult.accepted,
        duplicate: duplicate,
        entity: entry.entity,
        syncId: entry.syncId,
        parentChangeId: entry.parentChangeId,
        revision: revision ?? entry.revision,
        sequence: sequence,
      );

  SyncV2PushAck terminalAck(
    SyncV2OutboxEntry entry, {
    required SyncV2AckResult result,
    required String reason,
    int? expectedRevision,
    bool duplicate = false,
    SyncV2RemoteChange? remote,
  }) =>
      SyncV2PushAck(
        changeId: entry.changeId,
        result: result,
        duplicate: duplicate,
        entity: entry.entity,
        syncId: entry.syncId,
        parentChangeId: entry.parentChangeId,
        revision: entry.revision,
        reason: reason,
        expectedRevision: expectedRevision,
        remote: remote,
      );

  SyncV2RemoteChange remoteSnapshot(
    SyncV2OutboxEntry entry, {
    int revision = 1,
    String name = '云端',
  }) =>
      SyncV2RemoteChange(
        sequence: 9,
        changeId: remoteChangeId,
        entity: entry.entity,
        syncId: entry.syncId,
        parentChangeId: null,
        revision: revision,
        operation: SyncV2Operation.upsert,
        payload: {'name': name},
        deviceId: '10000000-0000-4000-8000-000000000008',
      );

  test('离线连续编辑按 revision/parentChangeId 串链并稳定排序', () async {
    final storage = await newDb();
    var now = 100;
    final outbox = SyncV2Outbox(
      uuidGenerator: nextUuid,
      nowProvider: () => now,
    );

    late SyncV2OutboxEntry first;
    await storage.db.transaction((txn) async {
      await txn.insert('tb_test_business', {'id': 1, 'value': 'v1'});
      first = await outbox.enqueueUpsert(
        executor: txn,
        entity: SyncV2Entity.project,
        syncId: syncId,
        localKey: '1',
        payload: const {'name': 'v1'},
      );
    });
    now = 100;
    late SyncV2OutboxEntry second;
    await storage.db.transaction((txn) async {
      await txn.update(
        'tb_test_business',
        {'value': 'v2'},
        where: 'id = ?',
        whereArgs: [1],
      );
      second = await outbox.enqueueUpsert(
        executor: txn,
        entity: SyncV2Entity.project,
        syncId: syncId,
        localKey: '1',
        payload: const {'name': 'v2'},
      );
    });

    expect(first.revision, 1);
    expect(first.parentChangeId, isNull);
    expect(second.revision, 2);
    expect(second.parentChangeId, first.changeId);
    expect(
      (await outbox.loadPending(storage.db)).map((entry) => entry.changeId),
      [first.changeId, second.changeId],
    );
    await storage.db.close();
  });

  test('enqueueUpsert 在返回 Future 前同步快照嵌套 payload', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final payload = <String, dynamic>{
      'profile': <String, dynamic>{
        'tags': <dynamic>[
          <String, dynamic>{'name': '原值'},
        ],
      },
    };

    final pending = outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: payload,
    );
    final profile = payload['profile'] as Map<String, dynamic>;
    final tags = profile['tags'] as List<dynamic>;
    (tags.single as Map<String, dynamic>)['name'] = '篡改值';
    tags.add(<String, dynamic>{'name': '新增值'});

    final returned = await pending;
    final persisted = (await outbox.loadAll(storage.db)).single;
    for (final entry in [returned, persisted]) {
      final savedProfile = entry.payload!['profile'] as Map;
      final savedTags = savedProfile['tags'] as List;
      expect(savedTags, hasLength(1));
      expect((savedTags.single as Map)['name'], '原值');
    }
    await storage.db.close();
  });

  test('业务行写入后、outbox insert 前失败会整体回滚', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(
      uuidGenerator: nextUuid,
      failureHook: (point) {
        if (point == SyncV2OutboxFailurePoint.beforeOutboxInsert) {
          throw StateError('injected');
        }
      },
    );

    await expectLater(
      storage.db.transaction((txn) async {
        await txn.insert('tb_test_business', {'id': 1, 'value': 'partial'});
        await outbox.enqueueUpsert(
          executor: txn,
          entity: SyncV2Entity.project,
          syncId: syncId,
          localKey: '1',
          payload: const {'name': 'partial'},
        );
      }),
      throwsStateError,
    );

    expect(await storage.db.query('tb_test_business'), isEmpty);
    expect(await storage.db.query(SyncV2Schema.outboxTable), isEmpty);
    expect(await storage.db.query(SyncV2Schema.entityStateTable), isEmpty);
    await storage.db.close();
  });

  test('直接传 Database 时 entity head 与 outbox insert 仍同事务回滚', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(
      uuidGenerator: nextUuid,
      failureHook: (point) {
        if (point == SyncV2OutboxFailurePoint.beforeOutboxInsert) {
          throw StateError('injected');
        }
      },
    );

    await expectLater(
      outbox.enqueueUpsert(
        executor: storage.db,
        entity: SyncV2Entity.project,
        syncId: syncId,
        localKey: '1',
        payload: const {'name': 'partial'},
      ),
      throwsStateError,
    );

    expect(await storage.db.query(SyncV2Schema.outboxTable), isEmpty);
    expect(await storage.db.query(SyncV2Schema.entityStateTable), isEmpty);
    await storage.db.close();
  });

  test('ACK 仅清 exact accepted changeId，冲突及后代持久保留', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(
      uuidGenerator: nextUuid,
      nowProvider: () => 100,
    );
    final first = await storage.db.transaction((txn) => outbox.enqueueUpsert(
          executor: txn,
          entity: SyncV2Entity.project,
          syncId: syncId,
          localKey: '1',
          payload: const {'name': 'v1'},
        ));
    final child = await storage.db.transaction((txn) => outbox.enqueueUpsert(
          executor: txn,
          entity: SyncV2Entity.project,
          syncId: syncId,
          localKey: '1',
          payload: const {'name': 'v2'},
        ));
    final independent =
        await storage.db.transaction((txn) => outbox.enqueueUpsert(
              executor: txn,
              entity: SyncV2Entity.assistant,
              syncId: independentSyncId,
              localKey: '9',
              payload: const {'name': '独立'},
            ));

    await storage.db.transaction((txn) => outbox.applyAcks(txn, [
          SyncV2PushAck(
            changeId: first.changeId,
            result: SyncV2AckResult.conflict,
            duplicate: false,
            entity: first.entity,
            syncId: first.syncId,
            parentChangeId: first.parentChangeId,
            revision: first.revision,
            reason: 'remote_ahead',
            expectedRevision: 2,
            remote: SyncV2RemoteChange(
              sequence: 9,
              changeId: remoteChangeId,
              entity: SyncV2Entity.project,
              syncId: syncId,
              parentChangeId: null,
              revision: 1,
              operation: SyncV2Operation.upsert,
              payload: {'name': '云端'},
              deviceId: '10000000-0000-4000-8000-000000000008',
            ),
          ),
          SyncV2PushAck(
            changeId: independent.changeId,
            result: SyncV2AckResult.accepted,
            duplicate: false,
            entity: independent.entity,
            syncId: independent.syncId,
            parentChangeId: independent.parentChangeId,
            revision: independent.revision,
            sequence: 10,
          ),
        ]));

    final persisted = await outbox.loadAll(storage.db);
    expect(persisted.map((entry) => entry.changeId),
        containsAll([first.changeId, child.changeId]));
    expect(
      persisted.map((entry) => entry.changeId),
      isNot(contains(independent.changeId)),
    );
    expect(
      persisted.singleWhere((entry) => entry.changeId == first.changeId).state,
      SyncV2OutboxState.conflict,
    );
    expect(
      persisted.singleWhere((entry) => entry.changeId == child.changeId).state,
      SyncV2OutboxState.blocked,
    );
    final conflicts = await SyncV2ConflictStore().loadUnresolved(storage.db);
    expect(conflicts, hasLength(1));
    expect(conflicts.single.changeId, first.changeId);
    await storage.db.close();
  });

  test('accepted ACK 字段不匹配时拒绝删除本地 outbox', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final item = await storage.db.transaction((txn) => outbox.enqueueUpsert(
          executor: txn,
          entity: SyncV2Entity.project,
          syncId: syncId,
          localKey: '1',
          payload: const {'name': 'v1'},
        ));

    await expectLater(
      storage.db.transaction((txn) => outbox.applyAcks(txn, [
            SyncV2PushAck(
              changeId: item.changeId,
              result: SyncV2AckResult.accepted,
              duplicate: false,
              entity: item.entity,
              syncId: item.syncId,
              parentChangeId: item.parentChangeId,
              revision: 99,
              sequence: 1,
            ),
          ])),
      throwsFormatException,
    );
    expect(await outbox.loadAll(storage.db), hasLength(1));
    await storage.db.close();
  });

  test('直接传 Database 时 ACK 批次中途失败会回滚已 accepted 的状态', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final first = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );
    final second = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.assistant,
      syncId: independentSyncId,
      localKey: '9',
      payload: const {'name': '独立'},
    );

    await expectLater(
      outbox.applyAcks(storage.db, [
        SyncV2PushAck(
          changeId: first.changeId,
          result: SyncV2AckResult.accepted,
          duplicate: false,
          entity: first.entity,
          syncId: first.syncId,
          parentChangeId: first.parentChangeId,
          revision: first.revision,
          sequence: 1,
        ),
        SyncV2PushAck(
          changeId: second.changeId,
          result: SyncV2AckResult.accepted,
          duplicate: false,
          entity: second.entity,
          syncId: second.syncId,
          parentChangeId: second.parentChangeId,
          revision: 99,
          sequence: 2,
        ),
      ]),
      throwsFormatException,
    );

    expect(
      (await outbox.loadAll(storage.db)).map((entry) => entry.changeId),
      containsAll([first.changeId, second.changeId]),
    );
    final firstState = await SyncV2EntityStateStore().findBySyncId(
      storage.db,
      first.entity,
      first.syncId,
    );
    expect(firstState?.serverRevision, 0);
    expect(firstState?.serverChangeId, isNull);
    await storage.db.close();
  });

  test('直接传 Database 时 conflict、后代 block 与冲突记录共同回滚', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final root = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );
    final child = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v2'},
    );
    final independent = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.assistant,
      syncId: independentSyncId,
      localKey: '9',
      payload: const {'name': '独立'},
    );

    await expectLater(
      outbox.applyAcks(storage.db, [
        SyncV2PushAck(
          changeId: root.changeId,
          result: SyncV2AckResult.conflict,
          duplicate: false,
          entity: root.entity,
          syncId: root.syncId,
          parentChangeId: root.parentChangeId,
          revision: root.revision,
          reason: 'remote_ahead',
          expectedRevision: 2,
          remote: SyncV2RemoteChange(
            sequence: 9,
            changeId: remoteChangeId,
            entity: SyncV2Entity.project,
            syncId: syncId,
            parentChangeId: null,
            revision: 1,
            operation: SyncV2Operation.upsert,
            payload: {'name': '云端'},
            deviceId: '10000000-0000-4000-8000-000000000008',
          ),
        ),
        SyncV2PushAck(
          changeId: independent.changeId,
          result: SyncV2AckResult.accepted,
          duplicate: false,
          entity: independent.entity,
          syncId: independent.syncId,
          parentChangeId: independent.parentChangeId,
          revision: 99,
          sequence: 10,
        ),
      ]),
      throwsFormatException,
    );

    final persisted = await outbox.loadAll(storage.db);
    expect(
      persisted.singleWhere((entry) => entry.changeId == root.changeId).state,
      SyncV2OutboxState.pending,
    );
    expect(
      persisted.singleWhere((entry) => entry.changeId == child.changeId).state,
      SyncV2OutboxState.pending,
    );
    expect(
      persisted
          .singleWhere(
            (entry) => entry.changeId == independent.changeId,
          )
          .state,
      SyncV2OutboxState.pending,
    );
    expect(await SyncV2ConflictStore().loadUnresolved(storage.db), isEmpty);
    await storage.db.close();
  });

  test('delete 保留 entity-state tombstone，失败日志不包含秘密或路径', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    await storage.db.insert('tb_test_business', {'id': 1, 'value': 'v1'});
    final deletion = await storage.db.transaction((txn) async {
      await txn.delete('tb_test_business', where: 'id = ?', whereArgs: [1]);
      return outbox.enqueueDelete(
        executor: txn,
        entity: SyncV2Entity.project,
        syncId: syncId,
        localKey: '1',
      );
    });
    await outbox.markAttemptFailed(
      storage.db,
      deletion.changeId,
      'apiKey=sk-secret /Users/me/private/file.json',
    );

    expect(await storage.db.query('tb_test_business'), isEmpty);
    final state = await SyncV2EntityStateStore().findBySyncId(
      storage.db,
      SyncV2Entity.project,
      syncId,
    );
    expect(state?.operation, SyncV2Operation.delete);
    expect(state?.localRevision, 1);
    final persisted = (await outbox.loadAll(storage.db)).single;
    expect(persisted.attempts, 1);
    expect(persisted.lastError, 'String');
    expect(persisted.lastError, isNot(contains('sk-secret')));
    expect(persisted.lastError, isNot(contains('/Users/')));
    await storage.db.close();
  });

  test('applyAcks 入口拒绝缺 sequence 的 direct accepted ACK', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final entry = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );

    await expectLater(
      outbox.applyAcks(storage.db, [
        SyncV2PushAck(
          changeId: entry.changeId,
          result: SyncV2AckResult.accepted,
          duplicate: false,
          entity: entry.entity,
          syncId: entry.syncId,
          parentChangeId: entry.parentChangeId,
          revision: entry.revision,
        ),
      ]),
      throwsFormatException,
    );
    expect(await outbox.loadAll(storage.db), hasLength(1));
    await storage.db.close();
  });

  test('partial accepted ACK 允许 rev2 先推进 head，后续 rev1 replay 只精确清理', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final first = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );
    final second = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v2'},
    );

    await outbox.applyAcks(
      storage.db,
      [acceptedAck(second, sequence: 2)],
    );
    var remaining = await outbox.loadAll(storage.db);
    expect(remaining.map((entry) => entry.changeId), [first.changeId]);
    var state = await SyncV2EntityStateStore().findBySyncId(
      storage.db,
      SyncV2Entity.project,
      syncId,
    );
    expect(state?.serverRevision, 2);
    expect(state?.serverChangeId, second.changeId);

    await outbox.applyAcks(
      storage.db,
      [acceptedAck(first, duplicate: true)],
    );
    remaining = await outbox.loadAll(storage.db);
    expect(remaining, isEmpty);
    state = await SyncV2EntityStateStore().findBySyncId(
      storage.db,
      SyncV2Entity.project,
      syncId,
    );
    expect(state?.serverRevision, 2);
    expect(state?.serverChangeId, second.changeId);
    await storage.db.close();
  });

  test('rejected ACK 保存终态证据并阻断现有和新建 descendants', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(
      uuidGenerator: nextUuid,
      nowProvider: () => 100,
    );
    final root = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );
    final child = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v2'},
    );
    await outbox.markAttemptFailed(storage.db, root.changeId, 'secret');
    final rejected = terminalAck(
      root,
      result: SyncV2AckResult.rejected,
      reason: 'revision_gap',
      expectedRevision: 2,
      remote: remoteSnapshot(root),
    );

    await outbox.applyAcks(storage.db, [rejected]);
    var rows = await outbox.loadAll(storage.db);
    var persistedRoot =
        rows.singleWhere((entry) => entry.changeId == root.changeId);
    var persistedChild =
        rows.singleWhere((entry) => entry.changeId == child.changeId);
    expect(persistedRoot.state, SyncV2OutboxState.rejected);
    expect(persistedRoot.ackReason, 'revision_gap');
    expect(persistedRoot.expectedRevision, 2);
    expect(persistedRoot.lastError, isNull);
    expect(persistedRoot.ackRemoteEvidence, isNotNull);
    expect(persistedChild.state, SyncV2OutboxState.blocked);
    expect(persistedChild.ackReason, 'blocked_by_ancestor');
    expect(persistedChild.expectedRevision, 2);
    expect(persistedChild.ackRemoteEvidence, isNull);

    await outbox.applyAcks(storage.db, [
      terminalAck(
        root,
        result: SyncV2AckResult.rejected,
        reason: 'revision_gap',
        expectedRevision: 2,
        duplicate: true,
        remote: remoteSnapshot(root),
      ),
    ]);
    await expectLater(
      outbox.applyAcks(storage.db, [
        terminalAck(
          root,
          result: SyncV2AckResult.rejected,
          reason: 'revision_gap',
          expectedRevision: 2,
          duplicate: true,
          remote: remoteSnapshot(root, name: '被篡改'),
        ),
      ]),
      throwsStateError,
    );
    await outbox.applyAcks(storage.db, [
      terminalAck(
        child,
        result: SyncV2AckResult.blocked,
        reason: 'blocked_by_ancestor',
        expectedRevision: 2,
        remote: remoteSnapshot(root),
      ),
    ]);
    persistedChild = (await outbox.loadAll(storage.db))
        .singleWhere((entry) => entry.changeId == child.changeId);
    expect(persistedChild.ackRemoteEvidence, isNotNull);
    await expectLater(
      outbox.applyAcks(storage.db, [
        terminalAck(
          child,
          result: SyncV2AckResult.blocked,
          reason: 'blocked_by_ancestor',
          expectedRevision: 2,
          duplicate: true,
          remote: remoteSnapshot(root, name: '被篡改'),
        ),
      ]),
      throwsStateError,
    );
    await expectLater(
      outbox.applyAcks(storage.db, [
        terminalAck(
          root,
          result: SyncV2AckResult.blocked,
          reason: 'blocked_by_ancestor',
          expectedRevision: 1,
          duplicate: true,
        ),
      ]),
      throwsStateError,
    );

    final descendant = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v3'},
    );
    expect(descendant.state, SyncV2OutboxState.blocked);
    expect(descendant.ackReason, 'blocked_by_ancestor');
    expect(descendant.expectedRevision, 2);
    rows = await outbox.loadAll(storage.db);
    persistedRoot =
        rows.singleWhere((entry) => entry.changeId == root.changeId);
    persistedChild =
        rows.singleWhere((entry) => entry.changeId == child.changeId);
    expect(persistedRoot.state, SyncV2OutboxState.rejected);
    expect(persistedChild.state, SyncV2OutboxState.blocked);
    await storage.db.close();
  });

  test('blocked ACK 可精确幂等重放，但不接受不同终态内容', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final entry = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );
    final blocked = terminalAck(
      entry,
      result: SyncV2AckResult.blocked,
      reason: 'blocked_by_ancestor',
      expectedRevision: 2,
      remote: remoteSnapshot(entry),
    );

    await outbox.applyAcks(storage.db, [blocked]);
    await outbox.applyAcks(storage.db, [
      terminalAck(
        entry,
        result: SyncV2AckResult.blocked,
        reason: 'blocked_by_ancestor',
        expectedRevision: 2,
        duplicate: true,
        remote: remoteSnapshot(entry),
      ),
    ]);
    await expectLater(
      outbox.applyAcks(storage.db, [
        terminalAck(
          entry,
          result: SyncV2AckResult.blocked,
          reason: 'blocked_by_ancestor',
          expectedRevision: 3,
          duplicate: true,
          remote: remoteSnapshot(entry, revision: 2),
        ),
      ]),
      throwsStateError,
    );
    final persisted = (await outbox.loadAll(storage.db)).single;
    expect(persisted.state, SyncV2OutboxState.blocked);
    expect(persisted.ackReason, 'blocked_by_ancestor');
    expect(persisted.expectedRevision, 2);
    expect(persisted.ackRemoteEvidence, isNotNull);
    await storage.db.close();
  });

  test('change_id_reused 不阻断同批 accepted child 或后续新变更', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final acceptedHead = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'accepted-head'},
    );
    await outbox.applyAcks(storage.db, [acceptedAck(acceptedHead)]);
    final reused = SyncV2OutboxEntry(
      changeId: acceptedHead.changeId,
      entity: acceptedHead.entity,
      syncId: acceptedHead.syncId,
      parentChangeId: acceptedHead.parentChangeId,
      revision: acceptedHead.revision,
      operation: SyncV2Operation.upsert,
      payload: const {'name': 'illegal-reuse'},
      state: SyncV2OutboxState.pending,
      attempts: 0,
      lastError: null,
      createdAt: 50,
      updatedAt: 50,
    );
    await storage.db.insert(
      SyncV2Schema.outboxTable,
      reused.toDatabaseRow(),
    );
    final descendant = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'descendant'},
    );

    await outbox.applyAcks(storage.db, [
      terminalAck(
        reused,
        result: SyncV2AckResult.rejected,
        reason: 'change_id_reused',
      ),
      acceptedAck(descendant, sequence: 2),
    ]);
    var rows = await outbox.loadAll(storage.db);
    final root = rows.single;
    expect(root.state, SyncV2OutboxState.rejected);
    expect(root.expectedRevision, isNull);
    final state = await SyncV2EntityStateStore().findBySyncId(
      storage.db,
      SyncV2Entity.project,
      syncId,
    );
    expect(state?.serverRevision, 2);
    expect(state?.serverChangeId, descendant.changeId);

    final next = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'next'},
    );
    expect(next.state, SyncV2OutboxState.pending);
    rows = await outbox.loadAll(storage.db);
    expect(rows.map((entry) => entry.changeId),
        containsAll([reused.changeId, next.changeId]));
    await storage.db.close();
  });

  test('无因果 stale conflict 不阻断指向当前 server head 的 accepted child', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final base = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'base'},
    );
    await outbox.applyAcks(storage.db, [acceptedAck(base)]);
    final head = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'head'},
    );
    await outbox.applyAcks(storage.db, [acceptedAck(head, sequence: 2)]);

    final stale = SyncV2OutboxEntry(
      changeId: '50000000-0000-4000-8000-000000000001',
      entity: SyncV2Entity.project,
      syncId: syncId,
      parentChangeId: null,
      revision: 1,
      operation: SyncV2Operation.upsert,
      payload: const {'name': 'stale'},
      state: SyncV2OutboxState.pending,
      attempts: 0,
      lastError: null,
      createdAt: 50,
      updatedAt: 50,
    );
    await storage.db.insert(
      SyncV2Schema.outboxTable,
      stale.toDatabaseRow(),
    );
    final child = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'child'},
    );
    expect(child.parentChangeId, head.changeId);

    await outbox.applyAcks(storage.db, [
      SyncV2PushAck(
        changeId: stale.changeId,
        result: SyncV2AckResult.conflict,
        duplicate: false,
        entity: stale.entity,
        syncId: stale.syncId,
        parentChangeId: stale.parentChangeId,
        revision: stale.revision,
        reason: 'remote_ahead',
        expectedRevision: 3,
        remote: SyncV2RemoteChange(
          sequence: 2,
          changeId: head.changeId,
          entity: head.entity,
          syncId: head.syncId,
          parentChangeId: base.changeId,
          revision: 2,
          operation: SyncV2Operation.upsert,
          payload: const {'name': 'head'},
          deviceId: '10000000-0000-4000-8000-000000000008',
        ),
      ),
      acceptedAck(child, sequence: 3),
    ]);
    var rows = await outbox.loadAll(storage.db);
    expect(rows, hasLength(1));
    expect(rows.single.changeId, stale.changeId);
    expect(rows.single.state, SyncV2OutboxState.conflict);
    final state = await SyncV2EntityStateStore().findBySyncId(
      storage.db,
      SyncV2Entity.project,
      syncId,
    );
    expect(state?.serverRevision, 3);
    expect(state?.serverChangeId, child.changeId);

    final next = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'next'},
    );
    expect(next.state, SyncV2OutboxState.pending);
    rows = await outbox.loadAll(storage.db);
    expect(rows.map((entry) => entry.changeId),
        containsAll([stale.changeId, next.changeId]));
    await storage.db.close();
  });

  test('accepted 不得跨过已有 conflict，unknown 仅 accepted replay 幂等', () async {
    final storage = await newDb();
    final outbox = SyncV2Outbox(uuidGenerator: nextUuid);
    final entry = await outbox.enqueueUpsert(
      executor: storage.db,
      entity: SyncV2Entity.project,
      syncId: syncId,
      localKey: '1',
      payload: const {'name': 'v1'},
    );
    final conflict = SyncV2PushAck(
      changeId: entry.changeId,
      result: SyncV2AckResult.conflict,
      duplicate: false,
      entity: entry.entity,
      syncId: entry.syncId,
      parentChangeId: entry.parentChangeId,
      revision: entry.revision,
      reason: 'remote_ahead',
      expectedRevision: 2,
      remote: SyncV2RemoteChange(
        sequence: 9,
        changeId: remoteChangeId,
        entity: entry.entity,
        syncId: entry.syncId,
        parentChangeId: null,
        revision: 1,
        operation: SyncV2Operation.upsert,
        payload: const {'name': '云端'},
        deviceId: '10000000-0000-4000-8000-000000000008',
      ),
    );
    await outbox.applyAcks(storage.db, [conflict]);
    await outbox.applyAcks(storage.db, [conflict]);
    await expectLater(
      outbox.applyAcks(storage.db, [
        SyncV2PushAck(
          changeId: entry.changeId,
          result: SyncV2AckResult.conflict,
          duplicate: true,
          entity: entry.entity,
          syncId: entry.syncId,
          parentChangeId: entry.parentChangeId,
          revision: entry.revision,
          reason: 'remote_ahead',
          expectedRevision: 2,
          remote: SyncV2RemoteChange(
            sequence: 9,
            changeId: remoteChangeId,
            entity: entry.entity,
            syncId: entry.syncId,
            parentChangeId: null,
            revision: 1,
            operation: SyncV2Operation.upsert,
            payload: const {'name': '被篡改'},
            deviceId: '10000000-0000-4000-8000-000000000008',
          ),
        ),
      ]),
      throwsStateError,
    );

    await expectLater(
      outbox.applyAcks(storage.db, [acceptedAck(entry, sequence: 9)]),
      throwsStateError,
    );
    var persisted = (await outbox.loadAll(storage.db)).single;
    expect(persisted.state, SyncV2OutboxState.conflict);

    const unknownChangeId = '90000000-0000-4000-8000-000000000001';
    final unknownAccepted = SyncV2PushAck(
      changeId: unknownChangeId,
      result: SyncV2AckResult.accepted,
      duplicate: true,
      entity: SyncV2Entity.project,
      syncId: syncId,
      parentChangeId: null,
      revision: 1,
      sequence: 1,
    );
    await outbox.applyAcks(storage.db, [unknownAccepted]);
    await expectLater(
      outbox.applyAcks(storage.db, [
        SyncV2PushAck(
          changeId: unknownChangeId,
          result: SyncV2AckResult.rejected,
          duplicate: true,
          entity: SyncV2Entity.project,
          syncId: syncId,
          parentChangeId: null,
          revision: 1,
          reason: 'change_id_reused',
        ),
      ]),
      throwsStateError,
    );
    persisted = (await outbox.loadAll(storage.db)).single;
    expect(persisted.state, SyncV2OutboxState.conflict);
    await storage.db.close();
  });
}
