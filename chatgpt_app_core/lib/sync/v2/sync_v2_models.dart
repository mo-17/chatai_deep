import 'dart:collection';
import 'dart:convert';

import 'package:chatgpt_app_core/sync/v2/sync_v2_uuid.dart';

const int _maxSqliteInteger = 9223372036854775807;

enum SyncV2Entity {
  project('project'),
  assistant('assistant'),
  conversation('conversation'),
  message('message'),
  favorite('favorite'),
  knowledgeDoc('knowledge_doc'),
  knowledgeChunk('knowledge_chunk'),
  projectKnowledge('project_knowledge'),
  assistantMemory('assistant_memory');

  const SyncV2Entity(this.wireName);

  final String wireName;

  static SyncV2Entity parse(Object? value, [String field = 'entity']) {
    if (value is! String) throw FormatException('$field 必须是字符串');
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw FormatException('$field 不在 Sync v2 allowlist');
  }
}

enum SyncV2Operation {
  upsert('upsert'),
  delete('delete');

  const SyncV2Operation(this.wireName);

  final String wireName;

  static SyncV2Operation parse(Object? value, [String field = 'op']) {
    if (value is! String) throw FormatException('$field 必须是字符串');
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw FormatException('$field 非法');
  }
}

enum SyncV2OutboxState {
  pending('pending'),
  conflict('conflict'),
  rejected('rejected'),
  blocked('blocked');

  const SyncV2OutboxState(this.wireName);

  final String wireName;

  static SyncV2OutboxState parse(Object? value) {
    if (value is! String) throw const FormatException('outbox state 必须是字符串');
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw const FormatException('outbox state 非法');
  }
}

enum SyncV2InboxState {
  pending('pending'),
  applied('applied');

  const SyncV2InboxState(this.wireName);

  final String wireName;

  static SyncV2InboxState parse(Object? value) {
    if (value is! String) throw const FormatException('inbox state 必须是字符串');
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw const FormatException('inbox state 非法');
  }
}

enum SyncV2AckResult {
  accepted('accepted'),
  conflict('conflict'),
  rejected('rejected'),
  blocked('blocked');

  const SyncV2AckResult(this.wireName);

  final String wireName;

  static SyncV2AckResult parse(Object? value) {
    if (value is! String) throw const FormatException('ACK result 必须是字符串');
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw const FormatException('ACK result 非法');
  }
}

enum SyncV2ConflictResolution {
  keepLocal('keep_local'),
  useRemote('use_remote'),
  keepBoth('keep_both');

  const SyncV2ConflictResolution(this.wireName);

  final String wireName;

  static SyncV2ConflictResolution? parseNullable(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const FormatException('conflict resolution 必须是字符串');
    }
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw const FormatException('conflict resolution 非法');
  }
}

class SyncV2OutboxEntry {
  SyncV2OutboxEntry({
    required this.changeId,
    required this.entity,
    required this.syncId,
    required this.parentChangeId,
    required this.revision,
    required this.operation,
    required Map<String, dynamic>? payload,
    required this.state,
    required this.attempts,
    required this.lastError,
    this.ackReason,
    this.expectedRevision,
    this.ackRemoteEvidence,
    required this.createdAt,
    required this.updatedAt,
  }) : payload = _freezeJsonObject(payload) {
    _validatePayloadForOperation(operation, this.payload);
    _validateOutboxStateEvidence(
      state: state,
      lastError: lastError,
      ackReason: ackReason,
      expectedRevision: expectedRevision,
      ackRemoteEvidence: ackRemoteEvidence,
      entity: entity,
      syncId: syncId,
    );
  }

  final String changeId;
  final SyncV2Entity entity;
  final String syncId;
  final String? parentChangeId;
  final int revision;
  final SyncV2Operation operation;
  final Map<String, dynamic>? payload;
  final SyncV2OutboxState state;
  final int attempts;
  final String? lastError;
  final String? ackReason;
  final int? expectedRevision;
  final String? ackRemoteEvidence;
  final int createdAt;
  final int updatedAt;

