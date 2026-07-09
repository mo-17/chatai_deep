import 'dart:convert';

class StoryRoomModel {
  int? id;
  String title;
  String mode;
  String replyMode;
  int maxAutoReplies;
  String publicContext;
  String? modelProviderId;
  String? modelId;
  double? temperature;
  int? maxOutputTokens;
  int createdAt;
  int updatedAt;

  StoryRoomModel({
    this.id,
    required this.title,
    this.mode = StoryRoomMode.creation,
    String? replyMode,
    this.maxAutoReplies = 1,
    this.publicContext = '',
    this.modelProviderId,
    this.modelId,
    this.temperature,
    this.maxOutputTokens,
    int? createdAt,
    int? updatedAt,
  })  : replyMode = StoryReplyMode.normalize(replyMode),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryRoomModel.fromJson(Map<String, dynamic> json) => StoryRoomModel(
        id: json['id'] as int?,
        title: json['title'] as String? ?? '未命名创作房间',
        mode: StoryRoomMode.normalize(json['mode'] as String?),
        replyMode: StoryReplyMode.normalize(json['replyMode'] as String?),
        maxAutoReplies: _safeMaxAutoReplies(json['maxAutoReplies']),
        publicContext: json['publicContext'] as String? ?? '',
        modelProviderId: json['modelProviderId'] as String?,
        modelId: json['modelId'] as String?,
        temperature: (json['temperature'] as num?)?.toDouble(),
        maxOutputTokens: (json['maxOutputTokens'] as num?)?.toInt(),
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'mode': mode,
        'replyMode': replyMode,
        'maxAutoReplies': maxAutoReplies.clamp(1, 3),
        'publicContext': publicContext,
        'modelProviderId': modelProviderId,
        'modelId': modelId,
        'temperature': temperature,
        'maxOutputTokens': maxOutputTokens,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static int _safeMaxAutoReplies(Object? value) {
    final number = value is num ? value.toInt() : int.tryParse('$value');
    return (number ?? 1).clamp(1, 3);
  }
}

class StoryRoomMode {
  static const creation = 'creation';
  static const tavern = 'tavern';

  static String normalize(String? mode) {
    switch (mode) {
      case tavern:
        return tavern;
      case creation:
      default:
        return creation;
    }
  }

  static String labelOf(String mode) {
    switch (normalize(mode)) {
      case tavern:
        return '酒馆模式';
      case creation:
      default:
        return '创作模式';
    }
  }
}

class StoryReplyMode {
  static const manual = 'manual';
  static const autoSingle = 'autoSingle';
  static const autoMulti = 'autoMulti';

  static String normalize(String? mode) {
    switch (mode) {
      case manual:
        return manual;
      case autoMulti:
        return autoMulti;
      case autoSingle:
      default:
        return autoSingle;
    }
  }

  static String labelOf(String mode) {
    switch (normalize(mode)) {
      case manual:
        return '手动发言';
      case autoMulti:
        return '群聊轮换';
      case autoSingle:
      default:
        return '自动接话';
    }
  }
}

class StoryParticipantRole {
  static const author = 'author';
  static const narrator = 'narrator';
  static const assistant = 'assistant';

  static String labelOf(String role) {
    switch (role) {
      case author:
        return '作者';
      case narrator:
        return '旁白';
      case assistant:
        return '角色';
      default:
        return '参与者';
    }
  }
}

class StoryParticipantModel {
  int? id;
  int roomId;
  int? assistantId;
  String role;
  String name;
  String prompt;
  String? avatarType;
  String? avatarValue;
  String? voiceStyle;
  String? modelProviderId;
  String? modelId;
  double? temperature;
  int? maxOutputTokens;
  int sortOrder;
  bool enabled;
  int createdAt;
  int updatedAt;

