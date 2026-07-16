import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('generated-image-save-');
  });

  tearDown(() async {
    LoginSdkConfig.reset();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('saveToAppAlbum 隐式账号在 resolver 切号后 fail closed', () async {
    final authStorage = await _installAccount('account-a');
    final plan = GeneratedImageSavePlan(
      source: 'data:image/png;base64,${base64Encode([1, 2, 3])}',
      albumName: 'ChatAI Deep',
      filename: 'stable.png',
      needsPhotoPermission: false,
    );

    await expectLater(
      GeneratedImageSaveService.saveToAppAlbum(
        plan,
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
    for (final account in ['account-a', 'account-b']) {
      final file = File(
        '${tempDir.path}/generated_images/accounts/'
        '${AccountResourceScope.tokenFor(account)}/stable.png',
      );
      expect(file.existsSync(), isFalse);
    }
  });

  test('saveToAppAlbum 保存 data URI 到当前账号的脱敏目录', () async {
    final bytes = [1, 2, 3, 4];
    final plan = GeneratedImageSavePlan(
      source: 'data:image/png;base64,${base64Encode(bytes)}',
      albumName: 'ChatAI Deep',
      filename: 'demo.png',
      needsPhotoPermission: false,
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      plan,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    final scope = AccountResourceScope.tokenFor('account-a');
    expect(
      path,
      endsWith('/generated_images/accounts/$scope/demo.png'),
    );
    expect(path, isNot(contains('account-a')));
    expect(await File(path).readAsBytes(), bytes);
  });

  test('saveToAppAlbum 提交后 backup 清理失败仍返回已生效的新文件', () async {
    GeneratedImageSavePlan plan(List<int> bytes) => GeneratedImageSavePlan(
          source: 'data:image/png;base64,${base64Encode(bytes)}',
          albumName: 'ChatAI Deep',
          filename: 'replace.png',
          needsPhotoPermission: false,
        );
    await GeneratedImageSaveService.saveToAppAlbum(
      plan([1]),
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      plan([2, 3]),
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
      debugBeforeBackupCleanup: () => throw Exception('cleanup unavailable'),
    );

    expect(await File(path).readAsBytes(), [2, 3]);
    final directory = File(path).parent;
    final backups = await directory
        .list(followLinks: false)
        .where((entity) => entity.path.contains('replace.png.backup.'))
        .toList();
    expect(backups, hasLength(1));
    expect(await File(backups.single.path).readAsBytes(), [1]);
  });

  test('saveToAppAlbum 复制本地文件', () async {
    final source = File('${tempDir.path}/source.png');
    await source.writeAsBytes([9, 8, 7]);
    const plan = GeneratedImageSavePlan(
      source: '',
      albumName: 'ChatAI Deep',
      filename: 'copy.png',
      needsPhotoPermission: false,
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      GeneratedImageSavePlan(
        source: source.path,
        albumName: plan.albumName,
        filename: plan.filename,
        needsPhotoPermission: plan.needsPhotoPermission,
      ),
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(await File(path).readAsBytes(), [9, 8, 7]);
  });

  test('saveToAppAlbum 下载 http 图片', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://img.example/a.png');
      return http.Response.bytes([5, 6, 7], 200);
    });
    const plan = GeneratedImageSavePlan(
      source: 'https://img.example/a.png',
      albumName: 'ChatAI Deep',
      filename: 'remote.png',
      needsPhotoPermission: false,
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      plan,
      directoryResolver: () async => tempDir,
      client: client,
      accountHash: 'account-a',
    );

    expect(await File(path).readAsBytes(), [5, 6, 7]);
  });

  test('listSavedImages 合并当前账号与 legacy 顶层且不暴露其他账号', () async {
    final dir = Directory('${tempDir.path}/generated_images');
    final accountADir = Directory(
      '${dir.path}/accounts/${AccountResourceScope.tokenFor('account-a')}',
    );
    final accountBDir = Directory(
      '${dir.path}/accounts/${AccountResourceScope.tokenFor('account-b')}',
    );
    await accountADir.create(recursive: true);
    await accountBDir.create(recursive: true);
    final oldFile = File('${dir.path}/legacy.png');
    final newFile = File('${accountADir.path}/current.jpg');
    final otherAccount = File('${accountBDir.path}/private.png');
    final ignored = File('${dir.path}/note.txt');
    await oldFile.writeAsBytes([1]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await newFile.writeAsBytes([2, 3]);
    await otherAccount.writeAsBytes([9, 9, 9]);
    await ignored.writeAsString('not image');

    final items = await GeneratedImageSaveService.listSavedImages(
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(items.map((e) => e.filename), ['current.jpg', 'legacy.png']);
    expect(items.first.sizeBytes, 2);
    expect(items.first.path, newFile.path);
    expect(items.map((e) => e.path), isNot(contains(otherAccount.path)));
  });

  test('listSavedImages 隐式账号在 resolver 切号后 fail closed', () async {
    final authStorage = await _installAccount('account-a');
    final root = Directory('${tempDir.path}/generated_images');
    final accountA = Directory(
      '${root.path}/accounts/${AccountResourceScope.tokenFor('account-a')}',
    );
    final accountB = Directory(
      '${root.path}/accounts/${AccountResourceScope.tokenFor('account-b')}',
    );
    await accountA.create(recursive: true);
    await accountB.create(recursive: true);
    await File('${accountA.path}/a.png').writeAsBytes([1]);
    await File('${accountB.path}/b.png').writeAsBytes([2]);

    await expectLater(
      GeneratedImageSaveService.listSavedImages(
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
  });

  test(
    'saveToAppAlbum 拒绝预置目标 symlink 且不覆盖外部文件',
    () async {
      final accountDir = Directory(
        '${tempDir.path}/generated_images/accounts/'
        '${AccountResourceScope.tokenFor('account-a')}',
      );
      await accountDir.create(recursive: true);
      final outside = File('${tempDir.path}/outside.png');
      await outside.writeAsBytes([9, 9, 9]);
      await Link('${accountDir.path}/linked.png').create(outside.path);
      final plan = GeneratedImageSavePlan(
        source: 'data:image/png;base64,${base64Encode([1, 2, 3])}',
        albumName: 'ChatAI Deep',
        filename: 'linked.png',
        needsPhotoPermission: false,
      );

      await expectLater(
        GeneratedImageSaveService.saveToAppAlbum(
          plan,
          directoryResolver: () async => tempDir,
          accountHash: 'account-a',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outside.readAsBytes(), [9, 9, 9]);
    },
    skip: Platform.isWindows ? 'Windows CI 不保证允许创建 symlink' : false,
  );

  test(
    'listSavedImages 拒绝 symlink managed root',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'generated-image-outside-',
      );
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      await File('${outside.path}/outside.png').writeAsBytes([7]);
      await Link('${tempDir.path}/generated_images').create(outside.path);

      await expectLater(
        GeneratedImageSaveService.listSavedImages(
          directoryResolver: () async => tempDir,
          accountHash: 'account-a',
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows ? 'Windows CI 不保证允许创建 symlink' : false,
  );

  test('deleteSavedImage 只删除当前 scoped 或 legacy 顶层文件', () async {
    final dir = Directory('${tempDir.path}/generated_images');
    final accountADir = Directory(
      '${dir.path}/accounts/${AccountResourceScope.tokenFor('account-a')}',
    );
    final accountBDir = Directory(
      '${dir.path}/accounts/${AccountResourceScope.tokenFor('account-b')}',
    );
    await accountADir.create(recursive: true);
    await accountBDir.create(recursive: true);
    final image = File('${accountADir.path}/delete-me.png');
    final legacy = File('${dir.path}/legacy.png');
    final otherAccount = File('${accountBDir.path}/private.png');
    await image.writeAsBytes([1, 2]);
    await legacy.writeAsBytes([4]);
    await otherAccount.writeAsBytes([5]);
    final outside = File('${tempDir.path}/outside.png');
    await outside.writeAsBytes([3]);

    final deleted = await GeneratedImageSaveService.deleteSavedImage(
      image.path,
      directoryResolver: () async => tempDir,
      accountHash: 'account-a',
    );

    expect(deleted, isTrue);
    expect(image.existsSync(), isFalse);
    expect(
      await GeneratedImageSaveService.deleteSavedImage(
        legacy.path,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
      ),
      isTrue,
    );
    expect(legacy.existsSync(), isFalse);

    expect(
      () => GeneratedImageSaveService.deleteSavedImage(
        outside.path,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => GeneratedImageSaveService.deleteSavedImage(
        otherAccount.path,
        directoryResolver: () async => tempDir,
        accountHash: 'account-a',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(outside.existsSync(), isTrue);
    expect(otherAccount.existsSync(), isTrue);
  });

  test('deleteSavedImage 隐式账号在 resolver 切号后 fail closed', () async {
    final authStorage = await _installAccount('account-a');
    final root = Directory('${tempDir.path}/generated_images/accounts');
    final accountA = Directory(
      '${root.path}/${AccountResourceScope.tokenFor('account-a')}',
    );
    final accountB = Directory(
      '${root.path}/${AccountResourceScope.tokenFor('account-b')}',
    );
    await accountA.create(recursive: true);
    await accountB.create(recursive: true);
    final target = File('${accountA.path}/delete.png');
    final other = File('${accountB.path}/delete.png');
    await target.writeAsBytes([1]);
    await other.writeAsBytes([2]);

    await expectLater(
      GeneratedImageSaveService.deleteSavedImage(
        target.path,
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

    expect(target.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
  });

  test(
    'deleteSavedImage 拒绝 symlink 文件且不触及外部目标',
    () async {
      final accountDir = Directory(
        '${tempDir.path}/generated_images/accounts/'
        '${AccountResourceScope.tokenFor('account-a')}',
      );
      await accountDir.create(recursive: true);
      final outside = File('${tempDir.path}/outside-delete.png');
      await outside.writeAsBytes([5, 6]);
      final link = Link('${accountDir.path}/linked.png');
      await link.create(outside.path);

      await expectLater(
        GeneratedImageSaveService.deleteSavedImage(
          link.path,
          directoryResolver: () async => tempDir,
          accountHash: 'account-a',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(link.existsSync(), isTrue);
      expect(await outside.readAsBytes(), [5, 6]);
    },
    skip: Platform.isWindows ? 'Windows CI 不保证允许创建 symlink' : false,
  );
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