  /// 在进入任何 async/事务边界前快照并验证调用方 payload。
  static Map<String, dynamic> snapshotUpsertPayload(
    Map<String, dynamic> payload,
  ) {
    final snapshot = _freezeJsonObject(payload)!;
    _validatePayloadForOperation(SyncV2Operation.upsert, snapshot);
    return snapshot;
  }

  factory SyncV2OutboxEntry.fromDatabaseRow(Map<String, Object?> row) {
    final operation = SyncV2Operation.parse(row['op']);
    final payload = _decodePayload(row['payload'], 'payload');
    _validatePayloadForOperation(operation, payload);
    return SyncV2OutboxEntry(
      changeId: SyncV2Uuid.require(row['changeId'], 'changeId'),
      entity: SyncV2Entity.parse(row['entity']),
      syncId: SyncV2Uuid.require(row['syncId'], 'syncId'),
      parentChangeId: _nullableUuid(row['parentChangeId'], 'parentChangeId'),
      revision: _positiveDbInt(row['revision'], 'revision'),
      operation: operation,
      payload: payload,
      state: SyncV2OutboxState.parse(row['state']),
      attempts: _nonNegativeDbInt(row['attempts'], 'attempts'),
      lastError: _nullableString(row['lastError'], 'lastError'),
      ackReason: _nullableString(row['ackReason'], 'ackReason'),
      expectedRevision: row['expectedRevision'] == null
          ? null
          : _positiveDbInt(row['expectedRevision'], 'expectedRevision'),
      ackRemoteEvidence:
          _nullableString(row['ackRemoteEvidence'], 'ackRemoteEvidence'),
      createdAt: _nonNegativeDbInt(row['createdAt'], 'createdAt'),
      updatedAt: _nonNegativeDbInt(row['updatedAt'], 'updatedAt'),
    );
  }

  Map<String, Object?> toDatabaseRow() => {
        'changeId': changeId,
        'entity': entity.wireName,
        'syncId': syncId,
        'parentChangeId': parentChangeId,
        'revision': revision,
        'op': operation.wireName,
        'payload': payload == null ? null : jsonEncode(payload),
        'state': state.wireName,
        'attempts': attempts,
        'lastError': lastError,
        'ackReason': ackReason,
        'expectedRevision': expectedRevision,
        'ackRemoteEvidence': ackRemoteEvidence,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  Map<String, Object?> toPushJson() => {
        'changeId': changeId,
        'entity': entity.wireName,
        'syncId': syncId,
        'parentChangeId': parentChangeId,
        'revision': '$revision',
        'op': operation.wireName,
        if (payload != null) 'payload': payload,
      };
}

class SyncV2RemoteChange {
  SyncV2RemoteChange({
    required this.sequence,
    required this.changeId,
    required this.entity,
    required this.syncId,
    required this.parentChangeId,
    required this.revision,
    required this.operation,
    required Map<String, dynamic>? payload,
    required this.deviceId,
  }) : payload = _freezeJsonObject(payload);

  final int sequence;
  final String changeId;
  final SyncV2Entity entity;
  final String syncId;
  final String? parentChangeId;
  final int revision;
  final SyncV2Operation operation;
  final Map<String, dynamic>? payload;
  final String deviceId;

  void validate() {
    _positiveRuntimeInt(sequence, 'remote.sequence');
    SyncV2Uuid.require(changeId, 'remote.changeId');
    SyncV2Uuid.require(syncId, 'remote.syncId');
    _nullableUuid(parentChangeId, 'remote.parentChangeId');
    _positiveRuntimeInt(revision, 'remote.revision');
    _validatePayloadForOperation(operation, payload);
    SyncV2Uuid.require(deviceId, 'remote.deviceId');
  }

