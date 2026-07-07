import 'dart:convert';

import 'package:chatgpt_app_core/model/assistant_model.dart';

typedef RoleCardTranslationCall = Future<String?> Function(String prompt);

class AssistantRoleCardTranslationService {
  const AssistantRoleCardTranslationService._();

  static const _fields = [
    'name',
    'description',
    'prompt',
    'openingMessage',
    'exampleDialogs',
    'memoryBook',
  ];

  static Future<AssistantModel> translateToSimplifiedChinese(
    AssistantModel assistant, {
    required RoleCardTranslationCall complete,
  }) async {
    try {
      final response = await complete(buildPrompt(assistant));
      final translated = decodeTranslation(response);
      return applyTranslatedFields(assistant, translated);
    } catch (_) {
      final translated = await translateFieldsIndividually(
        assistant,
        complete: complete,
      );
      return applyTranslatedFields(assistant, translated);
    }
  }

  static Future<Map<String, dynamic>> translateFieldsIndividually(
    AssistantModel assistant, {
    required RoleCardTranslationCall complete,
  }) async {
    final translated = <String, dynamic>{};
    for (final field in _fields) {
      final value = _fieldValue(assistant, field);
      if (value.trim().isEmpty) {
        translated[field] = value;
        continue;
      }
      final result = field == 'memoryBook'
          ? await _translateLongField(
              field: field,
              value: value,
              complete: complete,
            )
          : await _translateSingleField(
              field: field,
              value: value,
              complete: complete,
            );
      translated[field] = result ?? value;
    }
    return translated;
  }

  static String buildPrompt(AssistantModel assistant) {
    final payload = <String, String>{
      for (final field in _fields) field: _fieldValue(assistant, field),
    };
    return [
      '你是角色卡本地化助手。请将下面 JSON 中的自然语言文本翻译为简体中文。',
      '要求：',
      '1. 只返回一个 JSON 对象，不要 Markdown，不要解释。',
      '2. 保持字段名不变，只处理 name、description、prompt、openingMessage、exampleDialogs、memoryBook。',
      '3. 不要添加、删除或改写工具 ID、模型 ID、服务商 ID、语音 ID、文件路径、URL。',
      '4. memoryBook 可能包含 [off]、[p=10]、[re]、[sec=...]、=>、正则表达式和关键词；保留这些结构与正则表达式，只翻译自然语言内容。',
      '5. 如果某个字段为空，保持空字符串。',
      '',
      jsonEncode(payload),
    ].join('\n');
  }

  static String buildFieldPrompt({
    required String field,
    required String value,
  }) {
    return [
      '你是角色卡本地化助手。请将下面 JSON 中 "$field" 字段的自然语言文本翻译为简体中文。',
      '要求：',
      '1. 只返回一个 JSON 对象，不要 Markdown，不要解释。',
      '2. 保持字段名 "$field" 不变。',
      '3. 不要添加、删除或改写工具 ID、模型 ID、服务商 ID、语音 ID、文件路径、URL。',
      if (field == 'memoryBook')
        '4. memoryBook 可能包含 [off]、[p=10]、[re]、[sec=...]、=>、正则表达式和关键词；保留这些结构与正则表达式，只翻译自然语言内容。',
      '',
      jsonEncode({field: value}),
    ].join('\n');
  }

  static Map<String, dynamic> decodeTranslation(String? response) {
    final raw = response?.trim();
    if (raw == null || raw.isEmpty) {
      throw const FormatException('AI 未返回翻译结果');
    }
    final jsonText = _extractJsonObject(raw);
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 统一走下面的 FormatException，避免把大段 AI 原文抛到 UI。
    }
    throw FormatException('AI 翻译结果不是有效 JSON：${_preview(raw)}');
  }

  static AssistantModel applyTranslatedFields(
    AssistantModel assistant,
    Map<String, dynamic> translated,
  ) {
    return AssistantModel(
      id: assistant.id,
      name: _translated(translated, 'name', assistant.name),
      emoji: assistant.emoji,
      avatarType: assistant.avatarType,
      avatarValue: assistant.avatarValue,
      prompt: _translated(translated, 'prompt', assistant.prompt),
      description:
          _translated(translated, 'description', assistant.description),
      openingMessage:
          _translated(translated, 'openingMessage', assistant.openingMessage),
      exampleDialogs:
          _translated(translated, 'exampleDialogs', assistant.exampleDialogs),
      memoryBook: _translated(translated, 'memoryBook', assistant.memoryBook),
      defaultVoiceStyle: assistant.defaultVoiceStyle,
      providerId: assistant.providerId,
      model: assistant.model,
      useTools: assistant.useTools,
      toolIds: assistant.toolIds == null
          ? null
          : List<String>.from(assistant.toolIds!),
      createdAt: assistant.createdAt,
      updatedAt: assistant.updatedAt,
    );
  }

  static String _fieldValue(AssistantModel assistant, String field) {
    switch (field) {
      case 'name':
        return assistant.name;
      case 'description':
        return assistant.description;
      case 'prompt':
        return assistant.prompt;
      case 'openingMessage':
        return assistant.openingMessage;
      case 'exampleDialogs':
        return assistant.exampleDialogs;
      case 'memoryBook':
        return assistant.memoryBook;
    }
    return '';
  }

  static Future<String?> _translateSingleField({
    required String field,
    required String value,
    required RoleCardTranslationCall complete,
  }) async {
    try {
      final response = await complete(buildFieldPrompt(
        field: field,
        value: value,
      ));
      final translated = decodeTranslation(response);
      final result = translated[field];
      return result is String ? result : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _translateLongField({
    required String field,
    required String value,
    required RoleCardTranslationCall complete,
  }) async {
    final chunks = _chunkTextByLines(value);
    final translated = <String>[];
    var changed = false;
    for (final chunk in chunks) {
      final result = await _translateSingleField(
        field: field,
        value: chunk,
        complete: complete,
      );
      translated.add(result ?? chunk);
      changed = changed || (result != null && result != chunk);
    }
    return changed ? translated.join('\n') : null;
  }

  static List<String> _chunkTextByLines(String value, {int maxChars = 2200}) {
    final lines = value.replaceAll('\r\n', '\n').split('\n');
    final chunks = <String>[];
    final current = <String>[];
    var currentChars = 0;
    void flush() {
      if (current.isEmpty) return;
      chunks.add(current.join('\n'));
      current.clear();
      currentChars = 0;
    }

    for (final line in lines) {
      final lineChars = line.length + (current.isEmpty ? 0 : 1);
      if (current.isNotEmpty && currentChars + lineChars > maxChars) {
        flush();
      }
      if (line.length > maxChars) {
        var start = 0;
        while (start < line.length) {
          final end = (start + maxChars).clamp(0, line.length).toInt();
          chunks.add(line.substring(start, end));
          start = end;
        }
        continue;
      }
      current.add(line);
      currentChars += lineChars;
    }
    flush();
    return chunks.isEmpty ? [''] : chunks;
  }

  static String _translated(
    Map<String, dynamic> translated,
    String field,
    String fallback,
  ) {
    final value = translated[field];
    if (value is! String) return fallback;
    return value;
  }

  static String _extractJsonObject(String raw) {
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```')
        .firstMatch(raw)
        ?.group(1)
        ?.trim();
    final candidate = fenced ?? raw;
    final start = candidate.indexOf('{');
    final end = candidate.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw FormatException('AI 翻译结果未包含 JSON 对象：${_preview(raw)}');
    }
    return candidate.substring(start, end + 1);
  }

  static String _preview(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 240) return text;
    return '${text.substring(0, 240)}...';
  }
}
