import 'dart:convert';

/// 知识库文档（L4a）。一个文档导入后被切成若干 chunk 存入 tb_kb_chunk，
/// 元信息（标题、片段数、时间）存 tb_kb_doc。
class KnowledgeDoc {
  int? id;
  String title;
  int chunkCount;
  int createdAt;
  String uid, folder, contentHash, sourceKind, sourceAsset;
  int revision, updatedAt;
  bool archived;
  List<String> tags;

  KnowledgeDoc({
    this.id,
    required this.title,
    this.chunkCount = 0,
    this.createdAt = 0,
    this.uid = '',
    this.folder = '',
    this.contentHash = '',
    this.sourceKind = 'text',
    this.sourceAsset = '',
    this.revision = 1,
    this.updatedAt = 0,
    this.archived = false,
    this.tags = const [],
  });

  factory KnowledgeDoc.fromJson(Map<String, dynamic> json) => KnowledgeDoc(
        id: json['id'] as int?,
        title: json['title'] as String? ?? '',
        chunkCount: json['chunkCount'] as int? ?? 0,
        createdAt: json['createdAt'] as int? ?? 0,
        uid: json['uid'] as String? ?? '',
        folder: json['folder'] as String? ?? '',
        contentHash: json['contentHash'] as String? ?? '',
        sourceKind: json['sourceKind'] as String? ?? 'text',
        sourceAsset: json['sourceAsset'] as String? ?? '',
        revision: json['revision'] as int? ?? 1,
        updatedAt: json['updatedAt'] as int? ?? 0,
        archived: json['archived'] == 1,
        tags: decodeKnowledgeTags(json['tags']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'chunkCount': chunkCount,
        'createdAt': createdAt,
        'uid': uid,
        'folder': folder,
        'contentHash': contentHash,
        'sourceKind': sourceKind,
        'sourceAsset': sourceAsset,
        'revision': revision,
        'updatedAt': updatedAt,
        'archived': archived ? 1 : 0,
        'tags': jsonEncode(tags),
      };
}

List<String> decodeKnowledgeTags(Object? raw) {
  try {
    final value = raw is String ? jsonDecode(raw) : raw;
    return value is List ? value.whereType<String>().toList() : [];
  } catch (_) {
    return [];
  }
}
