import 'dart:async';
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
    final timeout = Stopwatch()..start();
    while (await file.exists()) {
      if (timeout.elapsed > const Duration(seconds: 2)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return true;
  }

  Future<bool> pumpUntilDeleted(WidgetTester tester, File file) async {
    final timeout = Stopwatch()..start();
    while (file.existsSync()) {
      if (timeout.elapsed > const Duration(seconds: 2)) return false;
      await tester.runAsync(file.exists);
      await tester.pump();
    }
    return true;
  }

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    final timeout = Stopwatch()..start();
    while (finder.evaluate().isEmpty) {
      if (timeout.elapsed > const Duration(seconds: 2)) {
        fail('Timed out waiting for $finder');
      }
      await tester.runAsync(
        () => Future<void>.delayed(Duration.zero),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
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
          theme: theme.copyWith(splashFactory: NoSplash.splashFactory),
          initialRoute: '/edit',
          routes: {
            '/': (_) => const Scaffold(body: Text('assistant-list')),
            '/edit': (_) => AssistantEditPage(
                  assistant: assistant,
                  saveAssistant: saveAssistant,
                ),
          },
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

  testWidgets(
      'selecting a preset defers old managed image cleanup until save succeeds',
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

    final persistenceCompleted = Completer<void>();
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
      saveAssistant: (_) {
        expect(image.existsSync(), isTrue);
        persistenceCompleted.complete();
        return Future<void>.value();
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    await tester.pump();
    expect(await tester.runAsync(image.exists), isTrue);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(persistenceCompleted.isCompleted, isTrue);
    expect(await pumpUntilDeleted(tester, image), isTrue);
    await pumpUntilFound(tester, find.text('assistant-list'));

    expect(find.text('assistant-list'), findsOneWidget);
    expect(await tester.runAsync(image.exists), isFalse);
  });

  testWidgets('selecting a preset then going back preserves the old image',
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
        id: 12,
        name: '取消测试',
        emoji: '🤖',
        avatarType: AvatarAssetService.imageType,
        avatarValue: image.path,
      ),
      saveAssistant: (_) async {},
    );

    final preset = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    final deletedBeforeCancel = await tester.runAsync(() async {
      preset.onSelected!(true);
      return waitForDeletion(image);
    });
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('assistant-list'), findsOneWidget);
    expect(deletedBeforeCancel, isFalse);
    expect(await tester.runAsync(image.exists), isTrue);
  });

  testWidgets('selecting a preset then save failure preserves the old image',
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
        id: 13,
        name: '失败测试',
        emoji: '🤖',
        avatarType: AvatarAssetService.imageType,
        avatarValue: image.path,
      ),
      saveAssistant: (_) => Future<void>.error(StateError('save failed')),
    );

    final preset = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    final deletedBeforeSave = await tester.runAsync(() async {
      preset.onSelected!(true);
      return waitForDeletion(image);
    });
    await tester.pump();

    expect(deletedBeforeSave, isFalse);
    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存修改'),
    );
    Object? saveError;
    await tester.runAsync(() async {
      final errorObserved = Completer<void>();
      runZonedGuarded<void>(
        saveButton.onPressed!,
        (error, _) {
          saveError = error;
          errorObserved.complete();
        },
      );
      await errorObserved.future;
    });
    await tester.pump();
    expect(saveError, isA<StateError>());
    expect(find.byType(AssistantEditPage), findsOneWidget);
    expect(await tester.runAsync(image.exists), isTrue);
  });
}
