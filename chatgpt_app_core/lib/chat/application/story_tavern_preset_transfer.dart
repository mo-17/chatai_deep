import 'dart:convert';

import 'package:chatgpt_app_core/model/story_tavern_preset.dart';

/// SillyTavern 预设的纯数据安全边界。
///
/// 这里不会解释宏、执行脚本、编译正则或发起网络请求；所有字符串都只是
/// 不透明数据。调用方只可从 [StoryTavernPresetPreview.applyValues] 映射受限
/// 采样值，OpenAI prompt 则以安全原始结构交回主线程。
class StoryTavernPresetTransfer {
  static const maxSourceBytes = 256 * 1024;
  static const maxRoomBundleBytes = (maxSourceBytes * 4) + (16 * 1024);
  static const maxJsonDepth = 32;
  static const maxArrayItems = 512;
  static const maxMapEntries = 512;
  static const maxJsonStringChars = 32 * 1024;

  static const bundleFormat = 'chatai_deep_story_tavern_preset';
  static const bundleFormatVersion = 1;
  static const roomBundleFormat = 'chatai_deep_story_tavern_preset_bundle';
  static const roomBundleFormatVersion = 1;

  const StoryTavernPresetTransfer._();

  /// 解析一个原始 SillyTavern 预设 JSON。
  static StoryTavernPresetPreview previewJson(String source) {
    final warnings = <String>[];
    if (utf8.encode(source).length > maxSourceBytes) {
      return StoryTavernPresetPreview.rejected(
        '预设文件超过 ${maxSourceBytes ~/ 1024}KB 限制。',
      );
    }
    dynamic decoded;
    try {
      final normalized =
          source.startsWith('\uFEFF') ? source.substring(1) : source;
      decoded = jsonDecode(normalized);
    } catch (_) {
      return StoryTavernPresetPreview.rejected('不是有效的 JSON 预设文件。');
    }
    if (decoded is! Map) {
      return StoryTavernPresetPreview.rejected('预设根节点必须是 JSON 对象。');
    }
    final root = _stringMap(decoded);
    final limitError = _jsonLimitError(root, 0);
    if (limitError != null) {
      return StoryTavernPresetPreview.rejected(limitError);
    }

    final sanitized = _sanitizeMap(root, warnings, path: r'$');
    final kind = _recognize(sanitized);
    if (kind == null) {
      return StoryTavernPresetPreview.rejected(
        '无法识别为 Context、Instruct、TextGen sampler 或 OpenAI preset。',
        warnings,
      );
    }

    final applyValues = _extractApplyValues(sanitized, kind, warnings);
    final promptData = kind == StoryTavernPresetKind.openAi
        ? _openAiPromptData(sanitized)
        : null;
    if (kind == StoryTavernPresetKind.context ||
        kind == StoryTavernPresetKind.instruct) {
      warnings.add('${kind.wireName} 预设仅作为不执行的声明式数据保留。');
    }
    return StoryTavernPresetPreview.accepted(
      kind: kind,
      sanitized: sanitized,
      applyValues: applyValues,
      warnings: warnings,
      openAiPromptData: promptData,
    );
  }

  /// [previewJson] 的语义别名，方便导入调用点使用。
  static StoryTavernPresetPreview importJson(String source) =>
      previewJson(source);

  static StoryTavernPresetBundle exportBundle(
    StoryTavernPresetPreview preview,
  ) {
    if (!preview.isAccepted ||
        preview.kind == null ||
        preview.sanitized == null) {
      throw ArgumentError('不能导出未通过安全检查的预设。');
    }
    return StoryTavernPresetBundle(
      kind: preview.kind!,
      preset: preview.sanitized!,
    );
  }

  static String exportBundleJson(StoryTavernPresetPreview preview) =>
      const JsonEncoder.withIndent('  ')
          .convert(exportBundle(preview).toJson());

