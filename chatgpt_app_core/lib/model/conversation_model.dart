import 'dart:convert';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';

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

  ///会话级 DeepSeek 思考强度。null = 跟随服务端默认，兼容旧会话。
  DeepSeekReasoningEffort? deepSeekReasoningEffort;

  ///会话级工具集覆盖。null = 跟随助手绑定；空列表 = 不暴露绑定工具。
  List<String>? toolIds;

  ///会话级语音输入开关。null = 跟随默认（显示语音入口）。
  bool? speechInputEnabled;

  ///会话级朗读开关。
  bool? readAloudEnabled;

  ///会话级语音识别 localeId，例如 zh_CN / en_US。null = 跟随系统。
  String? voiceLocale;

  ///会话级朗读速率。
  double? voiceRate;

  ///会话级 TTS 语音风格，例如 system / female / male / bright / deep。
  String? voiceStyle;

  ///会话级朗读入口：button / longPress / hidden。null = 默认 button。
  String? readAloudTriggerMode;

  ///会话级角色当前场景。只影响当前会话，不写回全局角色卡。
  String? roleScene;

  ///会话级角色关系备注，例如熟悉度、称呼、互动边界。
  String? roleRelationship;

  ///会话级角色语气/演绎备注。
  String? roleToneNote;

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
      this.deepSeekReasoningEffort,
      this.toolIds,
      this.speechInputEnabled,
      this.readAloudEnabled,
      this.voiceLocale,
      this.voiceRate,
      this.voiceStyle,
      this.readAloudTriggerMode,
      this.roleScene,
      this.roleRelationship,
      this.roleToneNote});

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
          deepSeekReasoningEffort:
              DeepSeekReasoningEffort.parse(json['deepSeekReasoningEffort']),
          toolIds: _decodeToolIds(json['toolIds']),
          speechInputEnabled: _boolOf(json['speechInputEnabled']),
          readAloudEnabled: _boolOf(json['readAloudEnabled']),
          voiceLocale: json['voiceLocale'] as String?,
          voiceRate: _doubleOf(json['voiceRate']),
          voiceStyle: json['voiceStyle'] as String?,
          readAloudTriggerMode: json['readAloudTriggerMode'] as String?,
          roleScene: json['roleScene'] as String?,
          roleRelationship: json['roleRelationship'] as String?,
          roleToneNote: json['roleToneNote'] as String?);

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
    data['deepSeekReasoningEffort'] = deepSeekReasoningEffort?.wireValue;
    data['toolIds'] = toolIds == null ? null : jsonEncode(toolIds);
    data['speechInputEnabled'] =
        speechInputEnabled == null ? null : (speechInputEnabled! ? 1 : 0);
    data['readAloudEnabled'] =
        readAloudEnabled == null ? null : (readAloudEnabled! ? 1 : 0);
    data['voiceLocale'] = voiceLocale;
    data['voiceRate'] = voiceRate;
    data['voiceStyle'] = voiceStyle;
    data['readAloudTriggerMode'] = readAloudTriggerMode;
    data['roleScene'] = roleScene;
    data['roleRelationship'] = roleRelationship;
    data['roleToneNote'] = roleToneNote;
    return data;
  }

  /// 当前会话专属的角色状态上下文。用于补充同一角色在不同会话里的
  /// 场景、关系和语气差异，不会写回全局角色卡。
  String roleStateContext() {
    final lines = roleStatePromptLines();
    if (lines.isEmpty) return '';
    return '[当前会话角色状态]\n${lines.join('\n')}';
  }

  List<String> roleStatePromptLines() {
    final preview = roleStatePreviewLines();
    return [
      for (final line in preview)
        if (line.startsWith('场景：'))
          '- 当前$line'
        else if (line.startsWith('关系：'))
          '- 关系备注：${line.substring(3)}'
        else if (line.startsWith('语气：'))
          '- 语气备注：${line.substring(3)}',
    ];
  }

  List<String> roleStatePreviewLines() {
    final scene = _normalizeRoleStateText(roleScene);
    final relationship = _normalizeRoleStateText(roleRelationship);
    final tone = _normalizeRoleStateText(roleToneNote);
    final lines = [
      if (scene.isNotEmpty) '场景：$scene',
      if (relationship.isNotEmpty) '关系：$relationship',
      if (tone.isNotEmpty) '语气：$tone',
    ];
    return lines;
  }

  String roleStateCopyText({String title = '当前会话状态'}) {
    final lines = roleStatePreviewLines();
    if (lines.isEmpty) return '';
    return ['# $title', ...lines].join('\n');
  }

  static String _normalizeRoleStateText(String? value) {
    return value?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
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

  static double? _doubleOf(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
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