  factory SyncV2RemoteChange.fromJson(Map<String, Object?> json) {
    final operation = SyncV2Operation.parse(json['op']);
    final payload = _jsonObject(json['payload'], 'payload', allowNull: true);
    _validatePayloadForOperation(operation, payload);
    final change = SyncV2RemoteChange(
      sequence: _positiveDecimal(json['sequence'], 'sequence'),
      changeId: SyncV2Uuid.require(json['changeId'], 'changeId'),
      entity: SyncV2Entity.parse(json['entity']),
      syncId: SyncV2Uuid.require(json['syncId'], 'syncId'),
      parentChangeId: _nullableUuid(json['parentChangeId'], 'parentChangeId'),
      revision: _positiveDecimal(json['revision'], 'revision'),
      operation: operation,
      payload: payload,
      deviceId: SyncV2Uuid.require(json['deviceId'], 'deviceId'),
    );
    change.validate();
    return change;
  }
}

class SyncV2PushAck {
  SyncV2PushAck({
    required this.changeId,
    required this.result,
    required this.duplicate,
    required this.entity,
    required this.syncId,
    required this.parentChangeId,
    required this.revision,
    this.reason,
    this.expectedRevision,
    this.remote,
    this.sequence,
  });

  final String changeId;
  final SyncV2AckResult result;
  final bool duplicate;
  final SyncV2Entity entity;
  final String syncId;
  final String? parentChangeId;
  final int revision;
  final String? reason;
  final int? expectedRevision;
  final SyncV2RemoteChange? remote;
  final int? sequence;

  String get remoteEvidence => _encodeRemoteEvidence(remote);

  void validate() {
    SyncV2Uuid.require(changeId, 'ACK changeId');
    SyncV2Uuid.require(syncId, 'ACK syncId');
    _nullableUuid(parentChangeId, 'ACK parentChangeId');
    _positiveRuntimeInt(revision, 'ACK revision');
    if (expectedRevision != null) {
      _positiveRuntimeInt(expectedRevision!, 'ACK expectedRevision');
    }
    if (sequence != null) {
      _positiveRuntimeInt(sequence!, 'ACK sequence');
    }
    remote?.validate();
    _validateAckShape(
      result: result,
      reason: reason,
      expectedRevision: expectedRevision,
      remote: remote,
      sequence: sequence,
    );
    final snapshot = remote;
    final carriesFailureHead = result == SyncV2AckResult.conflict ||
        result == SyncV2AckResult.blocked ||
        (result == SyncV2AckResult.rejected && reason == 'revision_gap');
    if (carriesFailureHead && snapshot == null && expectedRevision != 1) {
      throw const FormatException(
        'failure ACK remote 为 null 时 expectedRevision 必须为 1',
      );
    }
    if (carriesFailureHead && snapshot != null) {
      if (snapshot.revision == _maxSqliteInteger ||
          expectedRevision != snapshot.revision + 1) {
        throw const FormatException(
          'failure ACK expectedRevision 必须紧接 remote revision',
        );
      }
    }
    if (snapshot != null &&
        (snapshot.entity != entity || snapshot.syncId != syncId)) {
      throw const FormatException('ACK remote identity 与 ACK 不一致');
    }
  }

  factory SyncV2PushAck.fromJson(Map<String, Object?> json) {
    final result = SyncV2AckResult.parse(json['result']);
    final duplicate = json['duplicate'];
    if (duplicate is! bool) {
      throw const FormatException('ACK duplicate 必须是 bool');
    }
    final entity = SyncV2Entity.parse(json['entity']);
    final syncId = SyncV2Uuid.require(json['syncId'], 'syncId');
    final reason = _nullableString(json['reason'], 'reason');
    final expectedRevision = json['expectedRevision'] == null
        ? null
        : _positiveDecimal(json['expectedRevision'], 'expectedRevision');
    final remoteRaw = json['remote'];
    final remote = remoteRaw == null
        ? null
        : SyncV2RemoteChange.fromJson(_stringKeyMap(remoteRaw, 'remote'));
    final sequence = json['sequence'] == null
        ? null
        : _positiveDecimal(json['sequence'], 'sequence');
    final ack = SyncV2PushAck(
      changeId: SyncV2Uuid.require(json['changeId'], 'changeId'),
      result: result,
      duplicate: duplicate,
      entity: entity,
      syncId: syncId,
      parentChangeId: _nullableUuid(json['parentChangeId'], 'parentChangeId'),
      revision: _positiveDecimal(json['revision'], 'revision'),
      reason: reason,
      expectedRevision: expectedRevision,
      remote: remote,
      sequence: sequence,
    );
    ack.validate();
    return ack;
  }
}

class SyncV2InboxEntry {
  SyncV2InboxEntry({
    required this.serverId,
    required this.changeId,
    required this.entity,
    required this.syncId,
    required this.parentChangeId,
    required this.revision,
    required this.operation,
    required Map<String, dynamic>? payload,
    required this.state,
    required this.lastError,
    required this.receivedAt,
    required this.appliedAt,
  }) : payload = _freezeJsonObject(payload);

