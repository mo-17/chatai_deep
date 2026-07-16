import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('role-card-assets-');
  });

  tearDown(() async {
    LoginSdkConfig.reset();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('save 隐式账号在 resolver 切号后 fail closed', () async {
    final authStorage = await _installAccount('account-a');

    await expectLater(
      AssistantRoleCardAssetStore.save(
        assistantId: 3,
        directoryResolver: () async {
          await authStorage.writeProfile(
            token: 'token-b',
            userName: 'user-b',
            extras: const {'accountHash': 'account-b'},
          );
          return tempDir;
        },
        resources: [
          AssistantRoleCardResource(
            type: 'asset',
            uri: 'embeded://stable.bin',
            name: 'stable',
            ext: 'bin',
            size: 1,
            bytes: Uint8List.fromList([1]),
          ),
        ],
      ),
      throwsA(isA<LoginAccountChangedException>()),
    );
    for (final account in ['account-a', 'account-b']) {
      final directory = Directory(
        '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
        '${AccountResourceScope.tokenFor(account)}/3',
      );
      expect(directory.existsSync(), isFalse);
    }
  });

  test('save 中途写盘失败时保留旧目录与旧清单', () async {
    final oldManifest = await AssistantRoleCardAssetStore.save(
      assistantId: 7,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
      resources: [
        AssistantRoleCardResource(
          type: 'asset',
          uri: 'embeded://old.bin',
          name: 'old',
          ext: 'bin',
          size: 3,
          bytes: Uint8List.fromList([7, 7, 7]),
        ),
      ],
    );

    await expectLater(
      AssistantRoleCardAssetStore.save(
        assistantId: 7,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
        debugAfterAssetWrite: (completedWrites) {
          if (completedWrites == 1) throw Exception('injected write failure');
        },
        resources: [
          AssistantRoleCardResource(
            type: 'asset',
            uri: 'embeded://new-a.bin',
            name: 'new-a',
            ext: 'bin',
            size: 1,
            bytes: Uint8List.fromList([1]),
          ),
          AssistantRoleCardResource(
            type: 'asset',
            uri: 'embeded://new-b.bin',
            name: 'new-b',
            ext: 'bin',
            size: 1,
            bytes: Uint8List.fromList([2]),
          ),
        ],
      ),
      throwsA(isA<Exception>()),
    );

    final oldResources = await AssistantRoleCardAssetStore.load(
      oldManifest,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );
    expect(oldResources.single.bytes, [7, 7, 7]);
    final accountDirectory = Directory(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '${AccountResourceScope.tokenFor('account-a')}',
    );
    final leftovers = await accountDirectory
        .list(followLinks: false)
        .where((entity) =>
            entity.path.contains('7.staging.') ||
            entity.path.contains('7.backup.'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('save 提交后 backup 清理失败仍返回已生效的新 manifest', () async {
    AssistantRoleCardResource resource(String name, int byte) =>
        AssistantRoleCardResource(
          type: 'asset',
          uri: 'embeded://$name.bin',
          name: name,
          ext: 'bin',
          size: 1,
          bytes: Uint8List.fromList([byte]),
        );
    await AssistantRoleCardAssetStore.save(
      assistantId: 8,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
      resources: [resource('old', 1)],
    );

    final manifest = await AssistantRoleCardAssetStore.save(
      assistantId: 8,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
      resources: [resource('new', 2)],
      debugBeforeBackupCleanup: () => throw Exception('cleanup unavailable'),
    );

    final loaded = await AssistantRoleCardAssetStore.load(
      manifest,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );
    expect(loaded.single.bytes, [2]);
    final accountDirectory = Directory(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '${AccountResourceScope.tokenFor('account-a')}',
    );
    final backups = await accountDirectory
        .list(followLinks: false)
        .where((entity) => entity.path.contains('8.backup.'))
        .toList();
    expect(backups, hasLength(1));
    final backupFiles = await Directory(backups.single.path)
        .list(followLinks: false)
        .where((entity) => entity is File)
        .map((entity) => File(entity.path))
        .toList();
    expect(await backupFiles.single.readAsBytes(), [1]);
  });

  test('CHARX 资源保存为托管文件并可恢复导出字节', () async {
    final accountToken = AccountResourceScope.tokenFor('account-a');
    final manifest = await AssistantRoleCardAssetStore.save(
      assistantId: 7,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
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
    final resources = await AssistantRoleCardAssetStore.load(
      manifest,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(resources, hasLength(1));
    expect(resources.single.type, 'background');
    expect(resources.single.bytes, [1, 2, 3]);
    expect(
      resources.single.archivePath,
      'assets/background/moon.webp',
    );
    expect(
      (jsonDecode(manifest) as List).single['localPath'],
      contains('/assistant_role_assets/accounts/$accountToken/7/'),
    );
    expect(manifest, isNot(contains('account-a')));

    final legacy = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/7/legacy.bin',
    );
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes([8]);
    final otherAccount = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '${AccountResourceScope.tokenFor('account-b')}/7/private.bin',
    );
    await otherAccount.parent.create(recursive: true);
    await otherAccount.writeAsBytes([9]);

    await AssistantRoleCardAssetStore.delete(
      assistantId: 7,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );
    expect(
      Directory(
        '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
        '$accountToken/7',
      ).existsSync(),
      isFalse,
    );
    expect(legacy.existsSync(), isTrue);
    expect(otherAccount.existsSync(), isTrue);
  });

  test('助手 JSON 往返保留 CHARX 托管清单', () {
    const manifest = '[{"type":"audio","localPath":"/tmp/a.ogg"}]';
    final restored = AssistantModel.fromJson(
      AssistantModel(name: '角色', roleCardAssets: manifest).toJson(),
    );
    expect(restored.roleCardAssets, manifest);
  });

  test('iOS 容器路径变化后按托管目录后缀重定位', () async {
    final legacyTarget = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/9/voice.ogg',
    );
    final accountToken = AccountResourceScope.tokenFor('account-a');
    final scopedTarget = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '$accountToken/9/background.webp',
    );
    final suffixTarget = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/9/relative.bin',
    );
    await legacyTarget.parent.create(recursive: true);
    await scopedTarget.parent.create(recursive: true);
    await legacyTarget.writeAsBytes([4, 5, 6]);
    await scopedTarget.writeAsBytes([7, 8]);
    await suffixTarget.writeAsBytes([9]);
    final manifest = jsonEncode([
      {
        'type': 'audio',
        'name': 'voice',
        'ext': 'ogg',
        'localPath': '/old/container/assistant_role_assets/9/voice.ogg',
      },
      {
        'type': 'background',
        'name': 'background',
        'ext': 'webp',
        'localPath': '/old/container/assistant_role_assets/accounts/'
            '$accountToken/9/background.webp',
      },
      {
        'type': 'unknown',
        'name': 'relative',
        'ext': 'bin',
        'localPath': '9/relative.bin',
      },
    ]);

    final resources = await AssistantRoleCardAssetStore.load(
      manifest,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(resources[0].bytes, [4, 5, 6]);
    expect(resources[1].bytes, [7, 8]);
    expect(resources[2].bytes, [9]);
  });

  test('资源加载拒绝其他账号 scoped 路径', () async {
    final otherToken = AccountResourceScope.tokenFor('account-b');
    final target = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '$otherToken/9/private.bin',
    );
    await target.parent.create(recursive: true);
    await target.writeAsBytes([9, 9, 9]);
    final manifest = jsonEncode([
      {
        'type': 'unknown',
        'name': 'private',
        'ext': 'bin',
        'localPath': target.path,
      },
    ]);

    final resources = await AssistantRoleCardAssetStore.load(
      manifest,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(resources.single.bytes, isNull);
    expect(
      AssistantRoleCardAssetStore.managedSuffix(
        target.path,
        accountHash: 'account-a',
      ),
      isNull,
    );
  });

  test('资源加载不直接读取清单伪造的绝对根目录', () async {
    final accountToken = AccountResourceScope.tokenFor('account-a');
    final forgedRoot = Directory('${tempDir.path}/forged-root');
    final forged = File(
      '${forgedRoot.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '$accountToken/9/private.bin',
    );
    await forged.parent.create(recursive: true);
    await forged.writeAsBytes([6, 6, 6]);
    final manifest = jsonEncode([
      {
        'type': 'unknown',
        'name': 'private',
        'ext': 'bin',
        'localPath': forged.path,
      },
    ]);

    final resources = await AssistantRoleCardAssetStore.load(
      manifest,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(resources.single.bytes, isNull);
    expect(forged.existsSync(), isTrue);
  });

  test(
    '资源加载拒绝托管目录内的 symlink 文件',
    () async {
      final accountToken = AccountResourceScope.tokenFor('account-a');
      final managedDir = Directory(
        '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
        '$accountToken/9',
      );
      await managedDir.create(recursive: true);
      final outside = File('${tempDir.path}/outside-secret.bin');
      await outside.writeAsBytes([9, 8, 7]);
      final link = Link('${managedDir.path}/linked.bin');
      await link.create(outside.path);
      final manifest = jsonEncode([
        {
          'type': 'unknown',
          'name': 'linked',
          'ext': 'bin',
          'localPath': link.path,
        },
      ]);

      await expectLater(
        AssistantRoleCardAssetStore.load(
          manifest,
          directoryResolver: () async => tempDir,
          accountHash: 'account-a',
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await outside.readAsBytes(), [9, 8, 7]);
    },
    skip: Platform.isWindows ? 'Windows CI 不保证允许创建 symlink' : false,
  );

  test(
    'save 拒绝 symlink managed root 且不向外部目录写入',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'role-card-outside-',
      );
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      await Link(
        '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}',
      ).create(outside.path);

      await expectLater(
        AssistantRoleCardAssetStore.save(
          assistantId: 9,
          directoryResolver: () async => tempDir,
          accountHash: 'account-a',
          resources: [
            AssistantRoleCardResource(
              type: 'asset',
              uri: 'embeded://outside.bin',
              name: 'outside',
              ext: 'bin',
              size: 1,
              bytes: Uint8List.fromList([1]),
            ),
          ],
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outside.list().toList(), isEmpty);
    },
    skip: Platform.isWindows ? 'Windows CI 不保证允许创建 symlink' : false,
  );

  test(
    'delete 拒绝 symlink 助手目录且保留外部目录',
    () async {
      final accountDir = Directory(
        '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
        '${AccountResourceScope.tokenFor('account-a')}',
      );
      await accountDir.create(recursive: true);
      final outside = await Directory.systemTemp.createTemp(
        'role-card-delete-outside-',
      );
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      final secret = File('${outside.path}/secret.bin');
      await secret.writeAsBytes([4]);
      final link = Link('${accountDir.path}/7');
      await link.create(outside.path);

      await expectLater(
        AssistantRoleCardAssetStore.delete(
          assistantId: 7,
          directoryResolver: () async => tempDir,
          accountHash: 'account-a',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(link.existsSync(), isTrue);
      expect(await secret.readAsBytes(), [4]);
    },
    skip: Platform.isWindows ? 'Windows CI 不保证允许创建 symlink' : false,
  );

  test('delete 隐式账号在 resolver 切号后 fail closed', () async {
    final authStorage = await _installAccount('account-a');
    final root = Directory(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts',
    );
    final accountA = Directory(
      '${root.path}/${AccountResourceScope.tokenFor('account-a')}/7',
    );
    final accountB = Directory(
      '${root.path}/${AccountResourceScope.tokenFor('account-b')}/7',
    );
    await accountA.create(recursive: true);
    await accountB.create(recursive: true);
    await File('${accountA.path}/a.bin').writeAsBytes([1]);
    await File('${accountB.path}/b.bin').writeAsBytes([2]);

    await expectLater(
      AssistantRoleCardAssetStore.delete(
        assistantId: 7,
        directoryResolver: () async {
          await authStorage.writeProfile(
            token: 'token-b',
            userName: 'user-b',
            extras: const {'accountHash': 'account-b'},
          );
          return tempDir;
        },
      ),
      throwsA(isA<LoginAccountChangedException>()),
    );

    expect(accountA.existsSync(), isTrue);
    expect(accountB.existsSync(), isTrue);
  });

  test('资源加载在读取前拒绝超过 maxAssets 的清单', () async {
    final manifest = jsonEncode([
      for (var i = 0; i <= AssistantRoleCardAssetStore.maxAssets; i++)
        {'type': 'unknown', 'name': '$i', 'localPath': ''},
    ]);

    await expectLater(
      AssistantRoleCardAssetStore.load(
        manifest,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('资源加载在 readAsBytes 前拒绝超过 maxAssetBytes 的文件', () async {
    final accountToken = AccountResourceScope.tokenFor('account-a');
    final file = File(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '$accountToken/7/oversize.bin',
    );
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(AssistantRoleCardAssetStore.maxAssetBytes + 1);
    await handle.close();
    final manifest = jsonEncode([
      {
        'type': 'unknown',
        'name': 'oversize',
        'ext': 'bin',
        'localPath': file.path,
      },
    ]);

    await expectLater(
      AssistantRoleCardAssetStore.load(
        manifest,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('资源加载在 readAsBytes 前拒绝超过 maxTotalBytes 的文件集合', () async {
    final accountToken = AccountResourceScope.tokenFor('account-a');
    final directory = Directory(
      '${tempDir.path}/${AssistantRoleCardAssetStore.directoryName}/accounts/'
      '$accountToken/7',
    );
    await directory.create(recursive: true);
    final files = <File>[];
    for (var i = 0; i < 6; i++) {
      final file = File('${directory.path}/$i.bin');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(
        i < 5 ? AssistantRoleCardAssetStore.maxAssetBytes : 1,
      );
      await handle.close();
      files.add(file);
    }
    final manifest = jsonEncode([
      for (final file in files)
        {
          'type': 'unknown',
          'name': file.path,
          'ext': 'bin',
          'localPath': file.path,
        },
    ]);

    await expectLater(
      AssistantRoleCardAssetStore.load(
        manifest,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('资源清单不读取非托管路径并阻断路径穿越', () async {
    final secret = File('${tempDir.path}/secret.bin');
    await secret.writeAsBytes([9, 9, 9]);
    final resources = await AssistantRoleCardAssetStore.load(
      '[{"type":"unknown","localPath":"${secret.path}"}]',
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(resources.single.bytes, isNull);
    expect(
      AssistantRoleCardAssetStore.managedSuffix(
        '/old/assistant_role_assets/7/../secret.bin',
      ),
      isNull,
    );
    expect(
      AssistantRoleCardAssetStore.managedSuffix(
        '7/voice.ogg',
        accountHash: 'account-a',
      ),
      '7/voice.ogg',
    );
    expect(
      AssistantRoleCardAssetStore.managedSuffix(
        r'C:\old\assistant_role_assets\7\voice.ogg',
        accountHash: 'account-a',
      ),
      '7/voice.ogg',
    );
  });
}

Future<_MemoryTokenStorage> _installAccount(String accountHash) async {
  final storage = _MemoryTokenStorage();
  await storage.writeProfile(
    token: 'token-a',
    userName: 'user-a',
    extras: {'accountHash': accountHash},
  );
  LoginSdkConfig.install(LoginSdkConfig(
    baseUrl: 'localhost:3000',
    headerProvider: () async => const {},
    syncHeaders: () => const {},
    routes: LoginRoutes.imooc,
    responseAdapter: ImoocResponseAdapter(),
    storage: storage,
    onLogoutNavigate: () {},
  ));
  return storage;
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  @override
  Future<void> clear() async => _profile = null;

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = {
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      ...extras,
    };
  }
}
