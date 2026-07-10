import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('role-card-assets-');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('CHARX 资源保存为托管文件并可恢复导出字节', () async {
    final manifest = await AssistantRoleCardAssetStore.save(
      assistantId: 7,
      directoryResolver: () async => tempDir,
      resources: [
        AssistantRoleCardResource(
          type: 'background',
          uri: 'embeded://assets/background/moon.webp',
          name: '../moon',
          ext: 'webp',
          archivePath: 'assets/background/moon.webp',
          mimeType: 'image/webp',
          size: 3,
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ],
    );
    final resources = await AssistantRoleCardAssetStore.load(manifest);

    expect(resources, hasLength(1));
    expect(resources.single.type, 'background');
    expect(resources.single.bytes, [1, 2, 3]);
    expect(
      resources.single.archivePath,
      'assets/background/moon.webp',
    );

    await AssistantRoleCardAssetStore.delete(
      assistantId: 7,
      directoryResolver: () async => tempDir,
    );
    expect(
      Directory(
        '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/7',
      ).existsSync(),
      isFalse,
    );
  });

  test('助手 JSON 往返保留 CHARX 托管清单', () {
    const manifest = '[{"type":"audio","localPath":"/tmp/a.ogg"}]';
    final restored = AssistantModel.fromJson(
      AssistantModel(name: '角色', roleCardAssets: manifest).toJson(),
    );
    expect(restored.roleCardAssets, manifest);
  });

  test('iOS 容器路径变化后按托管目录后缀重定位', () async {
    final target = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/9/voice.ogg',
    );
    await target.parent.create(recursive: true);
    await target.writeAsBytes([4, 5, 6]);
    const manifest = '[{"type":"audio","name":"voice","ext":"ogg",'
        '"localPath":"/old/container/assistant_role_assets/9/voice.ogg"}]';

    final resources = await AssistantRoleCardAssetStore.load(
      manifest,
      directoryResolver: () async => tempDir,
    );

    expect(resources.single.bytes, [4, 5, 6]);
  });

  test('资源清单不读取非托管路径并阻断路径穿越', () async {
    final secret = File('${tempDir.path}/secret.bin');
    await secret.writeAsBytes([9, 9, 9]);
    final resources = await AssistantRoleCardAssetStore.load(
      '[{"type":"unknown","localPath":"${secret.path}"}]',
      directoryResolver: () async => tempDir,
    );

    expect(resources.single.bytes, isNull);
    expect(
      AssistantRoleCardAssetStore.managedSuffix(
        '/old/assistant_role_assets/7/../secret.bin',
      ),
      isNull,
    );
  });
}
