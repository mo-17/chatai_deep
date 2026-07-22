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

class _FakeImagePickerChannel {
  final List<String> _results;
  int callCount = 0;

  _FakeImagePickerChannel(this._results);

  Future<Object?> handle(MethodCall call) async {
    if (call.method != 'pickImage') {
      throw PlatformException(
        code: 'unsupported_test_method',
        message: call.method,
      );
    }
    final result = _results[callCount];
    callCount += 1;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<File> writeAvatar(
    Directory root, {
    required String relativePath,
  }) async {
    final image = File('${root.path}/$relativePath');
    await image.parent.create(recursive: true);
    final source = await File(
      StarcoreIconAssets.assistantExplorer,
    ).readAsBytes();
    await image.writeAsBytes(
      source,
    );
    return image;
  }

  Future<File> writeManagedAvatar(
    Directory root, {
    String filename = 'avatar.png',
  }) =>
      writeAvatar(
        root,
        relativePath: 'chat_avatar/test/$filename',
      );

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

  Finder saveButtonFinder() => find.ancestor(
        of: find.text('保存修改'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );

  String? previewImagePath(WidgetTester tester) {
    final preview = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == '助手头像预览',
    );
    final imageFinder = find.descendant(
      of: preview,
      matching: find.byType(Image),
    );
    if (imageFinder.evaluate().length != 1) return null;
    ImageProvider provider = tester.widget<Image>(imageFinder).image;
    if (provider is ResizeImage) provider = provider.imageProvider;
    return provider is FileImage ? provider.file.path : null;
  }

  Future<String> pumpUntilPreviewChanges(
    WidgetTester tester, {
    required bool Function(String path) matches,
  }) async {
    final timeout = Stopwatch()..start();
    while (true) {
      final path = previewImagePath(tester);
      if (path != null && matches(path)) return path;
      if (timeout.elapsed > const Duration(seconds: 2)) {
        fail('Timed out waiting for assistant avatar preview path');
      }
      await tester.runAsync(
        () => Future<void>.delayed(Duration.zero),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  _FakeImagePickerChannel useImagePicker(
    WidgetTester tester,
    List<String> paths,
  ) {
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    final fake = _FakeImagePickerChannel(paths);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      fake.handle,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    return fake;
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  setUp(() async {
    AvatarAssetService.debugDocumentsDirectoryResolver = null;
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
    expect(
      await pumpUntilPreviewChanges(
        tester,
        matches: (path) => path == image.path,
      ),
      image.path,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('assistant-avatar-preset-emoji')),
          )
          .selected,
      isFalse,
    );
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

  testWidgets('default avatar mode selects the Emoji preset', (tester) async {
    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(id: 18, name: '默认头像', emoji: '🤖'),
      saveAssistant: (_) async {},
    );

    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('assistant-avatar-preset-emoji')),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('asset avatar mode selects its matching preset', (tester) async {
    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(
        id: 19,
        name: '创作头像',
        emoji: '🤖',
        avatarType: AvatarAssetService.assetType,
        avatarValue: StarcoreIconAssets.assistantCreatorId,
      ),
      saveAssistant: (_) async {},
    );

    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('assistant-avatar-preset-emoji')),
          )
          .selected,
      isFalse,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('assistant-avatar-preset-creator')),
          )
          .selected,
      isTrue,
    );
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

    final persistenceStarted = Completer<void>();
    final releasePersistence = Completer<void>();
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
      saveAssistant: (_) async {
        expect(image.existsSync(), isTrue);
        persistenceStarted.complete();
        await releasePersistence.future;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('assistant-avatar-preset-explorer')),
    );
    await tester.pump();
    expect(await tester.runAsync(image.exists), isTrue);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(persistenceStarted.isCompleted, isTrue);
    expect(await tester.runAsync(image.exists), isTrue);

    releasePersistence.complete();
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

