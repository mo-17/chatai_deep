import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
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
  });
}

typedef TavernRoomImportProgressCallback = void Function(
  TavernRoomImportProgress progress,
);

class TavernRoomImportPreparer {
  const TavernRoomImportPreparer._();

  static Future<List<AssistantRoleCardImportResult>> prepare(
    List<AssistantRoleCardImportResult> results, {
    required bool translateToSimplifiedChinese,
    required RoleCardTranslationCall complete,
    TavernRoomImportProgressCallback? onProgress,
  }) async {
    if (!translateToSimplifiedChinese) return results;
    final translated = <AssistantRoleCardImportResult>[];
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
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
        )),
      );
      final protectedAssistant = _protectMemoryBookParticipants(
        source: result.assistant,
        translated: assistant,
        onProgress: onProgress,
        current: i + 1,
        total: results.length,
      );
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

  static int _participantCount(String memoryBook) {
    return StoryRoomRoleCardImporter.parseMemoryBookParticipants(
      memoryBook,
      roomId: 0,
    ).length;
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
