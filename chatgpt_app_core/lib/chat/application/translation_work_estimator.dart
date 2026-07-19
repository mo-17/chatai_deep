import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/role_card_translation_fields.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

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
    try {
      final decoded = jsonDecode(sourcePayload);
      if (decoded is! Map) return null;
      final payload = StoryRoomTemplatePayload.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return totalRunesForResults(
        payload.results,
        initialOpening: payload.initialOpening,
      );
    } catch (_) {
      return null;
    }
  }
}
