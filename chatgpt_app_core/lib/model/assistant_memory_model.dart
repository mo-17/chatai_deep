class AssistantMemoryModel {
  int? id;
  int assistantId;
  String content;
  String source;
  int createdAt;
  int updatedAt;

  AssistantMemoryModel({
    this.id,
    required this.assistantId,
    required this.content,
    this.source = 'manual',
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  factory AssistantMemoryModel.fromJson(Map<String, dynamic> json) =>
      AssistantMemoryModel(
        id: json['id'] as int?,
        assistantId: json['assistantId'] as int? ?? 0,
        content: json['content'] as String? ?? '',
        source: json['source'] as String? ?? 'manual',
        createdAt: json['createdAt'] as int? ?? 0,
        updatedAt: json['updatedAt'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assistantId': assistantId,
        'content': content,
        'source': source,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}
