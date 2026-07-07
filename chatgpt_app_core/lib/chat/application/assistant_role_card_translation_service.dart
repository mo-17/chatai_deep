import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/model/assistant_model.dart';

typedef RoleCardTranslationCall = Future<String?> Function(String prompt);
typedef RoleCardTranslationProgressCallback = void Function(
  RoleCardTranslationProgress progress,
);

class RoleCardTranslationProgress {
  final String field;
  final String fieldLabel;
  final int current;
  final int total;
  final String stage;
  final String detail;
  final double fieldProgress;

  const RoleCardTranslationProgress({
    required this.field,
    required this.fieldLabel,
    required this.current,
    required this.total,
    required this.stage,
    this.detail = '',
    this.fieldProgress = 0,
  });
}

class AssistantRoleCardTranslationService {
  const AssistantRoleCardTranslationService._();

  static const _wholeCardMaxChars = 3000;
  static const _fieldMaxAttempts = 2;
  static const _longFieldMaxChars = 2200;
  static const _longFieldRetryMaxChars = 900;
  static const _fieldCallTimeout = Duration(minutes: 2, seconds: 15);

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
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    if (!_shouldUseWholeCardTranslation(assistant)) {
      final translated = await translateFieldsIndividually(
        assistant,
        complete: complete,
        onProgress: onProgress,
      );
      return applyTranslatedFields(assistant, translated);
    }

