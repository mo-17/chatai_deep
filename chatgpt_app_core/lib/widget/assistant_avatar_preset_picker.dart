import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:flutter/material.dart';

class AssistantAvatarPresetPicker extends StatelessWidget {
  final String? selectedAssetId;
  final bool emojiSelected;
  final ValueChanged<String?> onSelected;

  const AssistantAvatarPresetPicker({
    super.key,
    required this.selectedAssetId,
    required this.emojiSelected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            key: const ValueKey('assistant-avatar-preset-emoji'),
            label: const Text('Emoji'),
            selected: emojiSelected,
            onSelected: (_) => onSelected(null),
          ),
          ChoiceChip(
            key: const ValueKey('assistant-avatar-preset-explorer'),
            label: const Text('探索向导'),
            selected: selectedAssetId == StarcoreIconAssets.assistantExplorerId,
            onSelected: (_) =>
                onSelected(StarcoreIconAssets.assistantExplorerId),
          ),
          ChoiceChip(
            key: const ValueKey('assistant-avatar-preset-creator'),
            label: const Text('创作搭档'),
            selected: selectedAssetId == StarcoreIconAssets.assistantCreatorId,
            onSelected: (_) =>
                onSelected(StarcoreIconAssets.assistantCreatorId),
          ),
        ],
      );
}
