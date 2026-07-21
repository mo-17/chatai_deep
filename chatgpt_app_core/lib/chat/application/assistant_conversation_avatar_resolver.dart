import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';

/// 助手头像到会话字段与消息协议的统一映射。
abstract final class AssistantConversationAvatarResolver {
  static (String?, String?) conversationAvatar(AssistantModel? assistant) {
    if (assistant == null) return (null, null);
    if (assistant.avatarType == AvatarAssetService.assetType &&
        StarcoreIconAssets.assistantAssetFor(assistant.avatarValue) != null) {
      return (AvatarAssetService.assetType, assistant.avatarValue!.trim());
    }
    if (assistant.avatarType == AvatarAssetService.imageType) {
      final value = assistant.avatarValue?.trim() ?? '';
      if (value.isNotEmpty) return (AvatarAssetService.imageType, value);
    }
    final emoji = assistant.emoji.trim();
    return emoji.isEmpty ? (null, null) : ('emoji', emoji);
  }

  static String? nextMessageAvatar(AssistantModel? assistant) {
    if (assistant == null) return null;
    if (assistant.avatarType == AvatarAssetService.assetType) {
      final protocol =
          StarcoreIconAssets.messageAvatarFor(assistant.avatarValue);
      if (protocol != null) return protocol;
    }
    if (assistant.avatarType == AvatarAssetService.imageType) {
      final value = assistant.avatarValue?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    final emoji = assistant.emoji.trim();
    return emoji.isEmpty ? null : 'emoji:${Uri.encodeComponent(emoji)}';
  }

  static void applySwitch(
    ConversationModel conversation,
    AssistantModel? assistant,
  ) {
    conversation.assistantId = assistant?.id;
    final avatar = conversationAvatar(assistant);
    conversation.avatarType = avatar.$1;
    conversation.avatarValue = avatar.$2;
    final assistantVoice = assistant?.defaultVoiceStyle.trim() ?? '';
    if (assistantVoice.isNotEmpty) {
      conversation.voiceStyle = assistantVoice;
    }
  }
}
