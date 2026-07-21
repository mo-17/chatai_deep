import 'dart:io';

import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/assistant_avatar_bytes.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class TestAssetBundle extends CachingAssetBundle {
  TestAssetBundle(this.assets);

  final Map<String, List<int>> assets;
  final List<String> loadedKeys = [];

  @override
  Future<ByteData> load(String key) async {
    loadedKeys.add(key);
    final bytes = assets[key];
    if (bytes == null) throw FlutterError('Missing test asset: $key');
    return Uint8List.fromList(bytes).buffer.asByteData();
  }
}

class ThrowingAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('Simulated package asset load failure: $key');
  }
}

void main() {
  test('reads approved Starcore asset from the package-qualified bundle key',
      () async {
    const key =
        'packages/chatgpt_app_core/assets/icons/starcore/assistant-explorer.png';
    final bundle = TestAssetBundle({
      key: [1, 2, 3, 4]
    });
    final assistant = AssistantModel(
      name: '向导',
      avatarType: AvatarAssetService.assetType,
      avatarValue: StarcoreIconAssets.assistantExplorerId,
    );

    final bytes = await AssistantAvatarBytes.read(assistant, bundle: bundle);

    expect(bytes, [1, 2, 3, 4]);
    expect(bundle.loadedKeys, [key]);
  });

  test('reads a valid local image file', () async {
    final dir =
        await Directory.systemTemp.createTemp('assistant_avatar_bytes_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/avatar.png');
    await file.writeAsBytes([9, 8, 7]);
    final assistant = AssistantModel(
      name: '本地头像',
      avatarType: AvatarAssetService.imageType,
      avatarValue: file.path,
    );

    expect(await AssistantAvatarBytes.read(assistant), [9, 8, 7]);
  });

  test('rejects an unknown asset id without loading the bundle', () async {
    final bundle = TestAssetBundle(const {});
    final assistant = AssistantModel(
      name: '未知头像',
      avatarType: AvatarAssetService.assetType,
      avatarValue: 'starcore_unknown',
    );

    expect(await AssistantAvatarBytes.read(assistant, bundle: bundle), isNull);
    expect(bundle.loadedKeys, isEmpty);
  });

  test('returns null for an absent local image', () async {
    final assistant = AssistantModel(
      name: '缺失头像',
      avatarType: AvatarAssetService.imageType,
      avatarValue: '/definitely/missing/avatar.png',
    );

    expect(await AssistantAvatarBytes.read(assistant), isNull);
  });

  test('returns null when an approved package asset fails to load', () async {
    final assistant = AssistantModel(
      name: '损坏的内置头像',
      avatarType: AvatarAssetService.assetType,
      avatarValue: StarcoreIconAssets.assistantExplorerId,
    );

    expect(
      await AssistantAvatarBytes.read(
        assistant,
        bundle: ThrowingAssetBundle(),
      ),
      isNull,
    );
  });

  test('returns null when an existing local avatar cannot be read', () async {
    final dir =
        await Directory.systemTemp.createTemp('assistant_avatar_unreadable_');
    final file = File('${dir.path}/avatar.png');
    await file.writeAsBytes([1, 2, 3]);
    final chmod = await Process.run('chmod', ['000', file.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr as String?);
    addTearDown(() async {
      await Process.run('chmod', ['600', file.path]);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final assistant = AssistantModel(
      name: '不可读本地头像',
      avatarType: AvatarAssetService.imageType,
      avatarValue: file.path,
    );

    expect(await AssistantAvatarBytes.read(assistant), isNull);
  },
      skip: Platform.isWindows
          ? 'chmod-based read failure requires POSIX'
          : false);
}
