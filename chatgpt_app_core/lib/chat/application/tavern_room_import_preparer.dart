import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

class TavernRoomImportProgress {
  final int current;
  final int total;
  final String name;
  final String stage;
  final String detail;
  final int fieldCurrent;
  final int fieldTotal;
  final String fieldLabel;
  final double fieldProgress;
  final int? completedRunes;
  final int? totalRunes;

  const TavernRoomImportProgress({
    required this.current,
    required this.total,
    required this.name,
    required this.stage,
    this.detail = '',
    this.fieldCurrent = 0,
    this.fieldTotal = 0,
    this.fieldLabel = '',
    this.fieldProgress = 0,
    this.completedRunes,
    this.totalRunes,
  });
}

typedef TavernRoomImportProgressCallback = void Function(
  TavernRoomImportProgress progress,
);
typedef TavernRoomImportFieldCheckpoint = Future<void> Function(
  int resultIndex,
  String field,
  String value,
);
typedef TavernRoomImportChunkCheckpoint = Future<void> Function(
  String checkpointKey,
  TranslationChunkCheckpoint checkpoint,
);

class TavernRoomImportPreparer {
  const TavernRoomImportPreparer._();

  static Future<List<AssistantRoleCardImportResult>> prepare(
    List<AssistantRoleCardImportResult> results, {
    required bool translateToSimplifiedChinese,
    required RoleCardTranslationCall complete,
    TavernRoomImportProgressCallback? onProgress,
    Map<int, Map<String, String>> initialTranslatedFields = const {},
    TavernRoomImportFieldCheckpoint? onFieldCheckpoint,
    Map<String, TranslationChunkCheckpoint> initialChunkCheckpoints = const {},
    TavernRoomImportChunkCheckpoint? onChunkCheckpoint,
    TranslationRetryPolicy retryPolicy = const TranslationRetryPolicy(),
  }) async {
    if (!translateToSimplifiedChinese) return results;
    final translated = <AssistantRoleCardImportResult>[];
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      final roleChunkCheckpoints = _chunkCheckpointsForRole(
        i,
        initialChunkCheckpoints,
      );
      final usesChunkPipeline =
          roleChunkCheckpoints.isNotEmpty || onChunkCheckpoint != null;
      final latestChunkCheckpoints =
          Map<String, TranslationChunkCheckpoint>.of(roleChunkCheckpoints);
      var hasPendingMemoryBookFieldCheckpoint = false;
      var pendingMemoryBookFieldCheckpoint = '';
      onProgress?.call(TavernRoomImportProgress(
        current: i + 1,
        total: results.length,
        name: result.assistant.name,
        stage: '准备翻译角色',
      ));
      final assistant = await AssistantRoleCardTranslationService
          .translateToSimplifiedChinese(
        result.assistant,
        complete: complete,
        initialTranslatedFields: initialTranslatedFields[i] ?? const {},
        onFieldCheckpoint: onFieldCheckpoint == null
            ? null
            : (field, value) async {
                if (usesChunkPipeline && field == 'memoryBook') {
                  hasPendingMemoryBookFieldCheckpoint = true;
                  pendingMemoryBookFieldCheckpoint = value;
                  return;
                }
                await onFieldCheckpoint(i, field, value);
              },
        initialChunkCheckpoints: roleChunkCheckpoints,
        onChunkCheckpoint: !usesChunkPipeline
            ? null
            : (field, checkpoint) async {
                latestChunkCheckpoints[field] = checkpoint;
                await onChunkCheckpoint?.call('$i:$field', checkpoint);
              },
        retryPolicy: retryPolicy,
        onProgress: (value) => onProgress?.call(TavernRoomImportProgress(
          current: i + 1,
          total: results.length,
          name: result.assistant.name,
          stage: value.stage,
          detail: value.detail,
          fieldCurrent: value.current,
          fieldTotal: value.total,
          fieldLabel: value.fieldLabel,
          fieldProgress: value.fieldProgress,
          completedRunes: value.completedRunes,
          totalRunes: value.totalRunes,
        )),
      );
      late final AssistantModel protectedAssistant;
      if (usesChunkPipeline) {
        await _pauseOnChunkParticipantLoss(
          resultIndex: i,
          source: result.assistant,
          translated: assistant,
          latestMemoryBookCheckpoint: latestChunkCheckpoints['memoryBook'],
          onChunkCheckpoint: onChunkCheckpoint,
        );
        if (hasPendingMemoryBookFieldCheckpoint) {
          await onFieldCheckpoint?.call(
            i,
            'memoryBook',
            pendingMemoryBookFieldCheckpoint,
          );
        }
        protectedAssistant = assistant;
      } else {
        protectedAssistant = _protectMemoryBookParticipants(
          source: result.assistant,
          translated: assistant,
          onProgress: onProgress,
          current: i + 1,
          total: results.length,
        );
      }
      translated.add(AssistantRoleCardImportResult(
        assistant: protectedAssistant,
        avatarPngBytes: result.avatarPngBytes,
        avatarExtension: result.avatarExtension,
        resources: result.resources,
        sourceName: result.sourceName,
        tavernMeta:
            result.tavernMeta?.syncTranslatedOpenings(protectedAssistant),
      ));
      onProgress?.call(TavernRoomImportProgress(
        current: i + 1,
        total: results.length,
        name: protectedAssistant.name,
        stage: '已翻译',
      ));
    }
    return translated;
  }

  static Map<String, TranslationChunkCheckpoint> _chunkCheckpointsForRole(
    int resultIndex,
    Map<String, TranslationChunkCheckpoint> checkpoints,
  ) {
    final prefix = '$resultIndex:';
    return {
      for (final entry in checkpoints.entries)
        if (entry.key.startsWith(prefix) &&
            entry.key.length > prefix.length &&
            entry.value.field == entry.key.substring(prefix.length))
          entry.value.field: entry.value,
    };
  }

  static int _participantCount(String memoryBook) {
    return StoryRoomRoleCardImporter.parseMemoryBookParticipants(
      memoryBook,
      roomId: 0,
    ).length;
  }

  static Future<void> _pauseOnChunkParticipantLoss({
    required int resultIndex,
    required AssistantModel source,
    required AssistantModel translated,
    required TranslationChunkCheckpoint? latestMemoryBookCheckpoint,
    required TavernRoomImportChunkCheckpoint? onChunkCheckpoint,
  }) async {
    final before = _participantCount(source.memoryBook);
    if (before <= 1 || _participantCount(translated.memoryBook) >= before) {
      return;
    }
    final checkpoint = latestMemoryBookCheckpoint;
    if (checkpoint != null && checkpoint.field == 'memoryBook') {
      final retryable = TranslationChunkCheckpoint(
        field: checkpoint.field,
        sourceHash: checkpoint.sourceHash,
        chunks: [
          for (final state in checkpoint.chunks)
            state.status == TranslationChunkStatus.retainedOriginal
                ? state
                : TranslationChunkState(
                    chunk: state.chunk,
                    status: TranslationChunkStatus.pending,
                    translatedText: '',
                    attempts: state.attempts,
                    lastErrorKind: TranslationFailureKind.invalidOutput,
                  ),
        ],
      );
      await onChunkCheckpoint?.call(
        '$resultIndex:memoryBook',
        retryable,
      );
    }
    throw const TranslationWorkPaused(
      failure: TranslationRequestFailure(
        kind: TranslationFailureKind.invalidOutput,
        safeCode: 'invalid_translation_participants',
      ),
    );
  }

  static AssistantModel _protectMemoryBookParticipants({
    required AssistantModel source,
    required AssistantModel translated,
    required TavernRoomImportProgressCallback? onProgress,
    required int current,
    required int total,
  }) {
    final before = _participantCount(source.memoryBook);
    if (before <= 1) return translated;
    final after = _participantCount(translated.memoryBook);
    if (after >= before) return translated;
    translated.memoryBook = source.memoryBook;
    onProgress?.call(TavernRoomImportProgress(
      current: current,
      total: total,
      name: translated.name,
      stage: '世界书角色数减少，已回退原文',
      detail: '$before -> $after',
      fieldLabel: '世界书',
      fieldCurrent: 6,
      fieldTotal: 6,
    ));
    return translated;
  }
}
