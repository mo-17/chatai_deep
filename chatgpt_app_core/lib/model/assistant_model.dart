import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_example_dialogs.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/world_book.dart';

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

  /// 助手头像类型：null/空 = 使用 emoji；image = 本地托管图片。
  String? avatarType;

  /// 助手头像值：image 时为本地文件路径。
  String? avatarValue;

  /// 系统提示词。发请求时作为 `{'role':'system'}` 插在 history 头部
  /// （见 [CompletionDao.injectSystemPrompt]）；空串 = 不注入。
  String prompt;

  /// 角色简介：展示给用户看的短描述，不进入 system prompt。
  String description;

  /// 角色开场白：新会话进入后用于展示/预填的欢迎语。
  String openingMessage;

  /// 示例对话：帮助用户理解角色说话方式，首版以纯文本保存。
  String exampleDialogs;

  /// 关键词记忆 / 轻量世界书：每行 `关键词1,关键词2 => 设定内容`。
  /// 发送时只把命中的条目注入 system prompt，避免长期上下文膨胀。
  String memoryBook;

  /// 结构化世界书 JSON。用于无损保存 Tavern 的高级触发条件和运行时字段；
  /// [memoryBook] 继续作为旧版兼容与人工编辑表示，空串表示仅使用旧格式。
  String worldBookJson;

  /// CHARX/V3 内嵌资源的本地托管清单（JSON）。仅保存文件引用，不执行资源。
  String roleCardAssets;

  /// 默认朗读声音：空串 = 跟随会话/系统设置；可为内置 TTS 风格或 custom_sherpa:<id>。
  String defaultVoiceStyle;

  /// 仅用于本地模式：可选覆盖服务商 id；空串 = 跟随全局服务商。
  /// 为空或服务商不存在/禁用时回落到全局服务商。
  String providerId;

  /// 可选模型覆盖（modelId）。空串 = 跟随全局 AI 设置；非空时覆盖
  /// 当前生效路径上的模型（见 [applyTo]），能力位随之重算。
  String model;

  /// 独立的后端覆盖；NULL legacy，不改本地模型引用。
  BackendSelection? backendSelection;

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
    this.avatarType,
    this.avatarValue,
    this.prompt = '',
    this.description = '',
    this.openingMessage = '',
    this.exampleDialogs = '',
    this.memoryBook = '',
    this.worldBookJson = '',
    this.roleCardAssets = '',
    this.defaultVoiceStyle = '',
    this.providerId = '',
    this.model = '',
    this.backendSelection,
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
        avatarType: json['avatarType'] as String?,
        avatarValue: json['avatarValue'] as String?,
        prompt: json['prompt'] as String? ?? '',
        description: json['description'] as String? ?? '',
        openingMessage: json['openingMessage'] as String? ?? '',
        exampleDialogs: json['exampleDialogs'] as String? ?? '',
        memoryBook: json['memoryBook'] as String? ?? '',
        worldBookJson: json['worldBookJson'] as String? ?? '',
        roleCardAssets: json['roleCardAssets'] as String? ?? '',
        defaultVoiceStyle: json['defaultVoiceStyle'] as String? ?? '',
        providerId: json['providerId'] as String? ?? '',
        model: json['model'] as String? ?? '',
        backendSelection:
            BackendSelection.fromStorage(json['backendSelection']),
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
      return [
        for (final e in decoded)
          if (e is String) e
      ];
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'avatarType': avatarType,
        'avatarValue': avatarValue,
        'prompt': prompt,
        'description': description,
        'openingMessage': openingMessage,
        'exampleDialogs': exampleDialogs,
        'memoryBook': memoryBook,
        'worldBookJson': worldBookJson,
        'roleCardAssets': roleCardAssets,
        'defaultVoiceStyle': defaultVoiceStyle,
        'providerId': providerId,
        'model': model,
        'backendSelection': backendSelection?.toSqlValue(),
        'useTools': useTools ? 1 : 0,
        // null 保持 null（旧语义）；非 null（含空列表）编码为 JSON 文本。
        'tools': toolIds == null ? null : jsonEncode(toolIds),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  /// 把模型覆盖应用到设置上：返回 clone 后的新 [AISettings]，当前生效
  /// 路径（后端模式 -> backendModel，本地模式 -> 所选服务商的 model）
  /// 被替换为 [model]。无覆盖且无 providerId 时原样返回。
  ///
  /// 注意：本地模式支持 providerId + model 的联合覆盖；无 providerId 时沿用全局
  /// 生效服务商。覆盖的模型应与目标服务商兼容（编辑页按该服务商下模型清单约束）。
  /// `ChatService.capabilitiesFor(applyTo(s))` 即得到覆盖后的能力位
  /// （effectiveModel 的派生路径见 [AISettings.effectiveModel]）。
  AISettings applyTo(AISettings s) {
    final pid = providerId;
    final m = model;
    if (pid.isEmpty && m.isEmpty) return s;

    final next = s.clone();
    if (next.mode == AIMode.backend) {
      if (m.isEmpty) return next;
      next.backendModel = m;
      return next;
    }

    if (pid.isNotEmpty) {
      next.activeProviderId = pid;
    }
    if (m.isNotEmpty) {
      next.setLocalModelOverride(m);
    }
    return next;
  }

  /// 当前轮请求使用的 system prompt：基础人设 + 按用户输入命中的世界书条目。
  String systemPromptFor(String userText) {
    final base = prompt.trim();
    final examples = _exampleDialogContext();
    final memory = AssistantMemoryBook.buildContext(
      memoryBook,
      userText,
      structuredJson: worldBookJson,
      characterName: name,
      characterDescription: _promptSection('角色设定'),
      characterPersonality: _promptSection('性格'),
      characterDepthPrompt: _promptSection('系统提示'),
      scenario: _promptSection('场景'),
      creatorNotes: description,
    );
    final parts = [
      if (base.isNotEmpty) base,
      if (examples.isNotEmpty) examples,
      if (memory.isNotEmpty) memory,
    ];
    return parts.join('\n\n');
  }

  /// 实际生成路径使用的异步版本：world-book regex 只在可终止 isolate 中匹配。
  Future<String> systemPromptForSafely(String userText) async {
    final base = prompt.trim();
    final examples = _exampleDialogContext();
    final memory = await AssistantMemoryBook.buildContextSafely(
      memoryBook,
      userText,
      structuredJson: worldBookJson,
      characterName: name,
      characterDescription: _promptSection('角色设定'),
      characterPersonality: _promptSection('性格'),
      characterDepthPrompt: _promptSection('系统提示'),
      scenario: _promptSection('场景'),
      creatorNotes: description,
    );
    return [
      if (base.isNotEmpty) base,
      if (examples.isNotEmpty) examples,
      if (memory.isNotEmpty) memory,
    ].join('\n\n');
  }

  String _exampleDialogContext() {
    final examples = AssistantExampleDialogs.promptText(exampleDialogs);
    if (examples.isEmpty) return '';
    return '[示例对话]\n$examples';
  }

  String _promptSection(String title) {
    final marker = '[$title]';
    final start = prompt.indexOf(marker);
    if (start < 0) return '';
    final bodyStart = start + marker.length;
    final next = RegExp(r'\n\[(系统提示|角色设定|性格|场景|后续指令)\]')
        .firstMatch(prompt.substring(bodyStart));
    final end = next == null ? prompt.length : bodyStart + next.start;
    return prompt.substring(bodyStart, end).trim();
  }
}

