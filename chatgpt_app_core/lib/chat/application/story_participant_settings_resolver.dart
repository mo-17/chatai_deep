import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

/// 把角色快照的可选覆盖叠加到已经解析过房间设置的 [AISettings] 上。
///
/// 房间设置仍然是每次调度和生成的基准；角色只覆盖自己实际填写的字段。
class StoryParticipantSettingsResolver {
  const StoryParticipantSettingsResolver._();

  static AISettings apply(
    AISettings roomSettings,
    StoryParticipantModel participant,
  ) {
    final next = roomSettings.clone();
    final model = participant.modelId?.trim() ?? '';
    if (next.mode == AIMode.backend) {
      if (model.isNotEmpty) next.backendModel = model;
    } else {
      final providerId = participant.modelProviderId?.trim() ?? '';
      if (providerId.isNotEmpty &&
          next.enabledProviders.any((provider) => provider.id == providerId)) {
        next.activeProviderId = providerId;
      }
      if (model.isNotEmpty) next.setActiveModel(model);
    }
    if (participant.temperature != null) {
      next.temperature = participant.temperature!.clamp(0, 2).toDouble();
    }
    if (participant.maxOutputTokens != null) {
      next.maxOutputTokens =
          participant.maxOutputTokens!.clamp(0, 200000).toInt();
    }
    return next;
  }
}
