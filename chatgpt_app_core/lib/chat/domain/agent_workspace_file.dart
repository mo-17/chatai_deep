import 'dart:convert';

/// 对话工作区的文件元信息。原始来源只供存储去重，不进入工具返回值。
class AgentWorkspaceFile {
  final int id;
  final int cid;
  final String name;
  final String kind;
  final int revision;
  final int characterCount;
  final int lineCount;
  final int pageCount;
  final int sizeBytes;
  final int updatedAt;
  final int createdAt;
  final String sourceKey;
  final String contentHash;
  final List<Map<String, dynamic>> sections;
  final int sectionCount;

  const AgentWorkspaceFile({
    required this.id,
    required this.cid,
    required this.name,
    required this.kind,
    required this.revision,
    required this.characterCount,
    required this.lineCount,
    required this.pageCount,
    required this.sizeBytes,
    required this.updatedAt,
    this.createdAt = 0,
    this.sourceKey = '',
    this.contentHash = '',
    this.sections = const [],
    this.sectionCount = 0,
  });

  bool get isInput => kind == 'input';

  factory AgentWorkspaceFile.fromJson(Map<String, dynamic> json) =>
      AgentWorkspaceFile(
        id: (json['id'] as num).toInt(),
        cid: (json['cid'] as num).toInt(),
        name: json['name'] as String,
        kind: json['kind'] as String,
        revision:
            ((json['currentRevision'] ?? json['revision']) as num).toInt(),
        characterCount: (json['characterCount'] as num).toInt(),
        lineCount: (json['lineCount'] as num).toInt(),
        pageCount: (json['pageCount'] as num).toInt(),
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        updatedAt: (json['updatedAt'] as num).toInt(),
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        sourceKey: json['sourceKey'] as String? ?? '',
        contentHash: json['contentHash'] as String? ?? '',
        sections: _sections(json['sections']),
        sectionCount: (json['sectionCount'] as num?)?.toInt() ?? 0,
      );

  /// 工具/界面可见信息不包含完整来源路径。
  Map<String, dynamic> toJson() => {
        'id': id,
        'cid': cid,
        'name': name,
        'kind': kind,
        'revision': revision,
        'characterCount': characterCount,
        'lineCount': lineCount,
        'pageCount': pageCount,
        'sizeBytes': sizeBytes,
        'updatedAt': updatedAt,
        'createdAt': createdAt,
        'readOnly': isInput,
        'offsetUnit': 'utf16',
        'sections': sections,
        'sectionCount': sectionCount,
      };

  static List<Map<String, dynamic>> _sections(Object? value) {
    final decoded = value is String ? jsonDecode(value) : value;
    return decoded is List
        ? decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : const [];
  }
}

class AgentWorkspaceRevision {
  final int fileId;
  final int revision;
  final String content;
  final String note;
  final int createdAt;
  final List<String> pageTexts;

  AgentWorkspaceRevision({
    required this.fileId,
    required this.revision,
    required this.content,
    required this.note,
    required this.createdAt,
    List<String> pageTexts = const [],
  }) : pageTexts = List.unmodifiable(pageTexts);

  factory AgentWorkspaceRevision.fromJson(Map<String, dynamic> json) {
    final pages = json['pageTexts'];
    final decoded = pages is String ? jsonDecode(pages) : pages;
    return AgentWorkspaceRevision(
      fileId: (json['fileId'] as num).toInt(),
      revision: (json['revision'] as num).toInt(),
      content: json['content'] as String,
      note: json['note'] as String? ?? '',
      createdAt: (json['createdAt'] as num).toInt(),
      pageTexts: decoded is List ? decoded.cast<String>() : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'revision': revision,
        'content': content,
        'note': note,
        'createdAt': createdAt,
        'pageTexts': pageTexts,
      };
}