class AssistantMemoryBook {
  static const int defaultMaxContextChars = 2400;

  static String buildContext(
    String raw,
    String userText, {
    int maxEntries = 6,
    int maxContextChars = defaultMaxContextChars,
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) {
    final budget = budgetContext(
      raw,
      userText,
      maxEntries: maxEntries,
      maxContextChars: maxContextChars,
      structuredJson: structuredJson,
      characterName: characterName,
      personaDescription: personaDescription,
      characterDescription: characterDescription,
      characterPersonality: characterPersonality,
      characterDepthPrompt: characterDepthPrompt,
      scenario: scenario,
      creatorNotes: creatorNotes,
    );
    return budget.context;
  }

  static Future<String> buildContextSafely(
    String raw,
    String userText, {
    int maxEntries = 6,
    int maxContextChars = defaultMaxContextChars,
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) async =>
      (await budgetContextSafely(
        raw,
        userText,
        maxEntries: maxEntries,
        maxContextChars: maxContextChars,
        structuredJson: structuredJson,
        characterName: characterName,
        personaDescription: personaDescription,
        characterDescription: characterDescription,
        characterPersonality: characterPersonality,
        characterDepthPrompt: characterDepthPrompt,
        scenario: scenario,
        creatorNotes: creatorNotes,
      ))
          .context;

  static Future<AssistantMemoryContextBudget> budgetContextSafely(
    String raw,
    String userText, {
    int maxEntries = 6,
    int maxContextChars = defaultMaxContextChars,
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) async {
    final entries = await matchSafely(
      raw,
      userText,
      maxEntries: maxEntries,
      structuredJson: structuredJson,
      characterName: characterName,
      personaDescription: personaDescription,
      characterDescription: characterDescription,
      characterPersonality: characterPersonality,
      characterDepthPrompt: characterDepthPrompt,
      scenario: scenario,
      creatorNotes: creatorNotes,
    );
    if (entries.isEmpty) {
      return AssistantMemoryContextBudget.empty(
        maxContextChars: maxContextChars,
      );
    }
    final lines = _budgetedLines(entries, maxContextChars: maxContextChars);
    final context = lines.isEmpty ? '' : '[当前命中的角色记忆]\n${lines.join('\n')}';
    return AssistantMemoryContextBudget(
      context: context,
      matchedCount: entries.length,
      includedCount: lines.length,
      skippedCount: entries.length - lines.length,
      truncated: lines.any((line) => line.endsWith('...')),
      maxContextChars: maxContextChars,
      usedChars: context.length,
    );
  }

  static AssistantMemoryContextBudget budgetContext(
    String raw,
    String userText, {
    int maxEntries = 6,
    int maxContextChars = defaultMaxContextChars,
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) {
    final entries = match(
      raw,
      userText,
      maxEntries: maxEntries,
      structuredJson: structuredJson,
      characterName: characterName,
      personaDescription: personaDescription,
      characterDescription: characterDescription,
      characterPersonality: characterPersonality,
      characterDepthPrompt: characterDepthPrompt,
      scenario: scenario,
      creatorNotes: creatorNotes,
    );
    if (entries.isEmpty) {
      return AssistantMemoryContextBudget.empty(
        maxContextChars: maxContextChars,
      );
    }
    final lines = _budgetedLines(entries, maxContextChars: maxContextChars);
    final context = lines.isEmpty ? '' : '[当前命中的角色记忆]\n${lines.join('\n')}';
    return AssistantMemoryContextBudget(
      context: context,
      matchedCount: entries.length,
      includedCount: lines.length,
      skippedCount: entries.length - lines.length,
      truncated: lines.any((line) => line.endsWith('...')),
      maxContextChars: maxContextChars,
      usedChars: context.length,
    );
  }

  static List<String> match(
    String raw,
    String userText, {
    int maxEntries = 6,
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) =>
      WorldBookMatcher.match(
        WorldBookCodec.decode(
          structuredJson: structuredJson,
          legacyText: raw,
        ),
        WorldBookMatchContext(
          input: userText,
          characterName: characterName,
          personaDescription: personaDescription,
          characterDescription: characterDescription,
          characterPersonality: characterPersonality,
          characterDepthPrompt: characterDepthPrompt,
          scenario: scenario,
          creatorNotes: creatorNotes,
        ),
        maxEntries: maxEntries.clamp(1, 50),
      ).entries.map((entry) => entry.content).toList();

  static Future<List<String>> matchSafely(
    String raw,
    String userText, {
    int maxEntries = 6,
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) async =>
      (await WorldBookMatcher.matchSafely(
        WorldBookCodec.decode(
          structuredJson: structuredJson,
          legacyText: raw,
        ),
        WorldBookMatchContext(
          input: userText,
          characterName: characterName,
          personaDescription: personaDescription,
          characterDescription: characterDescription,
          characterPersonality: characterPersonality,
          characterDepthPrompt: characterDepthPrompt,
          scenario: scenario,
          creatorNotes: creatorNotes,
        ),
        maxEntries: maxEntries.clamp(1, 50),
      ))
          .entries
          .map((entry) => entry.content)
          .toList();

  static List<String> _budgetedLines(
    List<String> entries, {
    required int maxContextChars,
  }) {
    const headerBudget = '[当前命中的角色记忆]\n'.length;
    final limit = (maxContextChars - headerBudget).clamp(0, 20000);
    if (limit <= 0) return const [];
    final lines = <String>[];
    var used = 0;
    for (final entry in entries) {
      final content = entry.trim();
      if (content.isEmpty) continue;
      final separator = lines.isEmpty ? 0 : 1;
      final remaining = limit - used - separator;
      if (remaining <= 0) break;
      var line = '- $content';
      if (line.length > remaining) {
        line = _truncateLine(line, remaining);
      }
      if (line.isEmpty) break;
      lines.add(line);
      used += separator + line.length;
      if (line.length >= remaining) break;
    }
    return lines;
  }

  static String _truncateLine(String line, int maxChars) {
    if (maxChars <= 0) return '';
    if (line.length <= maxChars) return line;
    if (maxChars <= 3) return line.substring(0, maxChars);
    return '${line.substring(0, maxChars - 3).trimRight()}...';
  }

  // ignore: unused_element
  static _MemoryEntry? _parseLine(String line, int order) {
    final parsed = _parseMeta(line);
    final body = parsed.body;
    final idx = body.indexOf('=>');
    if (idx < 0) {
      return _MemoryEntry(
        alwaysOn: true,
        keywords: const [],
        content: body,
        enabled: parsed.enabled,
        priority: parsed.priority,
        secondaryKeywords: parsed.secondaryKeywords,
        caseSensitive: parsed.caseSensitive,
        wholeWords: parsed.wholeWords,
        order: order,
      );
    }
    final keywordPart = body.substring(0, idx).trim();
    final content = body.substring(idx + 2).trim();
    final keywords = _splitKeywords(
      keywordPart,
      regex: parsed.regex,
      caseSensitive: parsed.caseSensitive,
    );
    if (keywords.isEmpty || content.isEmpty) return null;
    return _MemoryEntry(
      alwaysOn: false,
      keywords: keywords,
      content: content,
      enabled: parsed.enabled,
      priority: parsed.priority,
      regex: parsed.regex,
      secondaryKeywords: parsed.secondaryKeywords,
      caseSensitive: parsed.caseSensitive,
      wholeWords: parsed.wholeWords,
      order: order,
    );
  }

  static List<String> _splitKeywords(
    String raw, {
    required bool regex,
    bool caseSensitive = false,
  }) {
    final normalized = raw.trim();
    if (normalized.isEmpty) return const [];
    final splitter = regex ? RegExp(r'\s*\|\|\s*') : RegExp(r'[,，、|/ ]+');
    return normalized
        .split(splitter)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) => regex || caseSensitive ? e : e.toLowerCase())
        .toList();
  }

  static _MemoryLineMeta _parseMeta(String line) {
    var rest = line.trim();
    var enabled = true;
    var priority = 0;
    var regex = false;
    var secondaryKeywords = const <String>[];
    var caseSensitive = false;
    var wholeWords = false;
    var changed = true;
    while (changed && rest.startsWith('[')) {
      changed = false;
      final end = rest.indexOf(']');
      if (end <= 0) break;
      final rawTag = rest.substring(1, end).trim();
      final tag = rawTag.toLowerCase();
      if (tag == 'off' || tag == 'disabled') {
        enabled = false;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'on' || tag == 'enabled') {
        enabled = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('p=')) {
        priority = int.tryParse(tag.substring(2).trim()) ?? priority;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 're' || tag == 'regex') {
        regex = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'cs' || tag == 'case') {
        caseSensitive = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'ww' || tag == 'whole') {
        wholeWords = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('sec=') || tag.startsWith('secondary=')) {
        final rawValue = rawTag.substring(rawTag.indexOf('=') + 1);
        secondaryKeywords = _splitKeywords(
          rawValue,
          regex: regex,
          caseSensitive: caseSensitive,
        );
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      }
    }
    return _MemoryLineMeta(
      body: rest,
      enabled: enabled,
      priority: priority,
      regex: regex,
      secondaryKeywords: secondaryKeywords,
      caseSensitive: caseSensitive,
      wholeWords: wholeWords,
    );
  }
}

class _MemoryEntry {
  final bool alwaysOn;
  final List<String> keywords;
  final String content;
  final bool enabled;
  final int priority;
  final bool regex;
  final List<String> secondaryKeywords;
  final bool caseSensitive;
  final bool wholeWords;
  final int order;

  const _MemoryEntry({
    required this.alwaysOn,
    required this.keywords,
    required this.content,
    required this.enabled,
    required this.priority,
    this.regex = false,
    this.secondaryKeywords = const [],
    this.caseSensitive = false,
    this.wholeWords = false,
    required this.order,
  });

  bool matches(String userText, String lowerUserText) {
    if (!_keywordsMatch(keywords, userText, lowerUserText)) return false;
    if (secondaryKeywords.isEmpty) return true;
    return _keywordsMatch(secondaryKeywords, userText, lowerUserText);
  }

  bool _keywordsMatch(
    List<String> candidates,
    String userText,
    String lowerUserText,
  ) {
    if (!regex) {
      return candidates.any((keyword) => _plainKeywordHit(
            keyword,
            userText,
            lowerUserText,
          ));
    }
    // 旧同步 parser 保留仅为格式兼容；不可在主 isolate 执行
    // 导入的 regex。实际运行路径统一走 WorldBookMatcher.matchSafely。
    return false;
  }

  bool _plainKeywordHit(
    String keyword,
    String userText,
    String lowerUserText,
  ) {
    if (!wholeWords) {
      return caseSensitive
          ? userText.contains(keyword)
          : lowerUserText.contains(keyword);
    }
    final source = _wholeWordPattern(RegExp.escape(keyword));
    return RegExp(source, caseSensitive: caseSensitive).hasMatch(userText);
  }

  String _wholeWordPattern(String source) =>
      '(^|[^A-Za-z0-9_])(?:$source)([^A-Za-z0-9_]|\$)';
}

class _MemoryLineMeta {
  final String body;
  final bool enabled;
  final int priority;
  final bool regex;
  final List<String> secondaryKeywords;
  final bool caseSensitive;
  final bool wholeWords;

  const _MemoryLineMeta({
    required this.body,
    required this.enabled,
    required this.priority,
    this.regex = false,
    this.secondaryKeywords = const [],
    this.caseSensitive = false,
    this.wholeWords = false,
  });
}

class AssistantMemoryContextBudget {
  final String context;
  final int matchedCount;
  final int includedCount;
  final int skippedCount;
  final bool truncated;
  final int maxContextChars;
  final int usedChars;

  const AssistantMemoryContextBudget({
    required this.context,
    required this.matchedCount,
    required this.includedCount,
    required this.skippedCount,
    required this.truncated,
    required this.maxContextChars,
    required this.usedChars,
  });

  const AssistantMemoryContextBudget.empty({
    required this.maxContextChars,
  })  : context = '',
        matchedCount = 0,
        includedCount = 0,
        skippedCount = 0,
        truncated = false,
        usedChars = 0;

  factory AssistantMemoryContextBudget.fromJson(Map<String, dynamic> json) {
    return AssistantMemoryContextBudget(
      context: json['context'] as String? ?? '',
      matchedCount: json['matchedCount'] as int? ?? 0,
      includedCount: json['includedCount'] as int? ?? 0,
      skippedCount: json['skippedCount'] as int? ?? 0,
      truncated: json['truncated'] as bool? ?? false,
      maxContextChars: json['maxContextChars'] as int? ??
          AssistantMemoryBook.defaultMaxContextChars,
      usedChars: json['usedChars'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'context': context,
        'matchedCount': matchedCount,
        'includedCount': includedCount,
        'skippedCount': skippedCount,
        'truncated': truncated,
        'maxContextChars': maxContextChars,
        'usedChars': usedChars,
      };

  bool get affected => truncated || skippedCount > 0;

  String get compactSummary {
    final parts = <String>[
      '注入 $includedCount/$matchedCount 条',
      if (truncated) '有截断',
      if (skippedCount > 0) '跳过 $skippedCount 条',
    ];
    return parts.join('，');
  }
}
