import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

typedef RoleCardTranslationCall = Future<String?> Function(String prompt);
typedef RoleCardTranslationProgressCallback = void Function(
  RoleCardTranslationProgress progress,
);
typedef RoleCardFieldCheckpoint = Future<void> Function(
  String field,
  String value,
);
typedef RoleCardChunkCheckpoint = Future<void> Function(
  String field,
  TranslationChunkCheckpoint checkpoint,
);

final class _TranslationFieldInput {
  final String source;
  final String Function(String translated) restore;

  const _TranslationFieldInput({
    required this.source,
    required this.restore,
  });
}

/// 由上层任务运行器发出的立即停止信号，不能被字段降级逻辑吞掉。
class RoleCardTranslationCancelled implements Exception {
  const RoleCardTranslationCancelled();
}

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
  static const _chunkPlanner = TranslationChunkPlanner();

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
    Map<String, String> initialTranslatedFields = const {},
    RoleCardFieldCheckpoint? onFieldCheckpoint,
    Map<String, TranslationChunkCheckpoint> initialChunkCheckpoints = const {},
    RoleCardChunkCheckpoint? onChunkCheckpoint,
    TranslationRetryPolicy retryPolicy = const TranslationRetryPolicy(),
  }) async {
    final memoryBookView = AssistantRoleCardService.memoryBookTranslationView(
      assistant.memoryBook,
    );
    if (initialTranslatedFields.isNotEmpty ||
        initialChunkCheckpoints.isNotEmpty ||
        onChunkCheckpoint != null ||
        memoryBookView.hasRawMarker ||
        !_shouldUseWholeCardTranslation(assistant)) {
      final translated = await translateFieldsIndividually(
        assistant,
        complete: complete,
        onProgress: onProgress,
        initialTranslatedFields: initialTranslatedFields,
        onFieldCheckpoint: onFieldCheckpoint,
        initialChunkCheckpoints: initialChunkCheckpoints,
        onChunkCheckpoint: onChunkCheckpoint,
        retryPolicy: retryPolicy,
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
      await _checkpointTranslatedFields(
        assistant,
        translated,
        onFieldCheckpoint,
      );
      return applyTranslatedFields(assistant, translated);
    } on RoleCardTranslationCancelled {
      rethrow;
    } on TranslationRequestFailure catch (failure) {
      if (failure.kind == TranslationFailureKind.cancelled) {
        throw const RoleCardTranslationCancelled();
      }
      if (!_isTimeoutFailure(failure.kind)) {
        final decision = retryPolicy.decide(
          failure: failure,
          categoryAttempt: 0,
          chunkRunes: _wholeCardRuneCount(assistant),
          minimumSplitRunes: 0,
          now: DateTime.now(),
        );
        switch (decision.action) {
          case TranslationRetryAction.schedule:
            throw TranslationWorkDeferred(
              nextRunAt: decision.nextRunAt!,
              failure: failure,
            );
          case TranslationRetryAction.pause:
            throw TranslationWorkPaused(failure: failure);
          case TranslationRetryAction.cancel:
            throw const RoleCardTranslationCancelled();
          case TranslationRetryAction.retry:
          case TranslationRetryAction.repair:
          case TranslationRetryAction.split:
            break;
        }
      }
      final translated = await translateFieldsIndividually(
        assistant,
        complete: complete,
        onProgress: onProgress,
        initialTranslatedFields: initialTranslatedFields,
        onFieldCheckpoint: onFieldCheckpoint,
        initialChunkCheckpoints: initialChunkCheckpoints,
        onChunkCheckpoint: onChunkCheckpoint,
        retryPolicy: retryPolicy,
      );
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
        initialTranslatedFields: initialTranslatedFields,
        onFieldCheckpoint: onFieldCheckpoint,
        initialChunkCheckpoints: initialChunkCheckpoints,
        onChunkCheckpoint: onChunkCheckpoint,
        retryPolicy: retryPolicy,
      );
      return applyTranslatedFields(assistant, translated);
    }
  }

  static Future<Map<String, dynamic>> translateFieldsIndividually(
    AssistantModel assistant, {
    required RoleCardTranslationCall complete,
    RoleCardTranslationProgressCallback? onProgress,
    Map<String, String> initialTranslatedFields = const {},
    RoleCardFieldCheckpoint? onFieldCheckpoint,
    Map<String, TranslationChunkCheckpoint> initialChunkCheckpoints = const {},
    RoleCardChunkCheckpoint? onChunkCheckpoint,
    TranslationRetryPolicy retryPolicy = const TranslationRetryPolicy(),
  }) async {
    final translated = <String, dynamic>{
      for (final entry in initialTranslatedFields.entries)
        if (_fields.contains(entry.key) &&
            initialChunkCheckpoints[entry.key]?.matchesSource(
                  entry.key,
                  _translationFieldInput(assistant, entry.key).source,
                ) !=
                true)
          entry.key: entry.value,
    };
    for (var i = 0; i < _fields.length; i++) {
      final field = _fields[i];
      if (translated.containsKey(field)) {
        onProgress?.call(RoleCardTranslationProgress(
          field: field,
          fieldLabel: _fieldLabel(field),
          current: i + 1,
          total: _fields.length,
          stage: '从检查点恢复字段',
          fieldProgress: 1,
        ));
        continue;
      }
      final input = _translationFieldInput(assistant, field);
      final restored = initialChunkCheckpoints[field];
      final checkpoint =
          restored != null && restored.matchesSource(field, input.source)
              ? restored
              : _chunkPlanner.plan(field: field, source: input.source);
      if (checkpoint.chunks.every(
        (state) => state.chunk.sourceText.isEmpty,
      )) {
        final completedEmpty = TranslationChunkCheckpoint(
          field: checkpoint.field,
          sourceHash: checkpoint.sourceHash,
          chunks: [
            for (final state in checkpoint.chunks)
              state.status == TranslationChunkStatus.pending
                  ? TranslationChunkState(
                      chunk: state.chunk,
                      status: TranslationChunkStatus.completed,
                      translatedText: '',
                      attempts: state.attempts,
                      lastErrorKind: state.lastErrorKind,
                    )
                  : state,
          ],
        );
        await onChunkCheckpoint?.call(field, completedEmpty);
        final mergedBody = _mergeCheckpoint(completedEmpty);
        final merged = input.restore(mergedBody);
        translated[field] = merged;
        await onFieldCheckpoint?.call(field, merged);
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
        detail: '${input.source.runes.length} 字',
      ));
      final completed = await _translateCheckpoint(
        checkpoint: checkpoint,
        complete: complete,
        retryPolicy: retryPolicy,
        onChunkCheckpoint: onChunkCheckpoint,
        onProgress: onProgress,
        fieldIndex: i + 1,
        fieldTotal: _fields.length,
      );
      final mergedBody = _mergeCheckpoint(completed);
      try {
        _validateProtectedMarkers(
          field: field,
          source: input.source,
          translated: mergedBody,
        );
      } on FormatException {
        final retryable = TranslationChunkCheckpoint(
          field: completed.field,
          sourceHash: completed.sourceHash,
          chunks: [
            for (final state in completed.chunks)
              state.status == TranslationChunkStatus.retainedOriginal
                  ? state
                  : TranslationChunkState(
                      chunk: state.chunk,
                      status: TranslationChunkStatus.pending,
                      translatedText: '',
                      attempts: state.attempts == 0 ? 1 : state.attempts,
                      lastErrorKind: TranslationFailureKind.invalidOutput,
                    ),
          ],
        );
        await onChunkCheckpoint?.call(field, retryable);
        throw const TranslationWorkPaused(
          failure: TranslationRequestFailure(
            kind: TranslationFailureKind.invalidOutput,
            safeCode: 'invalid_translation_markers',
          ),
        );
      }
      final checkpointValue = input.restore(mergedBody);
      translated[field] = checkpointValue;
      await onFieldCheckpoint?.call(field, checkpointValue);
      final retainedOriginal = completed.chunks.any(
        (state) => state.status == TranslationChunkStatus.retainedOriginal,
      );
      onProgress?.call(RoleCardTranslationProgress(
        field: field,
        fieldLabel: _fieldLabel(field),
        current: i + 1,
        total: _fields.length,
        stage: retainedOriginal ? '字段部分翻译' : '字段已翻译',
        fieldProgress: 1,
      ));
    }
    return translated;
  }

  static Future<void> _checkpointTranslatedFields(
    AssistantModel assistant,
    Map<String, dynamic> translated,
    RoleCardFieldCheckpoint? checkpoint,
  ) async {
    if (checkpoint == null) return;
    for (final field in _fields) {
      final value = translated[field];
      await checkpoint(
        field,
        value is String ? value : _fieldValue(assistant, field),
      );
    }
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
    throw const FormatException('AI 翻译结果不是有效 JSON');
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
      roleCardAssets: assistant.roleCardAssets,
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

  static _TranslationFieldInput _translationFieldInput(
    AssistantModel assistant,
    String field,
  ) {
    final value = _fieldValue(assistant, field);
    if (field != 'memoryBook') {
      return _TranslationFieldInput(source: value, restore: (text) => text);
    }
    final view = AssistantRoleCardService.memoryBookTranslationView(value);
    if (!view.hasRawMarker) {
      return _TranslationFieldInput(source: value, restore: (text) => text);
    }
    return _TranslationFieldInput(
      source: view.translationSource,
      restore: view.translationSource.isEmpty ? (_) => value : view.restore,
    );
  }

  static bool _shouldUseWholeCardTranslation(AssistantModel assistant) {
    final chars = _fields.fold<int>(
      0,
      (sum, field) => sum + _fieldValue(assistant, field).trim().length,
    );
    return chars <= _wholeCardMaxChars;
  }

  static int _wholeCardRuneCount(AssistantModel assistant) => _fields.fold(
        0,
        (sum, field) => sum + _fieldValue(assistant, field).runes.length,
      );

  static bool _isTimeoutFailure(TranslationFailureKind kind) =>
      kind == TranslationFailureKind.firstEventTimeout ||
      kind == TranslationFailureKind.idleTimeout ||
      kind == TranslationFailureKind.totalTimeout;

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

  static Future<TranslationChunkCheckpoint> _translateCheckpoint({
    required TranslationChunkCheckpoint checkpoint,
    required RoleCardTranslationCall complete,
    required TranslationRetryPolicy retryPolicy,
    required RoleCardChunkCheckpoint? onChunkCheckpoint,
    required RoleCardTranslationProgressCallback? onProgress,
    required int fieldIndex,
    required int fieldTotal,
  }) async {
    var current = checkpoint;
    var chunkIndex = 0;
    while (chunkIndex < current.chunks.length) {
      final state = current.chunks[chunkIndex];
      if (state.status != TranslationChunkStatus.pending) {
        onProgress?.call(RoleCardTranslationProgress(
          field: current.field,
          fieldLabel: _fieldLabel(current.field),
          current: fieldIndex,
          total: fieldTotal,
          stage: '从检查点恢复分块',
          detail: '块 ${chunkIndex + 1}/${current.chunks.length}',
          fieldProgress: (chunkIndex + 1) / current.chunks.length,
        ));
        chunkIndex += 1;
        continue;
      }

      if (state.chunk.sourceText.isEmpty) {
        current = _replaceChunkState(
          current,
          chunkIndex,
          TranslationChunkState(
            chunk: state.chunk,
            status: TranslationChunkStatus.completed,
            translatedText: '',
            attempts: state.attempts,
            lastErrorKind: state.lastErrorKind,
          ),
        );
        await onChunkCheckpoint?.call(current.field, current);
        onProgress?.call(RoleCardTranslationProgress(
          field: current.field,
          fieldLabel: _fieldLabel(current.field),
          current: fieldIndex,
          total: fieldTotal,
          stage: '空分块已跳过',
          detail: '块 ${chunkIndex + 1}/${current.chunks.length}',
          fieldProgress: (chunkIndex + 1) / current.chunks.length,
        ));
        chunkIndex += 1;
        continue;
      }

      final resumedErrorKind = state.lastErrorKind;
      if (resumedErrorKind != null && _isTimeoutFailure(resumedErrorKind)) {
        final failure = TranslationRequestFailure(
          kind: resumedErrorKind,
          safeCode: resumedErrorKind.name,
        );
        final decision = retryPolicy.decide(
          failure: failure,
          categoryAttempt: state.attempts == 0 ? 0 : state.attempts - 1,
          chunkRunes: state.chunk.sourceText.runes.length,
          minimumSplitRunes: _minimumSplitRunes(current.field),
          now: DateTime.now(),
        );
        if (decision.action == TranslationRetryAction.split) {
          current = _chunkPlanner.splitTimedOut(
            checkpoint: current,
            chunkId: state.chunk.id,
          );
          await onChunkCheckpoint?.call(current.field, current);
          continue;
        }
        await onChunkCheckpoint?.call(current.field, current);
        throw TranslationWorkPaused(failure: failure);
      }

      try {
        final prompt =
            state.lastErrorKind == TranslationFailureKind.invalidOutput
                ? _buildFieldRepairPrompt(
                    field: current.field,
                    value: state.chunk.sourceText,
                  )
                : buildFieldPrompt(
                    field: current.field,
                    value: state.chunk.sourceText,
                  );
        final response = await complete(prompt);
        final translated = _decodeChunkTranslation(
          field: current.field,
          source: state.chunk.sourceText,
          response: response,
        );
        final completed = TranslationChunkState(
          chunk: state.chunk,
          status: TranslationChunkStatus.completed,
          translatedText: translated,
          attempts: state.attempts + 1,
          lastErrorKind: state.lastErrorKind,
        );
        current = _replaceChunkState(current, chunkIndex, completed);
        await onChunkCheckpoint?.call(current.field, current);
        onProgress?.call(RoleCardTranslationProgress(
          field: current.field,
          fieldLabel: _fieldLabel(current.field),
          current: fieldIndex,
          total: fieldTotal,
          stage: '分块已翻译',
          detail: '块 ${chunkIndex + 1}/${current.chunks.length}',
          fieldProgress: (chunkIndex + 1) / current.chunks.length,
        ));
        chunkIndex += 1;
      } on RoleCardTranslationCancelled {
        rethrow;
      } catch (error) {
        final failure = switch (error) {
          final TranslationRequestFailure failure => failure,
          FormatException _ => const TranslationRequestFailure(
              kind: TranslationFailureKind.invalidOutput,
              safeCode: 'invalid_translation_output',
            ),
          _ => null,
        };
        if (failure == null) rethrow;
        if (failure.kind == TranslationFailureKind.cancelled) {
          throw const RoleCardTranslationCancelled();
        }

        final categoryAttempt =
            state.lastErrorKind == failure.kind ? state.attempts : 0;
        final failed = TranslationChunkState(
          chunk: state.chunk,
          status: TranslationChunkStatus.pending,
          translatedText: '',
          attempts: categoryAttempt + 1,
          lastErrorKind: failure.kind,
        );
        final failedCheckpoint =
            _replaceChunkState(current, chunkIndex, failed);
        final decision = retryPolicy.decide(
          failure: failure,
          categoryAttempt: categoryAttempt,
          chunkRunes: state.chunk.sourceText.runes.length,
          minimumSplitRunes: _minimumSplitRunes(current.field),
          now: DateTime.now(),
        );
        switch (decision.action) {
          case TranslationRetryAction.retry:
          case TranslationRetryAction.repair:
            current = failedCheckpoint;
            await onChunkCheckpoint?.call(current.field, current);
            continue;
          case TranslationRetryAction.split:
            current = _chunkPlanner.splitTimedOut(
              checkpoint: failedCheckpoint,
              chunkId: state.chunk.id,
            );
            await onChunkCheckpoint?.call(current.field, current);
            continue;
          case TranslationRetryAction.schedule:
            current = failedCheckpoint;
            await onChunkCheckpoint?.call(current.field, current);
            throw TranslationWorkDeferred(
              nextRunAt: decision.nextRunAt!,
              failure: failure,
            );
          case TranslationRetryAction.pause:
            current = failedCheckpoint;
            await onChunkCheckpoint?.call(current.field, current);
            throw TranslationWorkPaused(failure: failure);
          case TranslationRetryAction.cancel:
            throw const RoleCardTranslationCancelled();
        }
      }
    }
    return current;
  }

  static TranslationChunkCheckpoint _replaceChunkState(
    TranslationChunkCheckpoint checkpoint,
    int index,
    TranslationChunkState state,
  ) =>
      TranslationChunkCheckpoint(
        field: checkpoint.field,
        sourceHash: checkpoint.sourceHash,
        chunks: [
          ...checkpoint.chunks.take(index),
          state,
          ...checkpoint.chunks.skip(index + 1),
        ],
      );

  static int _minimumSplitRunes(String field) =>
      field == 'memoryBook' || field == 'worldBook' ? 400 : 800;

  static String _mergeCheckpoint(TranslationChunkCheckpoint checkpoint) =>
      checkpoint.chunks.map((state) {
        final text = state.status == TranslationChunkStatus.completed
            ? state.translatedText
            : state.chunk.sourceText;
        return '$text${state.chunk.separatorAfter}';
      }).join();

  static String _decodeChunkTranslation({
    required String field,
    required String source,
    required String? response,
  }) {
    final decoded = decodeTranslation(response);
    final translated = decoded[field];
    if (translated is! String || (source.isNotEmpty && translated.isEmpty)) {
      throw const FormatException('翻译结果缺少目标字段');
    }
    _validateProtectedMarkers(
      field: field,
      source: source,
      translated: translated,
    );
    return translated;
  }

  static void _validateProtectedMarkers({
    required String field,
    required String source,
    required String translated,
  }) {
    final RegExp? pattern = switch (field) {
      'memoryBook' || 'worldBook' => RegExp(
          r'\[off\]|\[p=[^\]\r\n]*\]|\[re\]|\[sec=[^\]\r\n]*\]|=>',
        ),
      'exampleDialogs' => RegExp(r'<START>'),
      _ => null,
    };
    if (pattern == null) return;
    final before = pattern.allMatches(source).map((match) => match[0]).toList();
    final after =
        pattern.allMatches(translated).map((match) => match[0]).toList();
    if (before.length != after.length) {
      throw const FormatException('翻译结果改变了受保护标记');
    }
    for (var index = 0; index < before.length; index += 1) {
      if (before[index] != after[index]) {
        throw const FormatException('翻译结果改变了受保护标记');
      }
    }
  }

  static String _buildFieldRepairPrompt({
    required String field,
    required String value,
  }) =>
      [
        '上一次翻译结果不是有效 JSON 或改变了受保护标记，请修复。',
        '只返回一个包含 "$field" 字符串字段的 JSON 对象。',
        '不得添加、删除或重排原文中的受保护标记。',
        jsonEncode({field: value}),
      ].join('\n');

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
      throw const FormatException('AI 翻译结果未包含 JSON 对象');
    }
    return candidate.substring(start, end + 1);
  }
}
