import 'dart:convert';

import 'package:flutter/cupertino.dart';

enum OwnerType { receiver, sender }

///枚举类型在数据库保存为string，取出时转成枚举
OwnerType _of(String name) {
  if (name == OwnerType.receiver.toString()) {
    return OwnerType.receiver;
  } else {
    return OwnerType.sender;
  }
}

class MessageModel {
  final int? id;

  ///为了避免添加数据的时候重新刷新的问题
  final GlobalKey key;

  ///消息发送方和接收方的标识，用于决定消息展示在那一侧
  final OwnerType ownerType;

  ///消息发送方的名字
  final String? ownerName;

  ///头像url
  final String? avatar;

  ///消息内容
  final String content;

  ///milliseconds since
  final int createdAt;

  ///是否展示创建时间
  bool showCreatedTime = false;

  ///图片本地路径（发送中持有，落库后置空）
  final List<String>? imagePaths;

  ///已发送的图片：data:image/...;base64,xxx 或后端返回的 url
  final List<String>? imageUrlsOrB64;

  MessageModel({
    this.id,
    this.ownerName,
    required this.ownerType,
    this.avatar,
    required this.content,
    required this.createdAt,
    this.imagePaths,
    this.imageUrlsOrB64,
    GlobalKey? key,
  }) : key = key ?? GlobalKey();

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    List<String>? parseImages(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      try {
        final list = jsonDecode(raw) as List;
        return list.cast<String>();
      } catch (_) {
        return null;
      }
    }

    return MessageModel(
      ownerType: _of(json['ownerType']),
      content: json['content'] ?? '',
      createdAt: json['createdAt'],
      ownerName: json['ownerName'],
      avatar: json['avatar'],
      id: json['id'],
      imageUrlsOrB64: parseImages(json['images'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        //数据库存储不支持枚举等复合类型
        'ownerType': ownerType.toString(),
        'content': content,
        'createdAt': createdAt,
        'avatar': avatar,
        'ownerName': ownerName,
        if (imageUrlsOrB64 != null && imageUrlsOrB64!.isNotEmpty)
          'images': jsonEncode(imageUrlsOrB64),
      };

  MessageModel copyWith({
    String? content,
    List<String>? imagePaths,
    List<String>? imageUrlsOrB64,
  }) =>
      MessageModel(
        id: id,
        ownerType: ownerType,
        content: content ?? this.content,
        createdAt: createdAt,
        ownerName: ownerName,
        avatar: avatar,
        imagePaths: imagePaths ?? this.imagePaths,
        imageUrlsOrB64: imageUrlsOrB64 ?? this.imageUrlsOrB64,
        // 复用同一 GlobalKey：内容更新（如流式收尾落库）不应让 ListView 重建
        // 整个气泡子树 —— 否则块化渲染里展开的思考块会被销毁、计时器/展开态丢失。
        key: key,
      );
}