  final int serverId;
  final String changeId;
  final SyncV2Entity entity;
  final String syncId;
  final String? parentChangeId;
  final int revision;
  final SyncV2Operation operation;
  final Map<String, dynamic>? payload;
  final SyncV2InboxState state;
  final String? lastError;
  final int receivedAt;
  final int? appliedAt;

  factory SyncV2InboxEntry.fromDatabaseRow(Map<String, Object?> row) {
    final operation = SyncV2Operation.parse(row['op']);
    final payload = _decodePayload(row['payload'], 'payload');
    _validatePayloadForOperation(operation, payload);
    return SyncV2InboxEntry(
      serverId: _positiveDbInt(row['serverId'], 'serverId'),
      changeId: SyncV2Uuid.require(row['changeId'], 'changeId'),
      entity: SyncV2Entity.parse(row['entity']),
      syncId: SyncV2Uuid.require(row['syncId'], 'syncId'),
      parentChangeId: _nullableUuid(row['parentChangeId'], 'parentChangeId'),
      revision: _positiveDbInt(row['revision'], 'revision'),
      operation: operation,
      payload: payload,
      state: SyncV2InboxState.parse(row['state']),
      lastError: _nullableString(row['lastError'], 'lastError'),
      receivedAt: _nonNegativeDbInt(row['receivedAt'], 'receivedAt'),
      appliedAt: row['appliedAt'] == null
          ? null
          : _nonNegativeDbInt(row['appliedAt'], 'appliedAt'),
    );
  }
}

class SyncV2Conflict {
  SyncV2Conflict({
    required this.id,
    required this.changeId,
    required this.entity,
    required this.syncId,
    required this.reason,
    required Map<String, dynamic>? localPayload,
    required this.remoteSequence,
    required this.remoteChangeId,
    required this.remoteParentChangeId,
    required this.remoteRevision,
    required this.remoteOperation,
    required Map<String, dynamic>? remotePayload,
    required this.remoteDeviceId,
    required this.createdAt,
    required this.resolvedAt,
    required this.resolution,
  })  : localPayload = _freezeJsonObject(localPayload),
        remotePayload = _freezeJsonObject(remotePayload);

  final int? id;
  final String changeId;
  final SyncV2Entity entity;
  final String syncId;
  final String reason;
  final Map<String, dynamic>? localPayload;
  final int remoteSequence;
  final String remoteChangeId;
  final String? remoteParentChangeId;
  final int remoteRevision;
  final SyncV2Operation remoteOperation;
  final Map<String, dynamic>? remotePayload;
  final String remoteDeviceId;
  final int createdAt;
  final int? resolvedAt;
  final SyncV2ConflictResolution? resolution;

