import 'dart:convert';
import 'dart:math';

class StoryRoomModel {
  int? id;
  String title;
  String mode;
  String replyMode;
  int maxAutoReplies;
  String speakerStrategy;
  bool avoidRepeatSpeaker;
  int maxAutoTotalTokens;
  String publicContext;
  String worldBookState;
  String promptConfigJson;
  String quickRepliesJson;
  String regexScriptsJson;

  /// 经安全清洗后的 Tavern Context/Instruct/Sampler/OpenAI 预设包。
  /// 仅用于预览、受控参数映射和往返导出，不直接执行第三方模板。
  String tavernPresetJson;
  String? personaKey;
  String? modelProviderId;
  String? modelId;
  double? temperature;
  int? maxOutputTokens;
  String? activeMessageKey;

  /// Tavern JSONL 的首行快照（含 chat_metadata 和未知 header 字段）。
  String tavernChatMetadataJson;
  int createdAt;
  int updatedAt;

  StoryRoomModel({
    this.id,
    required this.title,
    this.mode = StoryRoomMode.creation,
    String? replyMode,
    this.maxAutoReplies = 1,
    String? speakerStrategy,
    this.avoidRepeatSpeaker = true,
    int maxAutoTotalTokens =
        StoryRoomSchedulingLimits.defaultMaxAutoTotalTokens,
    this.publicContext = '',
    this.worldBookState = '',
    this.promptConfigJson = '',
    this.quickRepliesJson = '',
    this.regexScriptsJson = '',
    this.tavernPresetJson = '',
    this.personaKey,
    this.modelProviderId,
    this.modelId,
    this.temperature,
    this.maxOutputTokens,
    this.activeMessageKey,
    this.tavernChatMetadataJson = '',
    int? createdAt,
    int? updatedAt,
  })  : replyMode = StoryReplyMode.normalize(replyMode),
        speakerStrategy = StorySpeakerStrategy.normalize(speakerStrategy),
        maxAutoTotalTokens =
            StoryRoomSchedulingLimits.normalizeMaxAutoTotalTokens(
                maxAutoTotalTokens),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryRoomModel.fromJson(Map<String, dynamic> json) => StoryRoomModel(
        id: json['id'] as int?,
        title: json['title'] as String? ?? '未命名创作房间',
        mode: StoryRoomMode.normalize(json['mode'] as String?),
        replyMode: StoryReplyMode.normalize(json['replyMode'] as String?),
        maxAutoReplies: _safeMaxAutoReplies(json['maxAutoReplies']),
        speakerStrategy:
            StorySpeakerStrategy.normalize(json['speakerStrategy'] as String?),
        avoidRepeatSpeaker:
            _safeBool(json['avoidRepeatSpeaker'], fallback: true),
        maxAutoTotalTokens:
            StoryRoomSchedulingLimits.normalizeMaxAutoTotalTokens(
          json['maxAutoTotalTokens'],
        ),
        publicContext: json['publicContext'] as String? ?? '',
        worldBookState: json['worldBookState'] as String? ?? '',
        promptConfigJson: json['promptConfigJson'] as String? ?? '',
        quickRepliesJson: json['quickRepliesJson'] as String? ?? '',
        regexScriptsJson: json['regexScriptsJson'] as String? ?? '',
        tavernPresetJson: json['tavernPresetJson'] as String? ?? '',
        personaKey: json['personaKey'] as String?,
        modelProviderId: json['modelProviderId'] as String?,
        modelId: json['modelId'] as String?,
        temperature: (json['temperature'] as num?)?.toDouble(),
        maxOutputTokens: (json['maxOutputTokens'] as num?)?.toInt(),
        activeMessageKey: json['activeMessageKey'] as String?,
        tavernChatMetadataJson: json['tavernChatMetadataJson'] as String? ?? '',
        createdAt: json['createdAt'] as int?,
        updatedAt: json['updatedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'mode': mode,
        'replyMode': replyMode,
        'maxAutoReplies': maxAutoReplies.clamp(1, 3),
        'speakerStrategy': StorySpeakerStrategy.normalize(speakerStrategy),
        'avoidRepeatSpeaker': avoidRepeatSpeaker ? 1 : 0,
        'maxAutoTotalTokens':
            StoryRoomSchedulingLimits.normalizeMaxAutoTotalTokens(
                maxAutoTotalTokens),
        'publicContext': publicContext,
        'worldBookState': worldBookState,
        'promptConfigJson': promptConfigJson,
        'quickRepliesJson': quickRepliesJson,
        'regexScriptsJson': regexScriptsJson,
        'tavernPresetJson': tavernPresetJson,
        'personaKey': personaKey,
        'modelProviderId': modelProviderId,
        'modelId': modelId,
        'temperature': temperature,
        'maxOutputTokens': maxOutputTokens,
        'activeMessageKey': activeMessageKey,
        'tavernChatMetadataJson': tavernChatMetadataJson,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  /// 房间级设置较多，重命名等局部更新必须从完整快照复制，避免遗漏新增字段。
  StoryRoomModel copyWith({String? title}) => StoryRoomModel.fromJson({
        ...toJson(),
        if (title != null) 'title': title,
      });

  static int _safeMaxAutoReplies(Object? value) {
    final number = value is num ? value.toInt() : int.tryParse('$value');
    return (number ?? 1).clamp(1, 3);
  }

  static bool _safeBool(Object? value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    switch ('$value'.trim().toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
      default:
        return fallback;
    }
  }
}

class StorySpeakerStrategy {
  const StorySpeakerStrategy._();

  static const smart = 'smart';
  static const roundRobin = 'roundRobin';

  static String normalize(String? strategy) {
    switch (strategy) {
      case roundRobin:
        return roundRobin;
      case smart:
      default:
        return smart;
    }
  }
}

class StoryRoomSchedulingLimits {
  const StoryRoomSchedulingLimits._();

  static const defaultMaxAutoTotalTokens = 4096;
  static const minMaxAutoTotalTokens = 256;
  static const maxMaxAutoTotalTokens = 32768;

  static int normalizeMaxAutoTotalTokens(Object? value) {
    final number = value is num ? value.toInt() : int.tryParse('$value');
    return (number ?? defaultMaxAutoTotalTokens)
        .clamp(minMaxAutoTotalTokens, maxMaxAutoTotalTokens);
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
  String participantKey;
  String stateSummary;
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
    String? participantKey,
    this.stateSummary = '',
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
  })  : participantKey = participantKey?.trim().isNotEmpty == true
            ? participantKey!.trim()
            : newParticipantKey(),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryParticipantModel.fromJson(Map<String, dynamic> json) =>
      StoryParticipantModel(
        id: json['id'] as int?,
        roomId: json['roomId'] as int? ?? 0,
        participantKey: json['participantKey'] as String?,
        stateSummary: json['stateSummary'] as String? ?? '',
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
        'participantKey': participantKey,
        'stateSummary': stateSummary,
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

  static String newParticipantKey() {
    final random = Random.secure();
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final entropy =
        List.generate(3, (_) => random.nextInt(1 << 32).toRadixString(36))
            .join();
    return 'participant-$timestamp-$entropy';
  }
}

class StoryRoleStateCodec {
  const StoryRoleStateCodec._();

  static Map<String, String> decode(Object? raw) {
    if (raw is Map) return _normalize(raw);
    if (raw is! String || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? _normalize(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  static String encode(Map<String, String> states) =>
      jsonEncode(_normalize(states));

  static Map<String, String> _normalize(Map<dynamic, dynamic> states) {
    final normalized = <String, String>{};
    for (final entry in states.entries) {
      final key = entry.key is String ? (entry.key as String).trim() : '';
      final value = entry.value is String ? (entry.value as String).trim() : '';
      if (key.isNotEmpty && value.isNotEmpty) normalized[key] = value;
    }
    return normalized;
  }
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
  String? speakerPersonaKey;
  String content;
  List<String> imagePaths;
  List<String> imageSources;
  List<String> citationUrls;
  List<String> filePaths;
  String attachmentContext;
  String nodeKey;
  String? parentNodeKey;
  String? candidateGroupKey;
  String contextStateAfter;
  String roleStatesAfter;

  /// Tavern 消息 extra 的受限 JSON 快照，用于 round-trip。
  String tavernExtraJson;

  /// Tavern 消息 swipe_info 的受限 JSON 快照，用于 round-trip。
  String tavernSwipeInfoJson;
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
    this.speakerPersonaKey,
    required this.content,
    this.imagePaths = const [],
    this.imageSources = const [],
    this.citationUrls = const [],
    this.filePaths = const [],
    this.attachmentContext = '',
    String? nodeKey,
    this.parentNodeKey,
    this.candidateGroupKey,
    this.contextStateAfter = '',
    this.roleStatesAfter = '',
    this.tavernExtraJson = '',
    this.tavernSwipeInfoJson = '',
    int? createdAt,
    int? updatedAt,
  })  : nodeKey =
            nodeKey?.trim().isNotEmpty == true ? nodeKey!.trim() : newNodeKey(),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
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
        speakerPersonaKey: json['speakerPersonaKey'] as String?,
        content: json['content'] as String? ?? '',
        imagePaths: _decodePaths(json['imagePaths']),
        imageSources: _decodePaths(json['imageSources']),
        citationUrls: _decodePaths(json['citationUrls']),
        filePaths: _decodePaths(json['filePaths']),
        attachmentContext: json['attachmentContext'] as String? ?? '',
        nodeKey: json['nodeKey'] as String?,
        parentNodeKey: json['parentNodeKey'] as String?,
        candidateGroupKey: json['candidateGroupKey'] as String?,
        contextStateAfter: json['contextStateAfter'] as String? ?? '',
        roleStatesAfter: json['roleStatesAfter'] as String? ?? '',
        tavernExtraJson: json['tavernExtraJson'] as String? ?? '',
        tavernSwipeInfoJson: json['tavernSwipeInfoJson'] as String? ?? '',
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
        'speakerPersonaKey': speakerPersonaKey,
        'content': content,
        'imagePaths': jsonEncode(imagePaths),
        'imageSources': jsonEncode(imageSources),
        'citationUrls': jsonEncode(citationUrls),
        'filePaths': jsonEncode(filePaths),
        'attachmentContext': attachmentContext,
        'nodeKey': nodeKey,
        'parentNodeKey': parentNodeKey,
        'candidateGroupKey': candidateGroupKey,
        'contextStateAfter': contextStateAfter,
        'roleStatesAfter': roleStatesAfter,
        'tavernExtraJson': tavernExtraJson,
        'tavernSwipeInfoJson': tavernSwipeInfoJson,
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

  static String newNodeKey() {
    final random = Random.secure();
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final entropy =
        List.generate(3, (_) => random.nextInt(1 << 32).toRadixString(36))
            .join();
    return 'node-$timestamp-$entropy';
  }
}
