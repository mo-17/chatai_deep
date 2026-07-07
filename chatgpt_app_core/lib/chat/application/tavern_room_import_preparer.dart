import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';

class TavernRoomImportProgress {
  final int current;
  final int total;
  final String name;
  final String stage;
  final String detail;
  final int fieldCurrent;
  final int fieldTotal;
  final String fieldLabel;

  const TavernRoomImportProgress({
    required this.current,
    required this.total,
    required this.name,
    required this.stage,
    this.detail = '',
    this.fieldCurrent = 0,
    this.fieldTotal = 0,
    this.fieldLabel = '',
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
        )),
      );
      translated.add(AssistantRoleCardImportResult(
        assistant: assistant,
        avatarPngBytes: result.avatarPngBytes,
        sourceName: result.sourceName,
        tavernMeta: result.tavernMeta?.syncTranslatedOpenings(assistant),
      ));
      onProgress?.call(TavernRoomImportProgress(
        current: i + 1,
        total: results.length,
        name: assistant.name,
        stage: '已翻译',
      ));
    }
    return translated;
  }
}
