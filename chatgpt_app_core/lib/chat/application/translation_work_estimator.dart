import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/role_card_translation_fields.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';

final class TranslationWorkEstimate {
  final int totalRunes;
  final int resolvedRunes;
  final bool usedFallback;

  TranslationWorkEstimate({
    required int totalRunes,
    required int resolvedRunes,
    required this.usedFallback,
  })  : totalRunes = totalRunes < 0 ? 0 : totalRunes,
        resolvedRunes = resolvedRunes.clamp(
          0,
          totalRunes < 0 ? 0 : totalRunes,
        );
}

final class TranslationProgressAnchor {
  final int totalRunes;
  final int anchorResolvedRunes;
  final double anchorProgress;

  const TranslationProgressAnchor({
    required this.totalRunes,
    required this.anchorResolvedRunes,
    required this.anchorProgress,
  });

  double map(int resolvedRunes) {
    if (totalRunes <= 0) {
      return anchorProgress.clamp(0.04, 0.94).toDouble();
    }
    if (anchorResolvedRunes >= totalRunes) return 0.94;
    final remaining = ((resolvedRunes - anchorResolvedRunes) /
            (totalRunes - anchorResolvedRunes))
        .clamp(0, 1);
    final anchored = anchorProgress + remaining * (0.94 - anchorProgress);
    final canonical = 0.04 + 0.90 * (resolvedRunes / totalRunes).clamp(0, 1);
    return [anchorProgress, anchored, canonical]
        .reduce((a, b) => a > b ? a : b)
        .clamp(0.04, 0.94)
        .toDouble();
  }
}

final class TranslationWorkEstimator {
  const TranslationWorkEstimator();

  int totalRunesForAssistant(AssistantModel assistant) =>
      RoleCardTranslationFields.fromAssistant(assistant).fold(
        0,
        (total, field) => total + field.source.runes.length,
      );

  int totalRunesForResults(
    Iterable<AssistantRoleCardImportResult> results, {
    String initialOpening = '',
  }) =>
      results.fold<int>(
        initialOpening.runes.length,
        (total, result) => total + totalRunesForAssistant(result.assistant),
      );

  int resolvedRunesForCheckpoint(TranslationChunkCheckpoint checkpoint) {
    var resolved = 0;
    var total = 0;
    for (final state in checkpoint.chunks) {
      final chunk = state.chunk;
      if (chunk.sourceHash != checkpoint.sourceHash) continue;
      final runes =
          chunk.sourceText.runes.length + chunk.separatorAfter.runes.length;
      total += runes;
      if (state.status != TranslationChunkStatus.pending) resolved += runes;
    }
    return resolved.clamp(0, total);
  }

  int? tryTotalRunesForTaskSource(String sourcePayload) {
    final payload = _decodeTaskSource(sourcePayload);
    if (payload == null) return null;
    return totalRunesForResults(
      payload.results,
      initialOpening: payload.initialOpening,
    );
  }

  TranslationWorkEstimate? estimateTask(
    StoryTemplateTranslationTaskModel task,
  ) {
    final source = _decodeTaskSource(task.sourcePayload);
    if (source == null) return null;
    final totalRunes = totalRunesForResults(
      source.results,
      initialOpening: source.initialOpening,
    );
    if (task.checkpointVersion != 0 &&
        task.checkpointVersion != TranslationChunkCheckpoint.currentVersion) {
      return TranslationWorkEstimate(
        totalRunes: totalRunes,
        resolvedRunes: 0,
        usedFallback: true,
      );
    }

    final chunks = _decodeTaskChunks(task.chunkPayload);
    if (chunks.usedFallback) {
      return TranslationWorkEstimate(
        totalRunes: totalRunes,
        resolvedRunes: 0,
        usedFallback: true,
      );
    }
    if (chunks.failed) return null;

    final partial = _decodePartial(task, source);
    final fields = _decodeFields(task.fieldPayload);
    var resolved = 0;
    for (var roleIndex = 0; roleIndex < source.results.length; roleIndex += 1) {
      final assistant = source.results[roleIndex].assistant;
      if (roleIndex < partial.completedRoleCount) {
        resolved += totalRunesForAssistant(assistant);
        continue;
      }
      if (roleIndex != partial.completedRoleCount) continue;
      final roleFields = RoleCardTranslationFields.fromAssistant(assistant);
      for (final field in roleFields) {
        final fieldRunes = field.source.runes.length;
        final rawMarkerMemoryBook =
            field.id == 'memoryBook' && field.source != assistant.memoryBook;
        final fieldResolved = fields.scope == 'role' &&
            fields.roleIndex == roleIndex &&
            fields.values.containsKey(field.id) &&
            !rawMarkerMemoryBook;
        if (fieldResolved) {
          resolved += fieldRunes;
          continue;
        }
        final checkpoint = chunks.values['role:$roleIndex:${field.id}'];
        if (checkpoint != null &&
            checkpoint.field == field.id &&
            checkpoint.matchesSource(field.id, field.source)) {
          resolved += resolvedRunesForCheckpoint(checkpoint);
        }
      }
    }

    final openingRunes = source.initialOpening.runes.length;
    if (partial.openingCompleted) {
      resolved += openingRunes;
    } else if (partial.completedRoleCount == source.results.length) {
      final fieldResolved = fields.scope == 'opening' &&
          fields.roleIndex == source.results.length &&
          fields.values.containsKey('openingMessage');
      if (fieldResolved) {
        resolved += openingRunes;
      } else {
        final checkpoint = chunks.values['opening:openingMessage'];
        if (checkpoint != null &&
            checkpoint.field == 'openingMessage' &&
            checkpoint.matchesSource(
              'openingMessage',
              source.initialOpening,
            )) {
          resolved += resolvedRunesForCheckpoint(checkpoint);
        }
      }
    }

    return TranslationWorkEstimate(
      totalRunes: totalRunes,
      resolvedRunes: resolved,
      usedFallback: false,
    );
  }

