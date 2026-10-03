/// 已导入技能的一篇参考资料。name 是包内名称，并不是本机文件路径。
class SkillCatalogReference {
  final String name;
  final String title;
  final String text;

  const SkillCatalogReference({
    required this.name,
    required this.title,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'title': title,
        'text': text,
      };

  factory SkillCatalogReference.fromJson(Map<String, dynamic> json) =>
      SkillCatalogReference(
        name: json['name'] as String,
        title: json['title'] as String,
        text: json['text'] as String,
      );
}

/// 目录仅携带名称与触发说明；正文直到 skill_load 被调用后才进入模型上下文。
class SkillCatalogSummary {
  final int assistantId;
  final String name;
  final String description;

  const SkillCatalogSummary({
    required this.assistantId,
    required this.name,
    required this.description,
  });
}

class SkillCatalogEntry extends SkillCatalogSummary {
  final int assistantCreatedAt;
  final String body;
  final List<SkillCatalogReference> references;

  const SkillCatalogEntry({
    required super.assistantId,
    required super.name,
    required super.description,
    required this.assistantCreatedAt,
    required this.body,
    this.references = const [],
  });
}