  /// 导入 App 导出的 bundle，并再次走完整安全解析而不是信任历史文件。
  static StoryTavernPresetPreview previewBundleJson(String source) {
    if (utf8.encode(source).length > maxSourceBytes) {
      return StoryTavernPresetPreview.rejected(
        '预设 bundle 超过 ${maxSourceBytes ~/ 1024}KB 限制。',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(
          source.startsWith('\uFEFF') ? source.substring(1) : source);
    } catch (_) {
      return StoryTavernPresetPreview.rejected('不是有效的预设 bundle JSON。');
    }
    if (decoded is! Map) {
      return StoryTavernPresetPreview.rejected('预设 bundle 根节点必须是对象。');
    }
    final root = _stringMap(decoded);
    final limitError = _jsonLimitError(root, 0);
    if (limitError != null) {
      return StoryTavernPresetPreview.rejected(limitError);
    }
    if (root['format'] != bundleFormat) {
      return StoryTavernPresetPreview.rejected('不是本 App 导出的酒馆预设 bundle。');
    }
    final version = _int(root['formatVersion']);
    if (version == null || version != bundleFormatVersion) {
      return StoryTavernPresetPreview.rejected('不支持该预设 bundle 格式版本。');
    }
    final declaredKind =
        StoryTavernPresetKindWireName.fromWireName(root['kind']);
    final rawPreset = root['preset'];
    if (declaredKind == null || rawPreset is! Map) {
      return StoryTavernPresetPreview.rejected('预设 bundle 缺少有效 kind 或 preset。');
    }
    final preview = previewJson(jsonEncode(_stringMap(rawPreset)));
    if (!preview.isAccepted) return preview;
    if (preview.kind != declaredKind) {
      return StoryTavernPresetPreview.rejected(
          '预设 bundle 的类型与内容不一致。', preview.warnings);
    }
    return preview;
  }

  static StoryTavernPresetPreview importBundleJson(String source) =>
      previewBundleJson(source);

  /// 将单个安全预设合并到房间集合；同类型只保留最后一次导入的版本。
  static String mergeRoomBundle(
    String current,
    StoryTavernPresetPreview preview,
  ) {
    if (!preview.isAccepted ||
        preview.kind == null ||
        preview.sanitized == null) {
      throw ArgumentError('不能保存未通过安全检查的预设。');
    }
    final presets = <String, dynamic>{};
    for (final item in previewsFromRoomBundle(current)) {
      presets[item.kind!.wireName] = item.sanitized;
    }
    presets[preview.kind!.wireName] = preview.sanitized;
    return jsonEncode({
      'format': roomBundleFormat,
      'formatVersion': roomBundleFormatVersion,
      'presets': presets,
    });
  }

  /// 读取房间集合时逐项重走安全边界；损坏或类型不一致的条目会被丢弃。
  static List<StoryTavernPresetPreview> previewsFromRoomBundle(String source) {
    final normalized =
        source.startsWith('\uFEFF') ? source.substring(1) : source;
    if (normalized.trim().isEmpty ||
        utf8.encode(normalized).length > maxRoomBundleBytes) {
      return const [];
    }
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is! Map || decoded['format'] != roomBundleFormat) {
        return const [];
      }
      if (_int(decoded['formatVersion']) != roomBundleFormatVersion ||
          decoded['presets'] is! Map) {
        return const [];
      }
      final output = <StoryTavernPresetPreview>[];
      for (final entry in (decoded['presets'] as Map).entries) {
        final declared =
            StoryTavernPresetKindWireName.fromWireName('${entry.key}');
        if (declared == null || entry.value is! Map) continue;
        final preview = previewJson(jsonEncode(entry.value));
        if (preview.isAccepted && preview.kind == declared) output.add(preview);
      }
      return List.unmodifiable(output);
    } catch (_) {
      return const [];
    }
  }

  static String exportRoomBundleJson(String source) {
    final previews = previewsFromRoomBundle(source);
    if (previews.isEmpty) throw ArgumentError('房间没有可导出的 Tavern 预设。');
    var normalized = '';
    for (final preview in previews) {
      normalized = mergeRoomBundle(normalized, preview);
    }
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(normalized));
  }

  /// 对来自模板、备份或同步的不可信持久化字段重新清洗并规范化。
  static String normalizeRoomBundle(Object? source) {
    if (source is! String) return '';
    final previews = previewsFromRoomBundle(source);
    if (previews.isEmpty) return '';
    var normalized = '';
    for (final preview in previews) {
      normalized = mergeRoomBundle(normalized, preview);
    }
    return normalized;
  }

  static double? safeTemperature(Object? value) {
    final parsed = _double(value);
    return parsed != null && parsed >= 0 && parsed <= 2 ? parsed : null;
  }

  static double? safeTopP(Object? value) {
    final parsed = _double(value);
    return parsed != null && parsed >= 0 && parsed <= 1 ? parsed : null;
  }

  static int? safeMaxTokens(Object? value) {
    final parsed = _int(value);
    return parsed != null && parsed >= 1 && parsed <= 32768 ? parsed : null;
  }

  /// 同时接受第三方单预设、本 App 单预设 bundle 和房间多预设 bundle。
  static List<StoryTavernPresetPreview> previewImportFile(String source) {
    if (utf8.encode(source).length > maxRoomBundleBytes) return const [];
    try {
      final decoded = jsonDecode(
          source.startsWith('\uFEFF') ? source.substring(1) : source);
      if (decoded is Map && decoded['format'] == roomBundleFormat) {
        return previewsFromRoomBundle(source);
      }
      if (decoded is Map && decoded['format'] == bundleFormat) {
        final preview = previewBundleJson(source);
        return preview.isAccepted ? [preview] : const [];
      }
    } catch (_) {
      // 交给原始预设解析器返回明确错误。
    }
    final preview = previewJson(source);
    return preview.isAccepted ? [preview] : const [];
  }

  static StoryTavernPresetKind? _recognize(Map<String, dynamic> preset) {
    if (preset.containsKey('prompts') || preset.containsKey('prompt_order')) {
      return StoryTavernPresetKind.openAi;
    }
    if (_hasAny(preset, const [
      'input_sequence',
      'output_sequence',
      'system_sequence',
      'last_output_sequence',
      'first_output_sequence',
      'stop_sequence',
      'instruct',
    ])) {
      return StoryTavernPresetKind.instruct;
    }
    if (_hasAny(preset, const [
      'story_string',
      'context',
      'chat_start',
      'example_separator',
      'use_story_string',
    ])) {
      return StoryTavernPresetKind.context;
    }
    if (_hasAny(preset, const [
      'temp',
      'temperature',
      'top_p',
      'top_k',
      'rep_pen',
      'max_new_tokens',
      'max_length',
    ])) {
      return StoryTavernPresetKind.textgenSampler;
    }
    return null;
  }

  static StoryTavernPresetApplyValues _extractApplyValues(
    Map<String, dynamic> preset,
    StoryTavernPresetKind kind,
    List<String> warnings,
  ) {
    if (kind == StoryTavernPresetKind.context ||
        kind == StoryTavernPresetKind.instruct) {
      return const StoryTavernPresetApplyValues();
    }
    final temperature = _readTemperature(preset, warnings);
    final topP = _readTopP(preset, warnings);
    final maxTokens = _readMaxTokens(preset, warnings);
    return StoryTavernPresetApplyValues(
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
    );
  }

  static double? _readTopP(
    Map<String, dynamic> preset,
    List<String> warnings,
  ) {
    if (!preset.containsKey('top_p')) return null;
    final value = _double(preset['top_p']);
    if (value != null && value >= 0 && value <= 1) return value;
    warnings.add('top_p 不在 0..1 范围内，未应用。');
    return null;
  }

  static double? _readTemperature(
    Map<String, dynamic> preset,
    List<String> warnings,
  ) {
    const keys = ['temperature', 'temp', 'sampling_temperature'];
    for (final key in keys) {
      if (!preset.containsKey(key)) continue;
      final value = _double(preset[key]);
      if (value != null && value >= 0 && value <= 2) return value;
      warnings.add('$key 不在 0..2 范围内，未应用。');
      return null;
    }
    return null;
  }

  static int? _readMaxTokens(
    Map<String, dynamic> preset,
    List<String> warnings,
  ) {
    const keys = ['max_tokens', 'max_new_tokens', 'max_length'];
    for (final key in keys) {
      if (!preset.containsKey(key)) continue;
      final value = _int(preset[key]);
      if (value != null && value >= 1 && value <= 32768) return value;
      warnings.add('$key 不在 1..32768 范围内，未应用。');
      return null;
    }
    return null;
  }

  static Map<String, dynamic> _openAiPromptData(Map<String, dynamic> preset) {
    final result = <String, dynamic>{};
    for (final key in const ['prompts', 'prompt_order']) {
      if (preset.containsKey(key)) result[key] = _copyJson(preset[key]);
    }
    return result;
  }

  static Map<String, dynamic> _sanitizeMap(
    Map<String, dynamic> source,
    List<String> warnings, {
    required String path,
  }) {
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      final key = entry.key;
      if (_isSensitiveOrRouteKey(key)) {
        warnings.add('$path.$key 已移除敏感或路由字段。');
        continue;
      }
      if (_isExecutableKey(key)) {
        warnings.add('$path.$key 已移除可执行字段。');
        continue;
      }
      result[key] = _sanitizeValue(entry.value, warnings, '$path.$key');
    }
    return result;
  }

  static dynamic _sanitizeValue(
    Object? value,
    List<String> warnings,
    String path,
  ) {
    if (value is Map) {
      return _sanitizeMap(_stringMap(value), warnings, path: path);
    }
    if (value is List) {
      return [
        for (var index = 0; index < value.length; index++)
          _sanitizeValue(value[index], warnings, '$path[$index]'),
      ];
    }
    return value;
  }

  static String? _jsonLimitError(Object? value, int depth) {
    if (depth > maxJsonDepth) return 'JSON 嵌套深度超过 $maxJsonDepth 层限制。';
    if (value is String) {
      return value.length > maxJsonStringChars
          ? 'JSON 字符串超过 $maxJsonStringChars 字符限制。'
          : null;
    }
    if (value is num || value is bool || value == null) return null;
    if (value is List) {
      if (value.length > maxArrayItems) {
        return 'JSON 数组超过 $maxArrayItems 项限制。';
      }
      for (final item in value) {
        final error = _jsonLimitError(item, depth + 1);
        if (error != null) return error;
      }
      return null;
    }
    if (value is Map) {
      if (value.length > maxMapEntries) {
        return 'JSON 对象超过 $maxMapEntries 个字段限制。';
      }
      for (final entry in value.entries) {
        if (entry.key is! String) return 'JSON 对象包含非字符串字段名。';
        final keyError = _jsonLimitError(entry.key, depth + 1);
        if (keyError != null) return keyError;
        final valueError = _jsonLimitError(entry.value, depth + 1);
        if (valueError != null) return valueError;
      }
      return null;
    }
    return 'JSON 包含不支持的值类型。';
  }

  static bool _hasAny(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      if (value.containsKey(key)) return true;
    }
    return false;
  }

  static Map<String, dynamic> _stringMap(Map source) =>
      Map<String, dynamic>.fromEntries(
        source.entries.map((entry) => MapEntry('${entry.key}', entry.value)),
      );

  static String _normalizedKey(String value) {
    final buffer = StringBuffer();
    for (final code in value.codeUnits) {
      if (code >= 65 && code <= 90) {
        buffer.writeCharCode(code + 32);
      } else if ((code >= 97 && code <= 122) || (code >= 48 && code <= 57)) {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  static bool _isSensitiveOrRouteKey(String key) {
    final normalized = _normalizedKey(key);
    const exact = {
      'authorization',
      'cookie',
      'cookies',
      'password',
      'passwd',
      'secret',
      'credential',
      'credentials',
      'proxy',
      'reverseproxy',
      'customurl',
      'url',
      'uri',
      'endpoint',
      'baseurl',
      'baseuri',
      'host',
      'hostname',
      'server',
      'address',
      'headers',
      'header',
      'route',
      'routing',
      'connection',
      'model',
      'modelid',
      'provider',
      'providerid',
      'chatcompletionsource',
      'apitype',
    };
    if (exact.contains(normalized)) return true;
    return normalized.contains('apikey') ||
        normalized.contains('authorization') ||
        normalized.contains('password') ||
        normalized.contains('passwd') ||
        normalized.contains('secret') ||
        normalized.contains('credential') ||
        normalized.contains('cookie') ||
        normalized.contains('proxy') ||
        normalized.contains('customurl') ||
        normalized.endsWith('token') ||
        normalized.endsWith('url') ||
        normalized.endsWith('uri') ||
        normalized.endsWith('endpoint');
  }

  static bool _isExecutableKey(String key) {
    final normalized = _normalizedKey(key);
    const exact = {
      'macro',
      'macros',
      'script',
      'scripts',
      'regex',
      'regexp',
      'regularexpression',
      'command',
      'commands',
      'shell',
      'javascript',
      'js',
      'function',
      'callback',
      'onload',
      'onmessage',
    };
    return exact.contains(normalized) ||
        normalized.endsWith('script') ||
        normalized.endsWith('regex') ||
        normalized.endsWith('command');
  }

  static double? _double(Object? value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    return int.tryParse('$value');
  }

  static dynamic _copyJson(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}': _copyJson(entry.value),
      };
    }
    if (value is List) return [for (final item in value) _copyJson(item)];
    return value;
  }
}
