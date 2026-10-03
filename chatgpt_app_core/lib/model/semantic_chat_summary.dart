/// 请求侧的历史摘要缓存；原始消息仍保存在 tb_messages，绝不被摘要覆盖。
class SemanticChatSummary {
  final int cid;
  final String sourceFingerprint;
  final int sourceMessageCount;
  final String content;
  final int createdAt;

  const SemanticChatSummary({
    required this.cid,
    required this.sourceFingerprint,
    required this.sourceMessageCount,
    required this.content,
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        'cid': cid,
        'sourceFingerprint': sourceFingerprint,
        'sourceMessageCount': sourceMessageCount,
        'content': content,
        'createdAt': createdAt,
      };

  static SemanticChatSummary? fromRow(Map<String, Object?> row) {
    final cid = row['cid'];
    final fingerprint = row['sourceFingerprint'];
    final count = row['sourceMessageCount'];
    final content = row['content'];
    final createdAt = row['createdAt'];
    if (cid is! int ||
        fingerprint is! String ||
        fingerprint.isEmpty ||
        count is! int ||
        count <= 0 ||
        content is! String ||
        content.trim().isEmpty ||
        createdAt is! int) {
      return null;
    }
    return SemanticChatSummary(
      cid: cid,
      sourceFingerprint: fingerprint,
      sourceMessageCount: count,
      content: content,
      createdAt: createdAt,
    );
  }
}