    var saveCalled = false;
    final expectedError = StateError('save failed');
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
      saveAssistant: (_) {
        saveCalled = true;
        return Future<void>.error(expectedError);
      },
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
    expect(saveButtonFinder(), findsOneWidget);
    final saveButton = tester.widget<FilledButton>(saveButtonFinder());
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
    expect(saveCalled, isTrue);
    expect(saveError, same(expectedError));
    expect(find.byType(AssistantEditPage), findsOneWidget);
    expect(await tester.runAsync(image.exists), isTrue);
  });

  testWidgets('removing a managed image deletes it only after save succeeds',
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
        id: 14,
        name: '删除测试',
        avatarType: AvatarAssetService.imageType,
        avatarValue: image.path,
      ),
      saveAssistant: (assistant) async => saved = assistant,
    );

    await tapVisible(tester, find.text('删除图片'));
    await tester.pump();
    expect(await tester.runAsync(image.exists), isTrue);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(await pumpUntilDeleted(tester, image), isTrue);

    expect(saved?.avatarType, isNull);
    expect(saved?.avatarValue, isNull);
  });

  testWidgets('replacing a managed image deletes only the old image after save',
      (tester) async {
    late Directory root;
    late File oldImage;
    late File sourceImage;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('assistant-avatar-test-');
      oldImage = await writeManagedAvatar(root, filename: 'old.png');
      sourceImage = await writeAvatar(root, relativePath: 'picked/new.png');
    });
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => root;
    addTearDown(() async {
      AvatarAssetService.debugDocumentsDirectoryResolver = null;
      if (await root.exists()) await root.delete(recursive: true);
    });
    final picker = useImagePicker(tester, [sourceImage.path]);
    AssistantModel? saved;

    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(
        id: 15,
        name: '替换测试',
        avatarType: AvatarAssetService.imageType,
        avatarValue: oldImage.path,
      ),
      saveAssistant: (assistant) async => saved = assistant,
    );

    await tapVisible(tester, find.text('更换图片'));
    final replacementPath = await pumpUntilPreviewChanges(
      tester,
      matches: (path) => path != oldImage.path,
    );
    expect(picker.callCount, 1);
    expect(await tester.runAsync(oldImage.exists), isTrue);
    expect(await tester.runAsync(() => File(replacementPath).exists()), isTrue);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(await pumpUntilDeleted(tester, oldImage), isTrue);

    expect(saved?.avatarType, AvatarAssetService.imageType);
    expect(saved?.avatarValue, replacementPath);
    expect(await tester.runAsync(() => File(replacementPath).exists()), isTrue);
  });

  testWidgets('a queued obsolete path is retained when selected as final image',
      (tester) async {
    late Directory root;
    late File originalImage;
    late File sourceImage;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('assistant-avatar-test-');
      originalImage = await writeManagedAvatar(root, filename: 'original.png');
      sourceImage = await writeAvatar(root, relativePath: 'picked/new.png');
    });
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => root;
    addTearDown(() async {
      AvatarAssetService.debugDocumentsDirectoryResolver = null;
      if (await root.exists()) await root.delete(recursive: true);
    });
    final picker = useImagePicker(
      tester,
      [sourceImage.path, originalImage.path],
    );
    AssistantModel? saved;

    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(
        id: 16,
        name: '保留测试',
        avatarType: AvatarAssetService.imageType,
        avatarValue: originalImage.path,
      ),
      saveAssistant: (assistant) async => saved = assistant,
    );

    await tapVisible(tester, find.text('更换图片'));
    final replacementPath = await pumpUntilPreviewChanges(
      tester,
      matches: (path) => path != originalImage.path,
    );
    await tapVisible(tester, find.text('更换图片'));
    await pumpUntilPreviewChanges(
      tester,
      matches: (path) => path == originalImage.path,
    );
    expect(picker.callCount, 2);

    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(
      await pumpUntilDeleted(tester, File(replacementPath)),
      isTrue,
    );

    expect(saved?.avatarType, AvatarAssetService.imageType);
    expect(saved?.avatarValue, originalImage.path);
    expect(await tester.runAsync(originalImage.exists), isTrue);
  });

  testWidgets('a non-managed image path is never deleted after save',
      (tester) async {
    late Directory root;
    late File image;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('assistant-avatar-test-');
      image = await writeAvatar(root, relativePath: 'external/avatar.png');
    });
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    AssistantModel? saved;

    await pumpEditor(
      tester,
      theme: AppThemeFactory.anime(),
      assistant: AssistantModel(
        id: 17,
        name: '外部路径测试',
        avatarType: AvatarAssetService.imageType,
        avatarValue: image.path,
      ),
      saveAssistant: (assistant) async => saved = assistant,
    );

    await tapVisible(tester, find.text('删除图片'));
    await tester.pump();
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('assistant-list'));

    expect(saved?.avatarType, isNull);
    expect(saved?.avatarValue, isNull);
    expect(await tester.runAsync(image.exists), isTrue);
  });
}
