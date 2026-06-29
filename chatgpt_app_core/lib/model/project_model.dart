import 'dart:convert';

/// 对话项目分组模型。
class ProjectModel {
  int? id;
  String name;
  String icon;
  int color;
  int sortOrder;
  int createdAt;
  int updatedAt;
  String? defaultProviderId;
  String? defaultModelId;
  int? defaultAssistantId;
  bool? defaultUseWebSearch;
  List<String>? defaultToolIds;

  /// 列表展示用的会话数量，不入库。
  int conversationCount;

  ProjectModel({
    this.id,
    required this.name,
    this.icon = '📁',
    this.color = 0xFF2E7D32,
    this.sortOrder = 0,
    this.defaultProviderId,
    this.defaultModelId,
    this.defaultAssistantId,
    this.defaultUseWebSearch,
    this.defaultToolIds,
    int? createdAt,
    int? updatedAt,
    this.conversationCount = 0,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory ProjectModel.fromJson(Map<String, dynamic> json) => ProjectModel(
        id: json['id'],
        name: json['name'] ?? '',
        icon: json['icon'] ?? '📁',
        color: json['color'] ?? 0xFF2E7D32,
        sortOrder: json['sortOrder'] ?? 0,
        defaultProviderId: json['defaultProviderId'],
        defaultModelId: json['defaultModelId'],
        defaultAssistantId: json['defaultAssistantId'],
        defaultUseWebSearch: _boolOf(json['defaultUseWebSearch']),
        defaultToolIds: _decodeToolIds(json['defaultToolIds']),
        createdAt: json['createdAt'],
        updatedAt: json['updatedAt'],
        conversationCount: json['conversationCount'] ?? 0,
      );

  Map<String, dynamic> toJson() {
    final data = <String, dynamic>{};
    data['id'] = id;
    data['name'] = name;
    data['icon'] = icon;
    data['color'] = color;
    data['sortOrder'] = sortOrder;
    data['defaultProviderId'] = defaultProviderId;
    data['defaultModelId'] = defaultModelId;
    data['defaultAssistantId'] = defaultAssistantId;
    data['defaultUseWebSearch'] =
        defaultUseWebSearch == null ? null : (defaultUseWebSearch! ? 1 : 0);
    data['defaultToolIds'] =
        defaultToolIds == null ? null : jsonEncode(defaultToolIds);
    data['createdAt'] = createdAt;
    data['updatedAt'] = updatedAt;
    return data;
  }

  static bool? _boolOf(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    if (raw is int) return raw != 0;
    if (raw is String) {
      if (raw == '1' || raw.toLowerCase() == 'true') return true;
      if (raw == '0' || raw.toLowerCase() == 'false') return false;
    }
    return null;
  }

  static List<String>? _decodeToolIds(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [
        for (final e in decoded)
          if (e is String) e
      ];
    } catch (_) {
      return null;
    }
  }
}
