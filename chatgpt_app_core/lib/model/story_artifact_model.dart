class StoryArtifactType {
  static const outline = 'outline';
  static const chapter = 'chapter';
  static const timeline = 'timeline';
  static const relationship = 'relationship';
  static const foreshadowing = 'foreshadowing';

  static const values = [
    outline,
    chapter,
    timeline,
    relationship,
    foreshadowing,
  ];

  static String labelOf(String type) {
    switch (type) {
      case outline:
        return '大纲';
      case chapter:
        return '章节';
      case timeline:
        return '时间线';
      case relationship:
        return '人物关系';
      case foreshadowing:
        return '伏笔';
      default:
        return '创作资料';
    }
  }
}

class StoryArtifactModel {
  int? id;
  int roomId;
  String type;
  String title;
  String content;
  String status;
  int sortOrder;
  int createdAt;
  int updatedAt;

  StoryArtifactModel({
    this.id,
    required this.roomId,
    required this.type,
    required this.title,
    this.content = '',
    this.status = '',
    this.sortOrder = 0,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryArtifactModel.fromJson(Map<String, dynamic> json) =>
      StoryArtifactModel(
        id: json['id'] as int?,
        roomId: json['roomId'] as int? ?? 0,
        type: json['type'] as String? ?? StoryArtifactType.outline,
        title: json['title'] as String? ?? '未命名资料',
        content: json['content'] as String? ?? '',
        status: json['status'] as String? ?? '',
        sortOrder: json['sortOrder'] as int? ?? 0,
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'type': type,
        'title': title,
        'content': content,
        'status': status,
        'sortOrder': sortOrder,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class StoryArtifactRevisionModel {
  final int id;
  final int artifactId;
  final String title;
  final String content;
  final String status;
  final int createdAt;

  const StoryArtifactRevisionModel({
    required this.id,
    required this.artifactId,
    required this.title,
    required this.content,
    required this.status,
    required this.createdAt,
  });

  factory StoryArtifactRevisionModel.fromJson(Map<String, dynamic> json) =>
      StoryArtifactRevisionModel(
        id: json['id'] as int,
        artifactId: json['artifactId'] as int,
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        status: json['status'] as String? ?? '',
        createdAt: json['createdAt'] as int? ?? 0,
      );
}
