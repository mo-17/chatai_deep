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
      this.assistantId});

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
          assistantId: json['assistantId']);

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
    return data;
  }
}
