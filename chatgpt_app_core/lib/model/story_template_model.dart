class StoryTemplateKind {
  static const tavernRoom = 'tavernRoom';
}

class StoryTemplateModel {
  int? id;
  String title;
  String sourceTitle;
  String kind;
  bool translated;
  String payload;
  int createdAt;
  int updatedAt;

  StoryTemplateModel({
    this.id,
    required this.title,
    this.sourceTitle = '',
    this.kind = StoryTemplateKind.tavernRoom,
    this.translated = false,
    required this.payload,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryTemplateModel.fromJson(Map<String, dynamic> json) =>
      StoryTemplateModel(
        id: json['id'] as int?,
        title: json['title'] as String? ?? '未命名酒馆模板',
        sourceTitle: json['sourceTitle'] as String? ?? '',
        kind: json['kind'] as String? ?? StoryTemplateKind.tavernRoom,
        translated: (json['translated'] as int? ?? 0) != 0,
        payload: json['payload'] as String? ?? '{}',
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'sourceTitle': sourceTitle,
        'kind': kind,
        'translated': translated ? 1 : 0,
        'payload': payload,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}
