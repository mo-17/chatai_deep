import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar_preset_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool isSelected(WidgetTester tester, String key) =>
      tester.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

  testWidgets('assistant avatar preset picker reports stable ids and Emoji',
      (tester) async {
    final selected = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssistantAvatarPresetPicker(
            selectedAssetId: null,
            emojiSelected: true,
            onSelected: selected.add,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-creator')),
    );
    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-emoji')),
    );

    expect(
      selected,
      const [
        StarcoreIconAssets.assistantExplorerId,
        StarcoreIconAssets.assistantCreatorId,
        null,
      ],
    );
  });

  testWidgets('local image mode leaves every avatar preset unselected',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssistantAvatarPresetPicker(
            selectedAssetId: null,
            emojiSelected: false,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(isSelected(tester, 'assistant-avatar-preset-emoji'), isFalse);
    expect(isSelected(tester, 'assistant-avatar-preset-explorer'), isFalse);
    expect(isSelected(tester, 'assistant-avatar-preset-creator'), isFalse);
  });

  testWidgets('Emoji mode selects only the Emoji preset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssistantAvatarPresetPicker(
            selectedAssetId: null,
            emojiSelected: true,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(isSelected(tester, 'assistant-avatar-preset-emoji'), isTrue);
    expect(isSelected(tester, 'assistant-avatar-preset-explorer'), isFalse);
    expect(isSelected(tester, 'assistant-avatar-preset-creator'), isFalse);
  });

  testWidgets('asset mode selects only its matching preset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssistantAvatarPresetPicker(
            selectedAssetId: StarcoreIconAssets.assistantCreatorId,
            emojiSelected: false,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(isSelected(tester, 'assistant-avatar-preset-emoji'), isFalse);
    expect(isSelected(tester, 'assistant-avatar-preset-explorer'), isFalse);
    expect(isSelected(tester, 'assistant-avatar-preset-creator'), isTrue);
  });
}
