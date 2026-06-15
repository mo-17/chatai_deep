/// 知识库文档（L4a）。一个文档导入后被切成若干 chunk 存入 tb_kb_chunk，
/// 元信息（标题、片段数、时间）存 tb_kb_doc。
class KnowledgeDoc {
  int? id;
  String title;
  int chunkCount;
  int createdAt;

  KnowledgeDoc({
    this.id,
    required this.title,
    this.chunkCount = 0,
    this.createdAt = 0,
  });

  factory KnowledgeDoc.fromJson(Map<String, dynamic> json) => KnowledgeDoc(
        id: json['id'] as int?,
        title: json['title'] as String? ?? '',
        chunkCount: json['chunkCount'] as int? ?? 0,
        createdAt: json['createdAt'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'chunkCount': chunkCount,
        'createdAt': createdAt,
      };
}
