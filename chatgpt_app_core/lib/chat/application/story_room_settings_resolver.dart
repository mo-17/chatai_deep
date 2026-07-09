import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

class StoryRoomSettingsResolver {
  const StoryRoomSettingsResolver._();

  static AISettings apply(StoryRoomModel room, AISettings settings) {
    final next = settings.clone();
    final model = room.modelId?.trim() ?? '';
    if (next.mode == AIMode.backend) {
      if (model.isNotEmpty) next.backendModel = model;
    } else {
      final providerId = room.modelProviderId?.trim() ?? '';
      if (providerId.isNotEmpty &&
          next.enabledProviders.any((provider) => provider.id == providerId)) {
        next.activeProviderId = providerId;
      }
      if (model.isNotEmpty) next.setActiveModel(model);
    }
    if (room.temperature != null) next.temperature = room.temperature;
    if (room.maxOutputTokens != null) {
      next.maxOutputTokens = room.maxOutputTokens!.clamp(0, 200000).toInt();
    }
    return next;
  }
}
