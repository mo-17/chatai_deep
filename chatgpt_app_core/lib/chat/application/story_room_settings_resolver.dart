import 'package:chatgpt_app_core/chat/application/story_backend_generation_snapshot.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

class StoryRoomSettingsResolver {
  const StoryRoomSettingsResolver._();

  static AISettings apply(StoryRoomModel room, AISettings settings) {
    final next = settings.mode == AIMode.backend
        ? storyBackendLayer(settings, room.backendSelection, room.modelId)
        : settings.clone();
    next.webSearchEnabled = room.webSearchEnabled ?? settings.webSearchEnabled;
    final model = room.modelId ?? '';
    if (next.mode == AIMode.local) {
      final providerId = room.modelProviderId ?? '';
      if (providerId.isNotEmpty) {
        next.activeProviderId = providerId;
      }
      if (model.isNotEmpty) next.setLocalModelOverride(model);
    }
    if (room.temperature != null) next.temperature = room.temperature;
    if (room.topP != null) next.topP = room.topP!.clamp(0, 1).toDouble();
    if (room.maxOutputTokens != null) {
      next.maxOutputTokens = room.maxOutputTokens!.clamp(0, 200000).toInt();
    }
    return next;
  }
}