  factory SyncV2Conflict.fromDatabaseRow(Map<String, Object?> row) {
    final reason = _requiredString(row['reason'], 'reason');
    if (reason != 'remote_ahead') {
      throw const FormatException('conflict reason 非法');
    }
    final remoteOperation = SyncV2Operation.parse(row['remoteOp'], 'remoteOp');
    final remotePayload = _decodePayload(row['remotePayload'], 'remotePayload');
    _validatePayloadForOperation(remoteOperation, remotePayload);
    return SyncV2Conflict(
      id: row['id'] == null ? null : _positiveDbInt(row['id'], 'id'),
      changeId: SyncV2Uuid.require(row['changeId'], 'changeId'),
      entity: SyncV2Entity.parse(row['entity']),
      syncId: SyncV2Uuid.require(row['syncId'], 'syncId'),
      reason: reason,
      localPayload: _decodePayload(row['localPayload'], 'localPayload'),
      remoteSequence: _positiveDbInt(row['remoteSequence'], 'remoteSequence'),
      remoteChangeId:
          SyncV2Uuid.require(row['remoteChangeId'], 'remoteChangeId'),
      remoteParentChangeId:
          _nullableUuid(row['remoteParentChangeId'], 'remoteParentChangeId'),
      remoteRevision: _positiveDbInt(row['remoteRevision'], 'remoteRevision'),
      remoteOperation: remoteOperation,
      remotePayload: remotePayload,
      remoteDeviceId:
          SyncV2Uuid.require(row['remoteDeviceId'], 'remoteDeviceId'),
      createdAt: _nonNegativeDbInt(row['createdAt'], 'createdAt'),
      resolvedAt: row['resolvedAt'] == null
          ? null
          : _nonNegativeDbInt(row['resolvedAt'], 'resolvedAt'),
      resolution: SyncV2ConflictResolution.parseNullable(row['resolution']),
    );
  }
}

class SyncV2EntityState {
  SyncV2EntityState({
    required this.entity,
    required this.syncId,
    required this.localKey,
    required this.serverRevision,
    required this.serverChangeId,
    required this.localRevision,
    required this.localHeadChangeId,
    required this.operation,
    required this.updatedAt,
  });

  final SyncV2Entity entity;
  final String syncId;
  final String? localKey;
  final int serverRevision;
  final String? serverChangeId;
  final int localRevision;
  final String? localHeadChangeId;
  final SyncV2Operation operation;
  final int updatedAt;

  factory SyncV2EntityState.fromDatabaseRow(Map<String, Object?> row) {
    final serverRevision =
        _nonNegativeDbInt(row['serverRevision'], 'serverRevision');
    final localRevision =
        _nonNegativeDbInt(row['localRevision'], 'localRevision');
    final serverChangeId =
        _nullableUuid(row['serverChangeId'], 'serverChangeId');
    final localHeadChangeId =
        _nullableUuid(row['localHeadChangeId'], 'localHeadChangeId');
    if (localRevision < serverRevision) {
      throw const FormatException('localRevision 不能小于 serverRevision');
    }
    if ((serverRevision == 0) != (serverChangeId == null)) {
      throw const FormatException('server revision/head 不一致');
    }
    if ((localRevision == 0) != (localHeadChangeId == null)) {
      throw const FormatException('local revision/head 不一致');
    }
    return SyncV2EntityState(
      entity: SyncV2Entity.parse(row['entity']),
      syncId: SyncV2Uuid.require(row['syncId'], 'syncId'),
      localKey: _nullableString(row['localKey'], 'localKey'),
      serverRevision: serverRevision,
      serverChangeId: serverChangeId,
      localRevision: localRevision,
      localHeadChangeId: localHeadChangeId,
      operation: SyncV2Operation.parse(row['op']),
      updatedAt: _nonNegativeDbInt(row['updatedAt'], 'updatedAt'),
    );
  }
}

int _positiveDecimal(Object? value, String field) {
  if (value is! String || !RegExp(r'^[1-9]\d*$').hasMatch(value)) {
    throw FormatException('$field 必须是正十进制字符串');
  }
  final parsed = BigInt.parse(value);
  if (parsed > BigInt.from(_maxSqliteInteger)) {
    throw FormatException('$field 超出 SQLite INTEGER 范围');
  }
  return parsed.toInt();
}

int _positiveDbInt(Object? value, String field) {
  if (value is! int || value <= 0) {
    throw FormatException('$field 必须是正整数');
  }
  return value;
}

void _positiveRuntimeInt(int value, String field) {
  if (value <= 0 || value > _maxSqliteInteger) {
    throw FormatException('$field 必须是 SQLite 范围内的正整数');
  }
}

int _nonNegativeDbInt(Object? value, String field) {
  if (value is! int || value < 0) {
    throw FormatException('$field 必须是非负整数');
  }
  return value;
}

String? _nullableUuid(Object? value, String field) =>
    value == null ? null : SyncV2Uuid.require(value, field);

String _requiredString(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field 必须是非空字符串');
  }
  return value;
}

