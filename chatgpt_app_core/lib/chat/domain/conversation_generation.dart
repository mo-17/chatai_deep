import 'dart:convert';
import 'package:crypto/crypto.dart';

String generationContentHash(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// 点击重试时捕获原始数据库行；正文相同不代表附件或消息身份相同。
String generationSourceRowHash(Map<String, Object?> row) =>
    generationContentHash(jsonEncode({
      for (final key in (row.keys.toList()..sort())) key: row[key],
    }));

enum ConversationGenerationStage {
  preparing,
  generating,
  awaitingConfirmation,
  persisting,
  complete,
  interrupted,
  failed,
  persistenceFailed,
}

/// 只保存执行证据，不保存服务对象、API key 或登录凭据。
class ConversationGenerationRecord {
  final String runId, sourceId, sourceHash, receiverId, state, reason;
  final int cid, conversationRowId, revision, receiverAt, attempts;
  final int? assistantId, userRowId, receiverRowId, usageRowId;
  const ConversationGenerationRecord(
      {required this.runId,
      required this.cid,
      required this.conversationRowId,
      this.assistantId,
      required this.sourceId,
      required this.sourceHash,
      required this.receiverId,
      required this.receiverAt,
      required this.revision,
      required this.state,
      this.reason = '',
      this.attempts = 0,
      this.userRowId,
      this.receiverRowId,
      this.usageRowId});
  bool get terminal =>
      const {'complete', 'interrupted', 'failed'}.contains(state);
  factory ConversationGenerationRecord.fromRow(Map<String, Object?> row) =>
      ConversationGenerationRecord(
          runId: row['runId'] as String,
          cid: row['cid'] as int,
          conversationRowId: row['conversationRowId'] as int,
          assistantId: row['assistantId'] as int?,
          sourceId: row['sourceId'] as String,
          sourceHash: row['sourceHash'] as String,
          receiverId: row['receiverId'] as String,
          receiverAt: row['receiverAt'] as int,
          revision: row['revision'] as int,
          state: row['state'] as String,
          reason: row['reason'] as String? ?? '',
          attempts: row['attempts'] as int? ?? 0,
          userRowId: row['userRowId'] as int?,
          receiverRowId: row['receiverRowId'] as int?,
          usageRowId: row['usageRowId'] as int?);
}
