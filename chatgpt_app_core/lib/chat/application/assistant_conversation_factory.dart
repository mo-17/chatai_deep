import 'package:chatgpt_app_core/chat/application/assistant_conversation_avatar_resolver.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';

/// 从助手生成新会话的字段映射，供会话列表、角色卡导入后的启动入口复用。
class AssistantConversationFactory {
  static ConversationModel create({
    required int cid,
    required String icon,
    AssistantModel? assistant,
    int? projectId,
    String? modelProviderId,
    String? modelId,
    bool? webSearchEnabled,
    List<String>? toolIds,
  }) {
    final voiceStyle = assistant?.defaultVoiceStyle.trim();
    final avatar =
        AssistantConversationAvatarResolver.conversationAvatar(assistant);
    return ConversationModel(
      cid: cid,
      icon: icon,
      assistantId: assistant?.id,
      avatarType: avatar.$1,
      avatarValue: avatar.$2,
      projectId: projectId,
      modelProviderId: modelProviderId,
      modelId: modelId,
      voiceStyle: voiceStyle == null || voiceStyle.isEmpty ? null : voiceStyle,
      webSearchEnabled: webSearchEnabled,
      toolIds: toolIds,
    );
  }

  static String openingMessageOf(AssistantModel? assistant,
      {int candidateIndex = 0}) {
    final candidates = openingMessageCandidates(assistant);
    if (candidates.isEmpty) return '';
    final index = candidateIndex.clamp(0, candidates.length - 1);
    return candidates[index];
  }

  static List<String> openingMessageCandidates(AssistantModel? assistant) {
    if (assistant == null) return const [];
    final candidates = <String>[];
    final seen = <String>{};
    void add(String value) {
      final text = value.trim();
      if (text.isEmpty) return;
      final key = text.replaceAll(RegExp(r'\s+'), '');
      if (!seen.add(key)) return;
      candidates.add(text);
    }

    add(assistant.openingMessage);
    for (final greeting in AssistantRoleCardService.alternateGreetings(
      assistant.exampleDialogs,
    )) {
      add(greeting);
    }
    return candidates;
  }
}
