import 'dart:convert';

import 'package:crypto/crypto.dart';

enum PersonalMemoryStatus { pending, active, rejected, archived }

/// 个人事实与助手/角色记忆分开存储；来源身份由本地消息 UUID 决定。
class PersonalMemory {
  final String memoryId;
  final String content;
  final String normalizedKey;
  final PersonalMemoryStatus status;
  final bool confirmedByUser;
  final String sourceType;
  final int? sourceCid;
  final String sourceMessageId;
  final String sourceFingerprint;
  final int suggestionEpoch;
  final String invalidReason;
  final int createdAt;
  final int updatedAt;
  final int revision;

  const PersonalMemory({
    required this.memoryId,
    required this.content,
    required this.normalizedKey,
    required this.status,
    required this.confirmedByUser,
    this.sourceType = 'manual',
    this.sourceCid,
    this.sourceMessageId = '',
    this.sourceFingerprint = '',
    this.suggestionEpoch = 0,
    this.invalidReason = '',
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
  });

  factory PersonalMemory.fromJson(Map<String, dynamic> row) => PersonalMemory(
        memoryId: row['memoryId'] as String,
        content: row['content'] as String,
        normalizedKey: row['normalizedKey'] as String,
        status: PersonalMemoryStatus.values.firstWhere(
          (v) => v.name == row['status'],
          orElse: () => PersonalMemoryStatus.archived,
        ),
        confirmedByUser: row['confirmedByUser'] == 1,
        sourceType: row['sourceType'] as String? ?? 'manual',
        sourceCid: row['sourceCid'] as int?,
        sourceMessageId: row['sourceMessageId'] as String? ?? '',
        sourceFingerprint: row['sourceFingerprint'] as String? ?? '',
        suggestionEpoch: row['suggestionEpoch'] as int? ?? 0,
        invalidReason: row['invalidReason'] as String? ?? '',
        createdAt: row['createdAt'] as int? ?? 0,
        updatedAt: row['updatedAt'] as int? ?? 0,
        revision: row['revision'] as int? ?? 1,
      );

  Map<String, Object?> toJson() => {
        'memoryId': memoryId,
        'content': content,
        'normalizedKey': normalizedKey,
        'status': status.name,
        'confirmedByUser': confirmedByUser ? 1 : 0,
        'sourceType': sourceType,
        'sourceCid': sourceCid,
        'sourceMessageId': sourceMessageId,
        'sourceFingerprint': sourceFingerprint,
        'suggestionEpoch': suggestionEpoch,
        'invalidReason': invalidReason,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'revision': revision,
      };

  static String fingerprint(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  static String keyFor(String text) =>
      fingerprint(text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ''));
}

class PersonalMemoryPreferences {
  final bool enabled;
  final bool suggestionsEnabled;
  final int epoch;
  final int enabledSince;
  final int revision;

  const PersonalMemoryPreferences({
    this.enabled = false,
    this.suggestionsEnabled = false,
    this.epoch = 0,
    this.enabledSince = 0,
    this.revision = 1,
  });

  factory PersonalMemoryPreferences.fromJson(Map<String, dynamic> row) =>
      PersonalMemoryPreferences(
        enabled: row['enabled'] == 1,
        suggestionsEnabled: row['suggestionsEnabled'] == 1,
        epoch: row['epoch'] as int? ?? 0,
        enabledSince: row['enabledSince'] as int? ?? 0,
        revision: row['revision'] as int? ?? 1,
      );
}

class PersonalMemorySource {
  final int cid;
  final String messageId;
  final String fingerprint;
  const PersonalMemorySource(this.cid, this.messageId, this.fingerprint);
}

/// 只有发送开始时捕获授权的轮次才能在成功落盘后提议；不补扫历史。
class PersonalMemoryTurn {
  final int cid;
  final int epoch;
  final int startedAt;
  final String rawInput;
  const PersonalMemoryTurn(this.cid, this.epoch, this.startedAt, this.rawInput);
}