String? _nullableString(Object? value, String field) {
  if (value == null) return null;
  if (value is! String) throw FormatException('$field 必须是字符串');
  return value;
}

Map<String, Object?> _stringKeyMap(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 必须是 JSON object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$field 的 key 必须是字符串');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, dynamic>? _decodePayload(Object? value, String field) {
  if (value == null) return null;
  if (value is! String) throw FormatException('$field 必须是 JSON 字符串');
  try {
    return _jsonObject(jsonDecode(value), field, allowNull: false);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw FormatException('$field 不是有效 JSON');
  }
}

Map<String, dynamic>? _jsonObject(
  Object? value,
  String field, {
  required bool allowNull,
}) {
  if (value == null && allowNull) return null;
  if (value is! Map) throw FormatException('$field 必须是 JSON object');
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$field 的 key 必须是字符串');
    }
    _validateJsonValue(entry.value, '$field.${entry.key}');
    result[entry.key as String] = entry.value;
  }
  return _freezeJsonObject(result);
}

void _validateJsonValue(Object? value, String field) {
  if (value == null || value is bool || value is String || value is int) return;
  if (value is double) {
    if (!value.isFinite) throw FormatException('$field 不是有限数值');
    return;
  }
  if (value is List) {
    for (var index = 0; index < value.length; index++) {
      _validateJsonValue(value[index], '$field[$index]');
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$field 的 key 必须是字符串');
      }
      _validateJsonValue(entry.value, '$field.${entry.key}');
    }
    return;
  }
  throw FormatException('$field 不是 JSON 值');
}

Map<String, dynamic>? _freezeJsonObject(Map<String, dynamic>? value) {
  if (value == null) return null;
  _validateJsonValue(value, 'payload');
  return UnmodifiableMapView<String, dynamic>({
    for (final entry in value.entries) entry.key: _freezeJsonValue(entry.value),
  });
}

Object? _freezeJsonValue(Object? value) {
  if (value is Map) {
    return UnmodifiableMapView<String, dynamic>({
      for (final entry in value.entries)
        entry.key as String: _freezeJsonValue(entry.value),
    });
  }
  if (value is List) {
    return UnmodifiableListView<Object?>(
      value.map(_freezeJsonValue).toList(growable: false),
    );
  }
  return value;
}

void _validatePayloadForOperation(
  SyncV2Operation operation,
  Map<String, dynamic>? payload,
) {
  if (operation == SyncV2Operation.upsert && payload == null) {
    throw const FormatException('upsert payload 必须是 JSON object');
  }
  if (operation == SyncV2Operation.delete && payload != null) {
    throw const FormatException('delete payload 必须为 null');
  }
}

void _validateOutboxStateEvidence({
  required SyncV2OutboxState state,
  required String? lastError,
  required String? ackReason,
  required int? expectedRevision,
  required String? ackRemoteEvidence,
  required SyncV2Entity entity,
  required String syncId,
}) {
  if (expectedRevision != null) {
    _positiveRuntimeInt(expectedRevision, 'expectedRevision');
  }
  switch (state) {
    case SyncV2OutboxState.pending:
      if (ackReason != null ||
          expectedRevision != null ||
          ackRemoteEvidence != null) {
        throw const FormatException('pending outbox 不应包含 ACK 终态证据');
      }
      break;
    case SyncV2OutboxState.conflict:
      if (ackReason != 'remote_ahead' ||
          expectedRevision == null ||
          ackRemoteEvidence == null) {
        throw const FormatException('conflict outbox 终态证据非法');
      }
      break;
    case SyncV2OutboxState.rejected:
      final validRevisionGap =
          ackReason == 'revision_gap' && expectedRevision != null;
      final validReuse =
          ackReason == 'change_id_reused' && expectedRevision == null;
      if ((!validRevisionGap && !validReuse) || ackRemoteEvidence == null) {
        throw const FormatException('rejected outbox 终态证据非法');
      }
      break;
    case SyncV2OutboxState.blocked:
      if (ackReason != 'blocked_by_ancestor' || expectedRevision == null) {
        throw const FormatException('blocked outbox 终态证据非法');
      }
      break;
  }
  if (state != SyncV2OutboxState.pending && lastError != null) {
    throw const FormatException('终态 outbox 不应保留上次网络错误');
  }
  if (ackRemoteEvidence != null) {
    final remote = _decodeRemoteEvidence(ackRemoteEvidence);
    if (state == SyncV2OutboxState.conflict && remote == null) {
      throw const FormatException('conflict outbox 缺少 remote evidence');
    }
    if (remote != null &&
        (remote.entity != entity || remote.syncId != syncId)) {
      throw const FormatException('outbox ACK remote identity 不一致');
    }
    if (ackReason == 'change_id_reused' && remote != null) {
      throw const FormatException('change_id_reused 不应包含 remote evidence');
    }
    final carriesFailureHead = ackReason == 'remote_ahead' ||
        ackReason == 'revision_gap' ||
        ackReason == 'blocked_by_ancestor';
    if (carriesFailureHead && remote == null && expectedRevision != 1) {
      throw const FormatException('remote null 与 expectedRevision 不一致');
    }
    if (carriesFailureHead && remote != null) {
      if (remote.revision == _maxSqliteInteger ||
          expectedRevision != remote.revision + 1) {
        throw const FormatException('remote evidence 与 expectedRevision 不一致');
      }
    }
  }
}

