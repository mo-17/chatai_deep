enum AssistantMemoryStatus {
  pending,
  active,
  rejected,
  archived,
}

class AssistantMemoryModel {
  int? id;
  int assistantId;
  String content;
  String source;
  int createdAt;
  int updatedAt;

  /// 跨备份/同步稳定的记忆身份。旧行由 DAO 回填为
  /// `legacy:<assistantId>:<id>`，新行使用 UUID v4。
  String memoryId;

  /// 记忆所属助手的稳定引用。现有助手尚未持有独立 UUID 时使用兼容引用
  /// `legacy:<assistantId>`；Backup/Sync 层可在映射时替换。
  String assistantSyncId;

  /// 规范化来源类型；[source] 继续保留原有短标签和 UI 兼容语义。
  String sourceType;
  String sourceConversationId;
  String sourceMessageId;
  AssistantMemoryStatus status;
  bool confirmedByUser;
  int revision;

  AssistantMemoryModel({
    this.id,
    required this.assistantId,
    required this.content,
    this.source = 'manual',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.memoryId = '',
    this.assistantSyncId = '',
    String? sourceType,
    this.sourceConversationId = '',
    this.sourceMessageId = '',
    this.status = AssistantMemoryStatus.active,
    this.confirmedByUser = true,
    this.revision = 1,
  }) : sourceType = sourceType ?? source;

  /// 会话内“记住”动作的唯一持久化入口。候选内容在用户确认前只存在内存中；
  /// 经过编辑弹窗确认后才创建 active 记录。
  factory AssistantMemoryModel.confirmedFromConversation({
    required int assistantId,
    required String content,
    required String source,
    required String sourceType,
    required String conversationId,
    required String messageId,
  }) =>
      AssistantMemoryModel(
        assistantId: assistantId,
        content: content,
        source: source,
        sourceType: sourceType,
        sourceConversationId: conversationId,
        sourceMessageId: messageId,
        status: AssistantMemoryStatus.active,
        confirmedByUser: true,
      );

  factory AssistantMemoryModel.fromJson(Map<String, dynamic> json) =>
      AssistantMemoryModel(
        id: _nullableInt(json['id']),
        assistantId: _intValue(json['assistantId']),
        content: json['content'] as String? ?? '',
        source: json['source'] as String? ?? 'manual',
        createdAt: _intValue(json['createdAt']),
        updatedAt: _intValue(json['updatedAt']),
        memoryId: json['memoryId'] as String? ?? '',
        assistantSyncId: json['assistantSyncId'] as String? ?? '',
        sourceType: json.containsKey('sourceType')
            ? json['sourceType'] as String? ?? 'legacy'
            : 'legacy',
        sourceConversationId: json['sourceConversationId'] as String? ?? '',
        sourceMessageId: json['sourceMessageId'] as String? ?? '',
        status: json.containsKey('status')
            ? _statusValue(json['status'])
            : AssistantMemoryStatus.active,
        confirmedByUser: json.containsKey('confirmedByUser')
            ? _confirmationValue(json['confirmedByUser'])
            : true,
        revision: _positiveInt(json['revision'], fallback: 1),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assistantId': assistantId,
        'content': content,
        'source': source,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'memoryId': memoryId,
        'assistantSyncId': assistantSyncId,
        'sourceType': sourceType,
        'sourceConversationId': sourceConversationId,
        'sourceMessageId': sourceMessageId,
        'status': status.name,
        'confirmedByUser': confirmedByUser ? 1 : 0,
        'revision': revision,
      };

  static AssistantMemoryStatus _statusValue(Object? raw) {
    final name = raw?.toString();
    for (final value in AssistantMemoryStatus.values) {
      if (value.name == name) return value;
    }
    return AssistantMemoryStatus.archived;
  }

  static bool _confirmationValue(Object? raw) {
    if (raw is bool) return raw;
    if (raw is int && (raw == 0 || raw == 1)) return raw == 1;
    return false;
  }

  static int _intValue(Object? raw) => _nullableInt(raw) ?? 0;

  static int _positiveInt(Object? raw, {required int fallback}) {
    final value = _nullableInt(raw);
    return value != null && value > 0 ? value : fallback;
  }

  static int? _nullableInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }
}