    try {
      onProgress?.call(const RoleCardTranslationProgress(
        field: 'wholeCard',
        fieldLabel: '整卡',
        current: 1,
        total: 1,
        stage: '提交整卡翻译',
      ));
      final response = await complete(buildPrompt(assistant));
      onProgress?.call(const RoleCardTranslationProgress(
        field: 'wholeCard',
        fieldLabel: '整卡',
        current: 1,
        total: 1,
        stage: '解析整卡翻译',
      ));
      final translated = decodeTranslation(response);
      return applyTranslatedFields(assistant, translated);
    } catch (_) {
      onProgress?.call(const RoleCardTranslationProgress(
        field: 'wholeCard',
        fieldLabel: '整卡',
        current: 1,
        total: 1,
        stage: '整卡失败，改为分字段',
      ));
      final translated = await translateFieldsIndividually(
        assistant,
        complete: complete,
        onProgress: onProgress,
      );
      return applyTranslatedFields(assistant, translated);
    }
  }

  static Future<Map<String, dynamic>> translateFieldsIndividually(
    AssistantModel assistant, {
    required RoleCardTranslationCall complete,
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    final translated = <String, dynamic>{};
    for (var i = 0; i < _fields.length; i++) {
      final field = _fields[i];
      final value = _fieldValue(assistant, field);
      if (value.trim().isEmpty) {
        translated[field] = value;
        onProgress?.call(RoleCardTranslationProgress(
          field: field,
          fieldLabel: _fieldLabel(field),
          current: i + 1,
          total: _fields.length,
          stage: '字段为空，已跳过',
          fieldProgress: 1,
        ));
        continue;
      }
      onProgress?.call(RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: i + 1,
        total: _fields.length,
        stage: '准备翻译字段',
        detail: '${value.length} 字',
      ));
      final result = field == 'memoryBook'
          ? await _translateLongField(
              field: field,
              value: value,
              complete: complete,
              fieldIndex: i + 1,
              fieldTotal: _fields.length,
              onProgress: onProgress,
            )
          : await _translateSingleField(
              field: field,
              value: value,
              complete: complete,
              onProgress: onProgress,
              progress: RoleCardTranslationProgress(
                field: field,
                fieldLabel: _fieldLabel(field),
                current: i + 1,
                total: _fields.length,
                stage: '等待 AI 返回字段翻译',
              ),
            );
      translated[field] = result ?? value;
      onProgress?.call(RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: i + 1,
        total: _fields.length,
        stage: result == null ? '字段翻译失败，保留原文' : '字段已翻译',
        fieldProgress: 1,
      ));
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

  static bool _shouldUseWholeCardTranslation(AssistantModel assistant) {
    final chars = _fields.fold<int>(
      0,
      (sum, field) => sum + _fieldValue(assistant, field).trim().length,
    );
    return chars <= _wholeCardMaxChars;
  }

  static String _fieldLabel(String field) {
    switch (field) {
      case 'name':
        return '名称';
      case 'description':
        return '简介';
      case 'prompt':
        return '人设';
      case 'openingMessage':
        return '开场';
      case 'exampleDialogs':
        return '示例对话';
      case 'memoryBook':
        return '世界书';
    }
    return field;
  }

  static Future<String?> _translateSingleField({
    required String field,
    required String value,
    required RoleCardTranslationCall complete,
    int maxAttempts = _fieldMaxAttempts,
    RoleCardTranslationProgressCallback? onProgress,
    RoleCardTranslationProgress? progress,
  }) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        if (progress != null) {
          onProgress?.call(RoleCardTranslationProgress(
            field: progress.field,
            fieldLabel: progress.fieldLabel,
            current: progress.current,
            total: progress.total,
            stage: progress.stage,
            detail: maxAttempts <= 1
                ? progress.detail
                : '第 ${attempt + 1}/$maxAttempts 次',
            fieldProgress: progress.fieldProgress,
          ));
        }
        final response = await complete(buildFieldPrompt(
          field: field,
          value: value,
        )).timeout(_fieldCallTimeout);
        final translated = decodeTranslation(response);
        final result = translated[field];
        return result is String ? result : null;
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          if (progress != null) {
            onProgress?.call(RoleCardTranslationProgress(
              field: progress.field,
              fieldLabel: progress.fieldLabel,
              current: progress.current,
              total: progress.total,
              stage: progress.stage,
              detail: e is TimeoutException ? '请求超时，保留原文' : '翻译失败，保留原文',
              fieldProgress: progress.fieldProgress,
            ));
          }
          return null;
        }
      }
    }
    return null;
  }

  static Future<String?> _translateLongField({
    required String field,
    required String value,
    required RoleCardTranslationCall complete,
    required int fieldIndex,
    required int fieldTotal,
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    final chunks = _chunkTextByLines(value, maxChars: _longFieldMaxChars);
    final translated = <String>[];
    var changed = false;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final result = await _translateLongFieldChunk(
        field: field,
        chunk: chunk,
        complete: complete,
        fieldIndex: fieldIndex,
        fieldTotal: fieldTotal,
        chunkIndex: i + 1,
        chunkTotal: chunks.length,
        onProgress: onProgress,
      );
      translated.add(result.text);
      changed = changed || result.changed;
    }
    return changed ? translated.join('\n') : null;
  }

  static Future<_TranslatedChunk> _translateLongFieldChunk({
    required String field,
    required String chunk,
    required RoleCardTranslationCall complete,
    required int fieldIndex,
    required int fieldTotal,
    required int chunkIndex,
    required int chunkTotal,
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    final result = await _translateSingleField(
      field: field,
      value: chunk,
      complete: complete,
      onProgress: onProgress,
      progress: RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: fieldIndex,
        total: fieldTotal,
        stage: '翻译长字段分块',
        detail: '块 $chunkIndex/$chunkTotal',
        fieldProgress: (chunkIndex - 1).clamp(0, chunkTotal) / chunkTotal,
      ),
    );
    if (result != null) {
      onProgress?.call(RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: fieldIndex,
        total: fieldTotal,
        stage: '长字段分块已翻译',
        detail: '块 $chunkIndex/$chunkTotal',
        fieldProgress: chunkIndex / chunkTotal,
      ));
      return _TranslatedChunk(result, result != chunk);
    }
    if (chunk.length <= _longFieldRetryMaxChars) {
      onProgress?.call(RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: fieldIndex,
        total: fieldTotal,
        stage: '长字段分块保留原文',
        detail: '块 $chunkIndex/$chunkTotal',
        fieldProgress: chunkIndex / chunkTotal,
      ));
      return _TranslatedChunk(chunk, false);
    }

    final subChunks = _chunkTextByLines(
      chunk,
      maxChars: _longFieldRetryMaxChars,
    );
    if (subChunks.length <= 1) {
      return _TranslatedChunk(chunk, false);
    }

    final translated = <String>[];
    var changed = false;
    for (var i = 0; i < subChunks.length; i++) {
      final subChunk = subChunks[i];
      final subResult = await _translateSingleField(
        field: field,
        value: subChunk,
        complete: complete,
        onProgress: onProgress,
        progress: RoleCardTranslationProgress(
          field: field,
          fieldLabel: _fieldLabel(field),
          current: fieldIndex,
          total: fieldTotal,
          stage: '重试长字段小分块',
          detail: '块 $chunkIndex/$chunkTotal · 小块 ${i + 1}/${subChunks.length}',
          fieldProgress: ((chunkIndex - 1) +
                  ((i).clamp(0, subChunks.length) / subChunks.length)) /
              chunkTotal,
        ),
      );
      translated.add(subResult ?? subChunk);
      changed = changed || (subResult != null && subResult != subChunk);
      onProgress?.call(RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: fieldIndex,
        total: fieldTotal,
        stage: subResult == null ? '小分块保留原文' : '小分块已翻译',
        detail: '块 $chunkIndex/$chunkTotal · 小块 ${i + 1}/${subChunks.length}',
        fieldProgress:
            ((chunkIndex - 1) + ((i + 1) / subChunks.length)) / chunkTotal,
      ));
    }

    return changed
        ? _TranslatedChunk(translated.join('\n'), true)
        : _TranslatedChunk(chunk, false);
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

class _TranslatedChunk {
  const _TranslatedChunk(this.text, this.changed);

  final String text;
  final bool changed;
}
