class ToolAuditRecord {
  final int? id;
  final String toolName;
  final String sourceType;
  final String sourceId;
  final String sourceName;
  final bool trusted;
  final bool readOnly;
  final bool approved;
  final bool success;
  final int argCount;
  final String argsPreview;
  final String resultPreview;
  final String? error;
  final int createdAt;

  const ToolAuditRecord({
    this.id,
    required this.toolName,
    required this.sourceType,
    required this.sourceId,
    required this.sourceName,
    required this.trusted,
    required this.readOnly,
    required this.approved,
    required this.success,
    required this.argCount,
    this.argsPreview = '',
    this.resultPreview = '',
    this.error,
    required this.createdAt,
  });

  factory ToolAuditRecord.fromJson(Map<String, dynamic> json) =>
      ToolAuditRecord(
        id: json['id'] as int?,
        toolName: json['toolName'] as String? ?? '',
        sourceType: json['sourceType'] as String? ?? '',
        sourceId: json['sourceId'] as String? ?? '',
        sourceName: json['sourceName'] as String? ?? '',
        trusted: _boolOf(json['trusted']),
        readOnly: _boolOf(json['readOnly']),
        approved: _boolOf(json['approved']),
        success: _boolOf(json['success']),
        argCount: json['argCount'] as int? ?? 0,
        argsPreview: json['argsPreview'] as String? ?? '',
        resultPreview: json['resultPreview'] as String? ?? '',
        error: json['error'] as String?,
        createdAt: json['createdAt'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'sourceType': sourceType,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'trusted': trusted ? 1 : 0,
        'readOnly': readOnly ? 1 : 0,
        'approved': approved ? 1 : 0,
        'success': success ? 1 : 0,
        'argCount': argCount,
        'argsPreview': argsPreview,
        'resultPreview': resultPreview,
        'error': error,
        'createdAt': createdAt,
      };

  static bool _boolOf(Object? raw) {
    if (raw is bool) return raw;
    if (raw is int) return raw != 0;
    if (raw is String) return raw == '1' || raw.toLowerCase() == 'true';
    return false;
  }
}