  StoryRoomTemplatePayload? _decodeTaskSource(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final payload = StoryRoomTemplatePayload.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return payload.results.isEmpty ? null : payload;
    } catch (_) {
      return null;
    }
  }

  _PartialProgress _decodePartial(
    StoryTemplateTranslationTaskModel task,
    StoryRoomTemplatePayload source,
  ) {
    final raw = task.partialPayload.trim();
    if (raw.isEmpty) return const _PartialProgress();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const _PartialProgress();
      var completedRoleCount = 0;
      try {
        final results = StoryRoomTemplatePayload.fromJson(
          Map<String, dynamic>.from(decoded),
        ).results;
        if (results.length <= source.results.length &&
            results.length == task.roleIndex) {
          completedRoleCount = results.length;
        }
      } catch (_) {
        // 与 runner 一致：损坏的 partial role 快照被忽略。
      }
      return _PartialProgress(
        completedRoleCount: completedRoleCount,
        openingCompleted: decoded['_translationOpeningCompleted'] == true,
      );
    } catch (_) {
      return const _PartialProgress();
    }
  }

  _FieldProgress _decodeFields(String rawPayload) {
    final raw = rawPayload.trim();
    if (raw.isEmpty) return const _FieldProgress();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['scope'] is! String ||
          decoded['roleIndex'] is! int ||
          decoded['fields'] is! Map) {
        return const _FieldProgress();
      }
      return _FieldProgress(
        scope: decoded['scope'] as String,
        roleIndex: decoded['roleIndex'] as int,
        values: {
          for (final entry in (decoded['fields'] as Map).entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        },
      );
    } catch (_) {
      return const _FieldProgress();
    }
  }

  _ChunkProgress _decodeTaskChunks(String rawPayload) {
    final raw = rawPayload.trim();
    if (raw.isEmpty) return const _ChunkProgress();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['checkpoints'] is! Map) {
        return const _ChunkProgress(failed: true);
      }
      final version = decoded['version'];
      if (version != null &&
          (version is! int ||
              version != TranslationChunkCheckpoint.currentVersion)) {
        return const _ChunkProgress(usedFallback: true);
      }
      return _ChunkProgress(values: {
        for (final entry in (decoded['checkpoints'] as Map).entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: TranslationChunkCheckpoint.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      });
    } catch (_) {
      return const _ChunkProgress(failed: true);
    }
  }
}

String formatRuneProgress(int completedRunes, int totalRunes) {
  final safeTotal = totalRunes < 0 ? 0 : totalRunes;
  final safeCompleted = completedRunes.clamp(0, safeTotal);
  return '已完成 ${_formatInteger(safeCompleted)}/${_formatInteger(safeTotal)} 字';
}

String _formatInteger(int value) => value.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );

final class _PartialProgress {
  final int completedRoleCount;
  final bool openingCompleted;

  const _PartialProgress({
    this.completedRoleCount = 0,
    this.openingCompleted = false,
  });
}

final class _FieldProgress {
  final String scope;
  final int roleIndex;
  final Map<String, String> values;

  const _FieldProgress({
    this.scope = '',
    this.roleIndex = -1,
    this.values = const {},
  });
}

final class _ChunkProgress {
  final Map<String, TranslationChunkCheckpoint> values;
  final bool usedFallback;
  final bool failed;

  const _ChunkProgress({
    this.values = const {},
    this.usedFallback = false,
    this.failed = false,
  });
}
