import 'dart:convert';

/// 可识别的 SillyTavern 预设格式。
enum StoryTavernPresetKind {
  context,
  instruct,
  textgenSampler,
  openAi,
}

extension StoryTavernPresetKindWireName on StoryTavernPresetKind {
  String get wireName {
    switch (this) {
      case StoryTavernPresetKind.context:
        return 'context';
      case StoryTavernPresetKind.instruct:
        return 'instruct';
      case StoryTavernPresetKind.textgenSampler:
        return 'textgen_sampler';
      case StoryTavernPresetKind.openAi:
        return 'openai';
    }
  }

  static StoryTavernPresetKind? fromWireName(Object? value) {
    switch (value) {
      case 'context':
        return StoryTavernPresetKind.context;
      case 'instruct':
        return StoryTavernPresetKind.instruct;
      case 'textgen_sampler':
        return StoryTavernPresetKind.textgenSampler;
      case 'openai':
        return StoryTavernPresetKind.openAi;
    }
    return null;
  }
}

/// 可以安全映射到当前 AI 设置的采样值。
///
/// `null` 表示源预设没有提供有效值，调用方不应覆盖当前设置。
class StoryTavernPresetApplyValues {
  final double? temperature;
  final double? topP;
  final int? maxTokens;

  const StoryTavernPresetApplyValues({
    this.temperature,
    this.topP,
    this.maxTokens,
  });

  bool get isEmpty => temperature == null && topP == null && maxTokens == null;

  Map<String, dynamic> toJson() => {
        'temperature': temperature,
        'topP': topP,
        'maxTokens': maxTokens,
      };
}

/// 受限预设解析的结果。预览数据不包含网络凭据、路由信息或可执行字段。
class StoryTavernPresetPreview {
  final StoryTavernPresetKind? kind;
  final String? error;
  final StoryTavernPresetApplyValues applyValues;
  final List<String> warnings;
  final Map<String, dynamic>? _sanitized;
  final Map<String, dynamic>? _openAiPromptData;

  StoryTavernPresetPreview._({
    this.kind,
    this.error,
    this.applyValues = const StoryTavernPresetApplyValues(),
    List<String> warnings = const [],
    Map<String, dynamic>? sanitized,
    Map<String, dynamic>? openAiPromptData,
  })  : warnings = List.unmodifiable(warnings),
        _sanitized = sanitized == null ? null : _copyMap(sanitized),
        _openAiPromptData =
            openAiPromptData == null ? null : _copyMap(openAiPromptData);

  bool get isAccepted => kind != null && _sanitized != null;

  /// 清洗后的原始预设。每次读取都会返回副本，避免调用方污染预览结果。
  Map<String, dynamic>? get sanitized =>
      _sanitized == null ? null : _copyMap(_sanitized!);

  /// [sanitized] 的别名，方便导入 UI 直接消费。
  Map<String, dynamic>? get sanitizedMap => sanitized;

  /// 可记录、展示或导出的紧凑安全 JSON。
  String? get sanitizedJson =>
      _sanitized == null ? null : jsonEncode(_sanitized);

  /// OpenAI 预设中的 `prompts` 和 `prompt_order`，保持原始安全结构，
  /// 由主线程按自己的运行时语义映射，解析器本身绝不执行它们。
  Map<String, dynamic>? get openAiPromptData =>
      _openAiPromptData == null ? null : _copyMap(_openAiPromptData!);

  factory StoryTavernPresetPreview.accepted({
    required StoryTavernPresetKind kind,
    required Map<String, dynamic> sanitized,
    StoryTavernPresetApplyValues applyValues =
        const StoryTavernPresetApplyValues(),
    List<String> warnings = const [],
    Map<String, dynamic>? openAiPromptData,
  }) =>
      StoryTavernPresetPreview._(
        kind: kind,
        sanitized: sanitized,
        applyValues: applyValues,
        warnings: warnings,
        openAiPromptData: openAiPromptData,
      );

  factory StoryTavernPresetPreview.rejected(
    String error, [
    List<String> warnings = const [],
  ]) =>
      StoryTavernPresetPreview._(error: error, warnings: warnings);
}

/// App 自有导出格式的内存表示，用于无损保存已经清洗的预设数据。
class StoryTavernPresetBundle {
  final StoryTavernPresetKind kind;
  final Map<String, dynamic> _preset;

  StoryTavernPresetBundle({
    required this.kind,
    required Map<String, dynamic> preset,
  }) : _preset = _copyMap(preset);

  Map<String, dynamic> get preset => _copyMap(_preset);

  Map<String, dynamic> toJson() => {
        'format': 'chatai_deep_story_tavern_preset',
        'formatVersion': 1,
        'kind': kind.wireName,
        'preset': preset,
      };
}

Map<String, dynamic> _copyMap(Map<String, dynamic> source) =>
    Map<String, dynamic>.from(_copyJson(source) as Map);

dynamic _copyJson(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries) '${entry.key}': _copyJson(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _copyJson(item)];
  return value;
}
