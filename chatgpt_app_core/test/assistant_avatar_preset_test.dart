import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar_preset_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('assistant avatar preset picker reports stable ids and Emoji',
      (tester) async {
    final selected = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssistantAvatarPresetPicker(
            selectedAssetId: null,
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
}