  StoryParticipantModel({
    this.id,
    required this.roomId,
    this.assistantId,
    required this.role,
    required this.name,
    this.prompt = '',
    this.avatarType,
    this.avatarValue,
    this.voiceStyle,
    this.modelProviderId,
    this.modelId,
    this.temperature,
    this.maxOutputTokens,
    this.sortOrder = 0,
    this.enabled = true,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryParticipantModel.fromJson(Map<String, dynamic> json) =>
      StoryParticipantModel(
        id: json['id'] as int?,
        roomId: json['roomId'] as int? ?? 0,
        assistantId: json['assistantId'] as int?,
        role: json['role'] as String? ?? StoryParticipantRole.assistant,
        name: json['name'] as String? ?? '未命名角色',
        prompt: json['prompt'] as String? ?? '',
        avatarType: json['avatarType'] as String?,
        avatarValue: json['avatarValue'] as String?,
        voiceStyle: json['voiceStyle'] as String?,
        modelProviderId: json['modelProviderId'] as String?,
        modelId: json['modelId'] as String?,
        temperature: (json['temperature'] as num?)?.toDouble(),
        maxOutputTokens: (json['maxOutputTokens'] as num?)?.toInt(),
        sortOrder: json['sortOrder'] as int? ?? 0,
        enabled: (json['enabled'] as int? ?? 1) == 1,
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'assistantId': assistantId,
        'role': role,
        'name': name,
        'prompt': prompt,
        'avatarType': avatarType,
        'avatarValue': avatarValue,
        'voiceStyle': voiceStyle,
        'modelProviderId': modelProviderId,
        'modelId': modelId,
        'temperature': temperature,
        'maxOutputTokens': maxOutputTokens,
        'sortOrder': sortOrder,
        'enabled': enabled ? 1 : 0,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

class StoryMessageModel {
  int? id;
  int roomId;
  int? speakerId;
  String speakerRole;
  String speakerName;
  String? speakerAvatarType;
  String? speakerAvatarValue;
  String? speakerVoiceStyle;
  String content;
  List<String> imagePaths;
  List<String> filePaths;
  String attachmentContext;
  int createdAt;
  int updatedAt;

  StoryMessageModel({
    this.id,
    required this.roomId,
    this.speakerId,
    required this.speakerRole,
    required this.speakerName,
    this.speakerAvatarType,
    this.speakerAvatarValue,
    this.speakerVoiceStyle,
    required this.content,
    this.imagePaths = const [],
    this.filePaths = const [],
    this.attachmentContext = '',
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt =
            updatedAt ?? createdAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isUser => speakerRole == 'user';

  factory StoryMessageModel.fromJson(Map<String, dynamic> json) =>
      StoryMessageModel(
        id: json['id'] as int?,
        roomId: json['roomId'] as int? ?? 0,
        speakerId: json['speakerId'] as int?,
        speakerRole: json['speakerRole'] as String? ?? 'user',
        speakerName: json['speakerName'] as String? ?? '',
        speakerAvatarType: json['speakerAvatarType'] as String?,
        speakerAvatarValue: json['speakerAvatarValue'] as String?,
        speakerVoiceStyle: json['speakerVoiceStyle'] as String?,
        content: json['content'] as String? ?? '',
        imagePaths: _decodePaths(json['imagePaths']),
        filePaths: _decodePaths(json['filePaths']),
        attachmentContext: json['attachmentContext'] as String? ?? '',
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int? ?? json['createdAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'speakerId': speakerId,
        'speakerRole': speakerRole,
        'speakerName': speakerName,
        'speakerAvatarType': speakerAvatarType,
        'speakerAvatarValue': speakerAvatarValue,
        'speakerVoiceStyle': speakerVoiceStyle,
        'content': content,
        'imagePaths': jsonEncode(imagePaths),
        'filePaths': jsonEncode(filePaths),
        'attachmentContext': attachmentContext,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static List<String> _decodePaths(Object? raw) {
    if (raw is List) {
      return [
        for (final item in raw)
          if (item is String && item.isNotEmpty) item
      ];
    }
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is String && item.isNotEmpty) item
      ];
    } catch (_) {
      return const [];
    }
  }
}
