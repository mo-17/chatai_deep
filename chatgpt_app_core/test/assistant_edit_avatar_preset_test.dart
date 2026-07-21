import 'dart:io';

import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<File> writeManagedAvatar(Directory root) async {
    final image = File('${root.path}/chat_avatar/test/avatar.png');
    await image.parent.create(recursive: true);
    final source = await File(
      StarcoreIconAssets.assistantExplorer,
    ).readAsBytes();
    await image.writeAsBytes(
      source,
    );
    return image;
  }

  Future<bool> waitForDeletion(File file) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (!await file.exists()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return false;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    required ThemeData theme,
    required AssistantModel assistant,
    required AssistantEditSaver saveAssistant,
  }) async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => Directory.systemTemp.path,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: AISettingsProvider(),
        child: MaterialApp(
          theme: theme,
          home: AssistantEditPage(
            assistant: assistant,
            saveAssistant: saveAssistant,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'assistant editor saves a Starcore preset without opening a picker',
      (tester) async {
    AssistantModel? saved;
    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(id: 7, name: '向导', emoji: '🤖'),
      saveAssistant: (assistant) async {
        saved = assistant;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    await tester.pump();
    expect(find.text('探索向导'), findsNWidgets(2));

    await tester.tap(find.text('保存修改'));
    await tester.pump();

    expect(saved?.avatarType, AvatarAssetService.assetType);
    expect(saved?.avatarValue, StarcoreIconAssets.assistantExplorerId);
  });

  testWidgets('editing Emoji explicitly clears a selected Starcore preset',
      (tester) async {
    AssistantModel? saved;
    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(id: 8, name: '创作者', emoji: '🤖'),
      saveAssistant: (assistant) async {
        saved = assistant;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-creator')),
    );
    await tester.pump();
    expect(find.text('创作搭档'), findsNWidgets(2));
    await tester.enterText(
      find.byKey(const ValueKey('assistant-avatar-emoji-field')),
      '🛰️',
    );
    await tester.tap(find.text('保存修改'));
    await tester.pump();

    expect(saved?.avatarType, isNull);
    expect(saved?.avatarValue, isNull);
    expect(saved?.emoji, '🛰️');
  });

  testWidgets('classic editor hides presets and preserves a stored asset id',
      (tester) async {
    AssistantModel? saved;
    await pumpEditor(
      tester,
      theme: AppThemeFactory.classic(Colors.blue),
      assistant: AssistantModel(
        id: 9,
        name: '向导',
        emoji: '🤖',
        avatarType: AvatarAssetService.assetType,
        avatarValue: StarcoreIconAssets.assistantExplorerId,
      ),
      saveAssistant: (assistant) async {
        saved = assistant;
      },
    );

    expect(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
      findsNothing,
    );
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.text('保存修改'));
    await tester.pump();

    expect(saved?.avatarType, AvatarAssetService.assetType);
    expect(saved?.avatarValue, StarcoreIconAssets.assistantExplorerId);
  });

  testWidgets('editing Emoji while using a local image does not delete it',
      (tester) async {
    late Directory root;
    late File image;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('assistant-avatar-test-');
      image = await writeManagedAvatar(root);
    });
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    AssistantModel? saved;

    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(
        id: 10,
        name: '本地头像',
        emoji: '🤖',
        avatarType: AvatarAssetService.imageType,
        avatarValue: image.path,
      ),
      saveAssistant: (assistant) async {
        saved = assistant;
      },
    );

    expect(find.text('图片头像'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('assistant-avatar-emoji-field')),
      '🚀',
    );
    await tester.tap(find.text('保存修改'));
    await tester.pump();

    expect(await tester.runAsync(image.exists), isTrue);
    expect(saved?.avatarType, AvatarAssetService.imageType);
    expect(saved?.avatarValue, image.path);
  });

  testWidgets('selecting a preset cleans up only the previous managed image',
      (tester) async {
    late Directory root;
    late File image;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('assistant-avatar-test-');
      image = await writeManagedAvatar(root);
    });
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(
        id: 11,
        name: '清理测试',
        emoji: '🤖',
        avatarType: AvatarAssetService.imageType,
        avatarValue: image.path,
      ),
      saveAssistant: (_) async {},
    );

    final preset = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    final deleted = await tester.runAsync(() async {
      preset.onSelected!(true);
      return waitForDeletion(image);
    });
    await tester.pump();

    expect(deleted, isTrue);
    expect(find.text('探索向导'), findsNWidgets(2));
  });
}
