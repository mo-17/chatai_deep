import 'dart:io';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_conflict_store.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_inbox.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<HiDBManager> newDb() async {
    final storage = HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
    );
    await SyncV2Schema.ensure(storage.db);
    return storage;
  }

  SyncV2RemoteChange remote(int sequence) => SyncV2RemoteChange(
        sequence: sequence,
        changeId:
            '30000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}',
        entity: SyncV2Entity.message,
        syncId:
            '31000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}',
        parentChangeId: null,
        revision: 1,
        operation: SyncV2Operation.upsert,
        payload: {'content': 'message-$sequence'},
        deviceId: '32000000-0000-4000-8000-000000000001',
      );

  test('inbox 按 serverId 幂等持久化并只显式标记 applied', () async {
    final storage = await newDb();
    final inbox = SyncV2Inbox(nowProvider: () => 100);
    await storage.db
        .transaction((txn) => inbox.persist(txn, [remote(2), remote(1)]));
    await storage.db.transaction((txn) => inbox.persist(txn, [remote(1)]));

    final pending = await inbox.loadPending(storage.db);
    expect(pending.map((entry) => entry.serverId), [1, 2]);
    await inbox.markApplied(storage.db, pending.first.changeId, appliedAt: 150);
    expect((await inbox.loadPending(storage.db)).map((entry) => entry.serverId),
        [2]);
    expect(await inbox.loadAll(storage.db), hasLength(2));
    await storage.db.close();
  });

  test('直接传 Database 时 inbox 批次中途冲突不会留下前置行', () async {
    final storage = await newDb();
    final inbox = SyncV2Inbox(nowProvider: () => 100);
    final reusedServerId = SyncV2RemoteChange(
      sequence: 1,
      changeId: '30000000-0000-4000-8000-000000000099',
      entity: SyncV2Entity.message,
      syncId: '31000000-0000-4000-8000-000000000099',
      parentChangeId: null,
      revision: 1,
      operation: SyncV2Operation.upsert,
      payload: const {'content': 'different'},
      deviceId: '32000000-0000-4000-8000-000000000001',
    );

    await expectLater(
      inbox.persist(storage.db, [remote(1), reusedServerId]),
      throwsFormatException,
    );

    expect(await storage.db.query(SyncV2Schema.inboxTable), isEmpty);
    await storage.db.close();
  });

  test('损坏 payload 读取失败但持久行不被删除', () async {
    final storage = await newDb();
    final inbox = SyncV2Inbox();
    await storage.db.insert(SyncV2Schema.inboxTable, {
      'serverId': 1,
      'changeId': '30000000-0000-4000-8000-000000000001',
      'entity': 'message',
      'syncId': '31000000-0000-4000-8000-000000000001',
      'parentChangeId': null,
      'revision': 1,
      'op': 'upsert',
      'payload': '{broken-json',
      'state': 'pending',
      'lastError': null,
      'receivedAt': 1,
      'appliedAt': null,
    });

    await expectLater(inbox.loadPending(storage.db), throwsFormatException);
    expect(await storage.db.query(SyncV2Schema.inboxTable), hasLength(1));
    await storage.db.close();
  });

  test('conflict 持久完整 remote identity 并可跨重启 round-trip', () async {
    final directory =
        await Directory.systemTemp.createTemp('sync-v2-conflict-');
    final path = '${directory.path}/sync.db';
    final firstDb = await databaseFactoryFfi.openDatabase(path);
    await SyncV2Schema.ensure(firstDb);
    final store = SyncV2ConflictStore(nowProvider: () => 100);
    final ack = SyncV2PushAck.fromJson(const {
      'changeId': '33000000-0000-4000-8000-000000000001',
      'result': 'conflict',
      'duplicate': false,
      'entity': 'message',
      'syncId': '31000000-0000-4000-8000-000000000001',
      'parentChangeId': null,
      'revision': '1',
      'reason': 'remote_ahead',
      'expectedRevision': '3',
      'remote': {
        'sequence': '9',
        'changeId': '34000000-0000-4000-8000-000000000001',
        'entity': 'message',
        'syncId': '31000000-0000-4000-8000-000000000001',
        'parentChangeId': '34000000-0000-4000-8000-000000000000',
        'revision': '2',
        'op': 'upsert',
        'payload': {
          'content': '云端',
          'meta': {'source': 'remote'},
        },
        'deviceId': '32000000-0000-4000-8000-000000000001',
      },
    });
    await store.recordRemoteAhead(
      firstDb,
      ack: ack,
      localPayload: const {
        'content': '本地',
        'meta': {'source': 'local'},
      },
    );
    await firstDb.close();

    final reopened = await databaseFactoryFfi.openDatabase(path);
    await SyncV2Schema.ensure(reopened);
    final conflict =
        (await SyncV2ConflictStore().loadUnresolved(reopened)).single;
    expect(conflict.remoteChangeId, '34000000-0000-4000-8000-000000000001');
    expect(conflict.remoteSequence, 9);
    expect(
        conflict.remoteParentChangeId, '34000000-0000-4000-8000-000000000000');
    expect(conflict.remoteDeviceId, '32000000-0000-4000-8000-000000000001');
    expect(conflict.remotePayload?['content'], '云端');
    await reopened.close();
    await directory.delete(recursive: true);
  });

  test('同 changeId 的相同 conflict snapshot 幂等，不同 snapshot 失败关闭', () async {
    final storage = await newDb();
    final store = SyncV2ConflictStore(nowProvider: () => 100);
    SyncV2PushAck ack(String remoteContent) => SyncV2PushAck.fromJson({
          'changeId': '33000000-0000-4000-8000-000000000001',
          'result': 'conflict',
          'duplicate': remoteContent == '云端',
          'entity': 'message',
          'syncId': '31000000-0000-4000-8000-000000000001',
          'parentChangeId': null,
          'revision': '1',
          'reason': 'remote_ahead',
          'expectedRevision': '3',
          'remote': {
            'sequence': '9',
            'changeId': '34000000-0000-4000-8000-000000000001',
            'entity': 'message',
            'syncId': '31000000-0000-4000-8000-000000000001',
            'parentChangeId': null,
            'revision': '2',
            'op': 'upsert',
            'payload': {
              'meta': {'source': 'remote'},
              'content': remoteContent,
            },
            'deviceId': '32000000-0000-4000-8000-000000000001',
          },
        });
    const local = {
      'content': '本地',
      'meta': {'source': 'local'},
    };

    final first = await store.recordRemoteAhead(
      storage.db,
      ack: ack('云端'),
      localPayload: local,
    );
    final replay = await store.recordRemoteAhead(
      storage.db,
      ack: ack('云端'),
      localPayload: const {
        'meta': {'source': 'local'},
        'content': '本地',
      },
    );
    expect(replay.id, first.id);

    await expectLater(
      store.recordRemoteAhead(
        storage.db,
        ack: ack('被篡改'),
        localPayload: local,
      ),
      throwsStateError,
    );
    final persisted = (await store.loadUnresolved(storage.db)).single;
    expect(persisted.remotePayload?['content'], '云端');
    await storage.db.close();
  });
}
