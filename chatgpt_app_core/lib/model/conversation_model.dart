import 'dart:convert';

/// 会话会话（聊天）列表表模型
class ConversationModel {
  int? id;
  int cid;
  String? title;
  String icon;
  int? updateAt;
  int stickTime;
  int? messageCount;
  String? lastMessage;

  ///绑定的助手 id（阶段七，tb_assistant.id）。null = 未绑定助手。
  int? assistantId;

  ///所属项目 id。null = 未分类，兼容旧会话。
  int? projectId;

  ///自定义头像类型：null=使用原 icon，emoji=表情，image=本地图片路径。
  String? avatarType;

  ///自定义头像值：emoji 字符或本地图片路径。
  String? avatarValue;

  ///会话级服务商覆盖。null = 跟随全局设置；仅本地直连模式使用。
  String? modelProviderId;

  ///会话级模型覆盖。null = 跟随全局/助手设置。
  String? modelId;

  ///会话级联网搜索覆盖。null = 跟随全局设置。
  bool? webSearchEnabled;

  ///会话级工具集覆盖。null = 跟随助手绑定；空列表 = 不暴露绑定工具。
  List<String>? toolIds;

  ///会话消息是否有变化
  bool hadChanged = false;

  ConversationModel(
      {this.id,
      required this.cid,
      this.title,
      required this.icon,
      this.updateAt,
      this.stickTime = 0,
      this.messageCount,
      this.lastMessage,
      this.assistantId,
      this.projectId,
      this.avatarType,
      this.avatarValue,
      this.modelProviderId,
      this.modelId,
      this.webSearchEnabled,
      this.toolIds});

  factory ConversationModel.fromJson(Map<String, dynamic> json) =>
      ConversationModel(
          id: json['id'],
          cid: json['cid'],
          title: json['title'],
          icon: json['icon'],
          updateAt: json['updateAt'],
          stickTime: json['stickTime'],
          messageCount: json['messageCount'],
          lastMessage: json['lastMessage'],
          assistantId: json['assistantId'],
          projectId: json['projectId'],
          avatarType: json['avatarType'],
          avatarValue: json['avatarValue'],
          modelProviderId: json['modelProviderId'],
          modelId: json['modelId'],
          webSearchEnabled: _boolOf(json['webSearchEnabled']),
          toolIds: _decodeToolIds(json['toolIds']));

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['cid'] = cid;
    data['title'] = title;
    data['icon'] = icon;
    data['updateAt'] = updateAt;
    data['stickTime'] = stickTime;
    data['messageCount'] = messageCount;
    data['lastMessage'] = lastMessage;
    data['assistantId'] = assistantId;
    data['projectId'] = projectId;
    data['avatarType'] = avatarType;
    data['avatarValue'] = avatarValue;
    data['modelProviderId'] = modelProviderId;
    data['modelId'] = modelId;
    data['webSearchEnabled'] =
        webSearchEnabled == null ? null : (webSearchEnabled! ? 1 : 0);
    data['toolIds'] = toolIds == null ? null : jsonEncode(toolIds);
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
