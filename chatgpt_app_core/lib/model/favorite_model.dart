///收藏模型
class FavoriteModel {
  /// primary key autoincrement
  int? id;

  ///发送者昵称
  String? ownerName;

  /// 消息的创建时间，单位milliseconds since。
  int? createdAt;

  ///消息内容
  String content;

  FavoriteModel(
      {this.id, this.ownerName, this.createdAt, required this.content});

  factory FavoriteModel.fromJson(Map<String, dynamic> json) => FavoriteModel(
        id: json['id'],
        ownerName: json['ownerName'],
        createdAt: json['createdAt'],
        content: json['content'],
      );

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['ownerName'] = ownerName;
    data['createdAt'] = createdAt;
    data['content'] = content;
    return data;
  }
}
