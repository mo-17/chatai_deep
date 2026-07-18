import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';

final class TavernRoomImportBundle {
  final StoryTemplateModel outputTemplate;
  final StoryRoomModel room;
  final List<StoryParticipantModel> participants;
  final List<StoryMessageModel> messages;
  final bool hasRetainedOriginal;

  const TavernRoomImportBundle({
    required this.outputTemplate,
    required this.room,
    required this.participants,
    required this.messages,
    this.hasRetainedOriginal = false,
  });
}

final class TavernRoomImportCompletion {
  final int outputTemplateId;
  final int outputRoomId;

  const TavernRoomImportCompletion({
    required this.outputTemplateId,
    required this.outputRoomId,
  });
}

abstract final class TavernRoomImportFinalizer {
  static TavernRoomImportBundle build({
    required StoryRoomTemplatePayload payload,
    required String title,
    required String sourceTitle,
    required bool translated,
    bool hasRetainedOriginal = false,
  }) {
    if (payload.results.isEmpty) {
      throw const FormatException('酒馆房间导入缺少角色数据');
    }

    final outputTemplate = payload.toTemplate(
      title: title,
      sourceTitle: sourceTitle,
      translated: translated,
    );
    final plan = payload.results.length == 1
        ? StoryRoomRoleCardImporter.buildPlan(
            payload.results.single.assistant,
            roomId: 0,
            title: title,
            tavernMeta: payload.results.single.tavernMeta,
          )
        : StoryRoomRoleCardImporter.buildBatchPlan(
            payload.results,
            roomId: 0,
            title: title,
          );
    final room = plan.room;
    if (payload.promptConfigJson.trim().isNotEmpty) {
      room.promptConfigJson = payload.promptConfigJson;
    }
    if (payload.quickRepliesJson.trim().isNotEmpty) {
      room.quickRepliesJson = payload.quickRepliesJson;
    }
    if (payload.regexScriptsJson.trim().isNotEmpty) {
      room.regexScriptsJson = payload.regexScriptsJson;
    }
    if (payload.tavernPresetJson.trim().isNotEmpty) {
      room.tavernPresetJson = payload.tavernPresetJson;
    }
    room
      ..temperature = payload.temperature
      ..topP = payload.topP
      ..maxOutputTokens = payload.maxOutputTokens;

    final opening = payload.results.length == 1
        ? payload.initialOpening
        : payload.initialOpening.trim().isNotEmpty
            ? payload.initialOpening.trim()
            : StoryRoomRoleCardImporter.initialBatchSceneMessage(
                payload.results,
              );
    final messages = <StoryMessageModel>[
      if (opening.isNotEmpty)
        StoryMessageModel(
          roomId: 0,
          speakerRole: 'system',
          speakerName: '开场',
          content: opening,
        ),
    ];
    return TavernRoomImportBundle(
      outputTemplate: outputTemplate,
      room: room,
      participants: plan.participants,
      messages: messages,
      hasRetainedOriginal: hasRetainedOriginal,
    );
  }
}
