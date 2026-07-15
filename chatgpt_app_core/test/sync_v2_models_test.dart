import 'dart:math';

import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_uuid.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const changeId = '00000000-0000-4000-8000-000000000001';
  const syncId = '00000000-0000-4000-8000-000000000002';
  const deviceId = '00000000-0000-4000-8000-000000000003';

  test('SyncV2Uuid 只接受 RFC 4122 version 4 UUID', () {
    final generated = SyncV2Uuid.generate(random: Random(42));

    expect(SyncV2Uuid.isValid(generated), isTrue);
    expect(
      generated,
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      )),
    );
    expect(
      SyncV2Uuid.isValid('00000000-0000-1000-8000-000000000001'),
      isFalse,
    );
    expect(SyncV2Uuid.isValid('not-a-uuid'), isFalse);
  });

  test('remote change 严格解析 UUID、十进制 revision 与 JSON object', () {
    final change = SyncV2RemoteChange.fromJson(const {
      'sequence': '12',
      'changeId': changeId,
      'entity': 'conversation',
      'syncId': syncId,
      'parentChangeId': null,
      'revision': '1',
      'op': 'upsert',
      'payload': {
        'title': '测试',
        'nested': {
          'enabled': true,
        },
      },
      'deviceId': deviceId,
    });

    expect(change.sequence, 12);
    expect(change.entity, SyncV2Entity.conversation);
    expect(change.revision, 1);
    expect(change.payload?['title'], '测试');
    expect(
      () => change.payload!['title'] = '不能修改',
      throwsUnsupportedError,
    );
  });

  test('push ACK 严格解析结果枚举及 remote snapshot', () {
    final ack = SyncV2PushAck.fromJson(const {
      'changeId': changeId,
      'result': 'conflict',
      'duplicate': false,
      'entity': 'assistant',
      'syncId': syncId,
      'parentChangeId': null,
      'revision': '2',
      'reason': 'remote_ahead',
      'expectedRevision': '3',
      'remote': {
        'sequence': '8',
        'changeId': '00000000-0000-4000-8000-000000000004',
        'entity': 'assistant',
        'syncId': syncId,
        'parentChangeId': null,
        'revision': '2',
        'op': 'upsert',
        'payload': {'name': '远端'},
        'deviceId': deviceId,
      },
    });

    expect(ack.result, SyncV2AckResult.conflict);
    expect(ack.reason, 'remote_ahead');
    expect(ack.expectedRevision, 3);
    expect(ack.remote?.payload?['name'], '远端');
  });

  test('revision_gap/blocked 接受合法 remote，change_id_reused 仍禁止', () {
    const remote = <String, Object?>{
      'sequence': '8',
      'changeId': '00000000-0000-4000-8000-000000000004',
      'entity': 'project',
      'syncId': syncId,
      'parentChangeId': null,
      'revision': '2',
      'op': 'upsert',
      'payload': {'name': '远端'},
      'deviceId': deviceId,
    };
    Map<String, Object?> failureAck(String result, String reason) => {
          'changeId': changeId,
          'result': result,
          'duplicate': false,
          'entity': 'project',
          'syncId': syncId,
          'parentChangeId': null,
          'revision': '3',
          'reason': reason,
          'expectedRevision': '3',
          'remote': remote,
        };

    final revisionGap = SyncV2PushAck.fromJson(
      failureAck('rejected', 'revision_gap'),
    );
    final blocked = SyncV2PushAck.fromJson(
      failureAck('blocked', 'blocked_by_ancestor'),
    );
    expect(revisionGap.remote?.changeId, remote['changeId']);
    expect(blocked.remote?.payload?['name'], '远端');

    for (final failure in const [
      ('conflict', 'remote_ahead'),
      ('rejected', 'revision_gap'),
      ('blocked', 'blocked_by_ancestor'),
    ]) {
      expect(
        () => SyncV2PushAck.fromJson({
          ...failureAck(failure.$1, failure.$2),
          'expectedRevision': '2',
        }),
        throwsFormatException,
      );
    }
    final noHead = SyncV2PushAck.fromJson({
      ...failureAck('rejected', 'revision_gap'),
      'expectedRevision': '1',
      'remote': null,
    });
    expect(noHead.expectedRevision, 1);
    expect(noHead.remote, isNull);
    for (final failure in const [
      ('rejected', 'revision_gap'),
      ('blocked', 'blocked_by_ancestor'),
    ]) {
      expect(
        () => SyncV2PushAck.fromJson({
          ...failureAck(failure.$1, failure.$2),
          'expectedRevision': '2',
          'remote': null,
        }),
        throwsFormatException,
      );
    }

    final maxRevisionRemote = SyncV2RemoteChange(
      sequence: 8,
      changeId: '00000000-0000-4000-8000-000000000004',
      entity: SyncV2Entity.project,
      syncId: syncId,
      parentChangeId: null,
      revision: 9223372036854775807,
      operation: SyncV2Operation.delete,
      payload: null,
      deviceId: deviceId,
    );
    final overflow = SyncV2PushAck(
      changeId: changeId,
      result: SyncV2AckResult.blocked,
      duplicate: false,
      entity: SyncV2Entity.project,
      syncId: syncId,
      parentChangeId: null,
      revision: 3,
      reason: 'blocked_by_ancestor',
      expectedRevision: 9223372036854775807,
      remote: maxRevisionRemote,
    );
    expect(overflow.validate, throwsFormatException);

    expect(
      () => SyncV2PushAck.fromJson({
        ...failureAck('rejected', 'change_id_reused'),
        'expectedRevision': null,
      }),
      throwsFormatException,
    );
    expect(
      () => SyncV2PushAck.fromJson({
        ...failureAck('blocked', 'blocked_by_ancestor'),
        'remote': {...remote, 'entity': 'assistant'},
      }),
      throwsFormatException,
    );
    expect(
      () => SyncV2PushAck.fromJson({
        ...failureAck('rejected', 'revision_gap'),
        'remote': {...remote, 'payload': null},
      }),
      throwsFormatException,
    );
  });

  test('malformed enum/revision/UUID/payload 均拒绝', () {
    Map<String, Object?> base() => const {
          'sequence': '1',
          'changeId': changeId,
          'entity': 'project',
          'syncId': syncId,
          'parentChangeId': null,
          'revision': '1',
          'op': 'upsert',
          'payload': <String, Object?>{},
          'deviceId': deviceId,
        };

    expect(
      () => SyncV2RemoteChange.fromJson({...base(), 'entity': 'unknown'}),
      throwsFormatException,
    );
    expect(
      () => SyncV2RemoteChange.fromJson({...base(), 'revision': 1}),
      throwsFormatException,
    );
    expect(
      () => SyncV2RemoteChange.fromJson({...base(), 'revision': '01'}),
      throwsFormatException,
    );
    expect(
      () => SyncV2RemoteChange.fromJson({...base(), 'syncId': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => SyncV2RemoteChange.fromJson({
        ...base(),
        'payload': ['not-map']
      }),
      throwsFormatException,
    );
    expect(
      () => SyncV2OutboxEntry.fromDatabaseRow(const {
        'changeId': changeId,
        'entity': 'project',
        'syncId': syncId,
        'parentChangeId': null,
        'revision': 0,
        'op': 'upsert',
        'payload': '{}',
        'state': 'pending',
        'attempts': 0,
        'lastError': null,
        'createdAt': 1,
        'updatedAt': 1,
      }),
      throwsFormatException,
    );
  });

  test('direct ACK 与 conflict row 共享严格 shape/payload 校验', () {
    final missingSequence = SyncV2PushAck(
      changeId: changeId,
      result: SyncV2AckResult.accepted,
      duplicate: false,
      entity: SyncV2Entity.project,
      syncId: syncId,
      parentChangeId: null,
      revision: 1,
    );
    expect(missingSequence.validate, throwsFormatException);

    final illegalExpectedRevision = SyncV2PushAck(
      changeId: changeId,
      result: SyncV2AckResult.rejected,
      duplicate: true,
      entity: SyncV2Entity.project,
      syncId: syncId,
      parentChangeId: null,
      revision: 1,
      reason: 'change_id_reused',
      expectedRevision: 2,
    );
    expect(illegalExpectedRevision.validate, throwsFormatException);

    expect(
      () => SyncV2OutboxEntry.fromDatabaseRow(const {
        'changeId': changeId,
        'entity': 'project',
        'syncId': syncId,
        'parentChangeId': null,
        'revision': 1,
        'op': 'upsert',
        'payload': '{}',
        'state': 'conflict',
        'attempts': 0,
        'lastError': null,
        'ackReason': 'remote_ahead',
        'expectedRevision': 1,
        'ackRemoteEvidence': 'null',
        'createdAt': 1,
        'updatedAt': 1,
      }),
      throwsFormatException,
    );

    expect(
      () => SyncV2Conflict.fromDatabaseRow(const {
        'id': 1,
        'changeId': changeId,
        'entity': 'project',
        'syncId': syncId,
        'reason': 'remote_ahead',
        'localPayload': '{}',
        'remoteSequence': 1,
        'remoteChangeId': '00000000-0000-4000-8000-000000000004',
        'remoteParentChangeId': null,
        'remoteRevision': 1,
        'remoteOp': 'upsert',
        'remotePayload': null,
        'remoteDeviceId': deviceId,
        'createdAt': 1,
        'resolvedAt': null,
        'resolution': null,
      }),
      throwsFormatException,
    );
  });
}
