import 'dart:convert';

import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 助手（阶段七）。对应源项目 `src/types/assistant.ts` 的 Assistant 精简版：
/// 「系统提示词 + 可选模型覆盖 + 工具开关」三件套，会话通过
/// `ConversationModel.assistantId` 绑定一个助手。
class AssistantModel {
  /// 数据库自增 id（未落库时为 null）。
  int? id;

  /// 助手名称（必填）。
  String name;

  /// 头像 emoji（如 '🤖'），列表与气泡处展示用。
  String emoji;

  /// 系统提示词。发请求时作为 `{'role':'system'}` 插在 history 头部
  /// （见 [CompletionDao.injectSystemPrompt]）；空串 = 不注入。
  String prompt;

  /// 可选模型覆盖（modelId）。空串 = 跟随全局 AI 设置；非空时覆盖
  /// 当前生效路径上的模型（见 [applyTo]），能力位随之重算。
  String model;

  /// 是否允许工具调用（阶段六 ToolLoopRunner 路径）的**总开关**。关闭后一律无
  /// 工具，联网搜索回落阶段五意图编排，与「模型不支持工具」同一条路。
  bool useTools;

  /// 助手绑定的工具 id 列表（L1）。`null` = 旧数据 / 未绑定：不主动暴露任何工具，
  /// 联网搜索仍只由会话页联网开关驱动（`ToolRegistry.fromAssistant` 的 forceWebSearch）。
  /// 显式包含某工具 id（如 `'web_search'`）时，该助手始终把它暴露给模型。
  /// 持久化为 `tb_assistant.tools`（JSON 文本列）。
  List<String>? toolIds;

  int createdAt;
  int updatedAt;

  AssistantModel({
    this.id,
    required this.name,
    this.emoji = '🤖',
    this.prompt = '',
    this.model = '',
    this.useTools = true,
    this.toolIds,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  /// sqflite 行 -> Model（useTools 以 integer 0/1 存储）。
  factory AssistantModel.fromJson(Map<String, dynamic> json) => AssistantModel(
        id: json['id'] as int?,
        name: json['name'] as String? ?? '',
        emoji: json['emoji'] as String? ?? '🤖',
        prompt: json['prompt'] as String? ?? '',
        model: json['model'] as String? ?? '',
        useTools: (json['useTools'] as int? ?? 1) != 0,
        toolIds: _decodeToolIds(json['tools']),
        createdAt: json['createdAt'] as int? ?? 0,
        updatedAt: json['updatedAt'] as int? ?? 0,
      );

  /// `tools` 列：JSON 数组文本 -> List<String>。null/空/解析失败 -> null（视为未绑定）。
  static List<String>? _decodeToolIds(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [for (final e in decoded) if (e is String) e];
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'prompt': prompt,
        'model': model,
        'useTools': useTools ? 1 : 0,
        // null 保持 null（旧语义）；非 null（含空列表）编码为 JSON 文本。
        'tools': toolIds == null ? null : jsonEncode(toolIds),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  /// 把模型覆盖应用到设置上：返回 clone 后的新 [AISettings]，当前生效
  /// 路径（后端模式 -> backendModel，本地模式 -> 所选服务商的 model）
  /// 被替换为 [model]。无覆盖时原样返回。
  ///
  /// 注意：本地模式下只换模型名、不切服务商 —— 覆盖的模型应与当前
  /// 服务商兼容（编辑页的下拉清单按当前设置给选项即为此意）。
  /// `ChatService.capabilitiesFor(applyTo(s))` 即得到覆盖后的能力位
  /// （effectiveModel 的派生路径见 [AISettings.effectiveModel]）。
  AISettings applyTo(AISettings s) {
    final m = model.trim();
    if (m.isEmpty) return s;
    final next = s.clone();
    if (next.mode == AIMode.backend) {
      next.backendModel = m;
    } else {
      next.setActiveModel(m);
    }
    return next;
  }
}