String _encodeRemoteEvidence(SyncV2RemoteChange? remote) {
  if (remote == null) return 'null';
  return jsonEncode(_canonicalJsonValue({
    'changeId': remote.changeId,
    'deviceId': remote.deviceId,
    'entity': remote.entity.wireName,
    'op': remote.operation.wireName,
    'parentChangeId': remote.parentChangeId,
    'payload': remote.payload,
    'revision': '${remote.revision}',
    'sequence': '${remote.sequence}',
    'syncId': remote.syncId,
  }));
}

SyncV2RemoteChange? _decodeRemoteEvidence(String evidence) {
  if (evidence == 'null') return null;
  try {
    final decoded = jsonDecode(evidence);
    final remote = SyncV2RemoteChange.fromJson(
      _stringKeyMap(decoded, 'ackRemoteEvidence'),
    );
    if (_encodeRemoteEvidence(remote) != evidence) {
      throw const FormatException('ackRemoteEvidence 不是 canonical JSON');
    }
    return remote;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('ackRemoteEvidence 不是有效 JSON');
  }
}

Object? _canonicalJsonValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJsonValue(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalJsonValue).toList(growable: false);
  }
  return value;
}

void _validateAckShape({
  required SyncV2AckResult result,
  required String? reason,
  required int? expectedRevision,
  required SyncV2RemoteChange? remote,
  required int? sequence,
}) {
  switch (result) {
    case SyncV2AckResult.accepted:
      if (reason != null || expectedRevision != null || remote != null) {
        throw const FormatException('accepted ACK 含非法冲突字段');
      }
      if (sequence == null) {
        throw const FormatException('accepted ACK 缺少 sequence');
      }
      break;
    case SyncV2AckResult.conflict:
      if (reason != 'remote_ahead' ||
          expectedRevision == null ||
          remote == null ||
          sequence != null) {
        throw const FormatException('conflict ACK 结构非法');
      }
      break;
    case SyncV2AckResult.rejected:
      if (reason != 'revision_gap' && reason != 'change_id_reused') {
        throw const FormatException('rejected ACK reason 非法');
      }
      if (reason == 'revision_gap' && expectedRevision == null) {
        throw const FormatException('revision_gap 缺少 expectedRevision');
      }
      if (reason == 'change_id_reused' && expectedRevision != null) {
        throw const FormatException('change_id_reused 不应包含 expectedRevision');
      }
      if (reason == 'change_id_reused' && remote != null) {
        throw const FormatException('change_id_reused 不应包含 remote');
      }
      if (sequence != null) {
        throw const FormatException('rejected ACK 不应包含 sequence');
      }
      break;
    case SyncV2AckResult.blocked:
      if (reason != 'blocked_by_ancestor' ||
          expectedRevision == null ||
          sequence != null) {
        throw const FormatException('blocked ACK 结构非法');
      }
      break;
  }
}
