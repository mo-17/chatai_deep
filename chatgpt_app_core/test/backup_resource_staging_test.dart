import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<HiDBManager> newDb() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    return HiDBManager.test(db);
  }

  String basename(String path) => path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .last;

  Future<List<String>> transactionArtifacts(Directory target) async {
    final parent = target.absolute.parent;
    if (!await parent.exists()) return const [];
    final prefix = '${basename(target.path)}.backup-';
    return [
      await for (final entity in parent.list(followLinks: false))
        if (basename(entity.path).startsWith(prefix)) entity.path,
    ];
  }

  Future<Map<String, List<int>>> directorySnapshot(Directory root) async {
    if (!await root.exists()) return const {};
    final snapshot = <String, List<int>>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(root.path.length + 1);
      snapshot[relative] = await entity.readAsBytes();
    }
    return snapshot;
  }

  Future<List<int>> exportAllResourceKinds({
    required Directory documents,
    required File attachment,
  }) async {
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => documents;
    BackupService.debugGeneratedImageDirectoryResolver = () async => documents;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => documents;

    final avatarDir =
        await AvatarAssetService.avatarDir(accountHash: 'source-account');
    final avatar = File('${avatarDir.path}/conversation_source.png');
    await avatar.writeAsBytes([1, 2, 3]);

    final generatedDir = Directory(
      '${documents.path}/${GeneratedImageSaveService.albumDirectoryName}',
    );
    await generatedDir.create(recursive: true);
    await File('${generatedDir.path}/imported.png').writeAsBytes([4, 5, 6]);

    final roleAsset = File(
      '${documents.path}/${AssistantRoleCardAssetStore.directoryName}/7/000.webp',
    );
    await roleAsset.parent.create(recursive: true);
    await roleAsset.writeAsBytes([7, 8, 9]);
    final managedPath = await ManagedAttachmentStore.importFile(attachment);

    final source = await newDb();
    await ConversationListDao.create(source);
    await MessageDao.create(source, cid: 100);
    await AssistantDao.create(source);
    await source.db.insert('tb_conversation_list', {
      'cid': 100,
      'icon': '',
      'stickTime': 0,
      'title': 'source',
      'avatarType': AvatarAssetService.imageType,
      'avatarValue': avatar.path,
    });
    await source.db.insert('tb_messages', {
      'cid': 100,
      'content': 'attachment',
      'createdAt': 100,
      'ownerName': 'user',
      'ownerType': 'sender',
      'blocks': MessageBlock.encodeList([
        FileBlock(
          id: 'file-resource',
          messageId: 'message-resource',
          createdAt: 100,
          status: MessageBlockStatus.success,
          file: FileMetadata(
            name: 'resource.txt',
            path: managedPath,
            mime: 'text/plain',
            size: await attachment.length(),
          ),
        ),
      ]),
    });
    await source.db.insert('tb_assistant', {
      ...AssistantModel(
        name: 'resource assistant',
        roleCardAssets: jsonEncode([
          {
            'type': 'background',
            'name': 'moon',
            'ext': 'webp',
            'localPath': roleAsset.path,
          },
        ]),
      ).toJson(),
      'id': 7,
    });
    final bytes = await BackupService(source).exportArchive(
      settings: AISettings.defaults(),
      accountHash: 'source-account',
    );
    await source.db.close();
    return bytes;
  }

  Future<List<int>> exportGeneratedImage({
    required Directory documents,
  }) async {
    BackupService.debugGeneratedImageDirectoryResolver = () async => documents;
    final generatedDir = AccountResourceScope.scopedDirectory(
      base: documents,
      resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
      accountHash: 'source-account',
    );
    await generatedDir.create(recursive: true);
    await File('${generatedDir.path}/imported.png').writeAsBytes([41, 42, 43]);

    final source = await newDb();
    final bytes = await BackupService(source).exportArchive(
      settings: AISettings.defaults(),
      accountHash: 'source-account',
    );
    await source.db.close();
    return bytes;
  }

  Future<List<int>> exportConversation({
    required int cid,
    required Directory documents,
  }) async {
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => documents;
    BackupService.debugGeneratedImageDirectoryResolver = () async => documents;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => documents;
    final source = await newDb();
    await ConversationListDao.create(source);
    await source.db.insert('tb_conversation_list', {
      'cid': cid,
      'icon': '',
      'stickTime': 0,
      'title': 'source conversation',
    });
    final bytes = await BackupService(source).exportArchive(
      settings: AISettings.defaults(),
      accountHash: 'source-account',
    );
    await source.db.close();
    return bytes;
  }

  group('backup resource two-phase commit', () {
    late Directory sourceDocuments;
    late Directory targetDocuments;
    late Directory sourceFiles;
    late Directory attachmentTarget;

    Future<
        ({
          Directory avatar,
          Directory generated,
          Directory role,
          Directory attachment,
          Map<String, Map<String, List<int>>> snapshots,
        })> seedTargetResources() async {
      AvatarAssetService.debugDocumentsDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;

      final avatar =
          await AvatarAssetService.avatarDir(accountHash: 'target-account');
      await File('${avatar.path}/old-avatar.png').writeAsBytes([51]);
      final generated = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'target-account',
      );
      await generated.create(recursive: true);
      await File('${generated.path}/old-generated.png').writeAsBytes([52]);
      final role = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
        accountHash: 'target-account',
      );
      final oldRole = File('${role.path}/1/old.bin');
      await oldRole.parent.create(recursive: true);
      await oldRole.writeAsBytes([53]);
      await File('${attachmentTarget.path}/old-resource.txt')
          .writeAsBytes([54]);

      final directories = [avatar, generated, role, attachmentTarget];
      return (
        avatar: avatar,
        generated: generated,
        role: role,
        attachment: attachmentTarget,
        snapshots: {
          for (final directory in directories)
            directory.path: await directorySnapshot(directory),
        },
      );
    }

    Future<HiDBManager> targetDbWithSentinel(int cid) async {
      final target = await newDb();
      await ConversationListDao.create(target);
      await target.db.insert('tb_conversation_list', {
        'cid': cid,
        'icon': '',
        'stickTime': 0,
        'title': 'local sentinel',
      });
      return target;
    }

    setUp(() async {
      sourceDocuments =
          await Directory.systemTemp.createTemp('backup-stage-source-');
      targetDocuments =
          await Directory.systemTemp.createTemp('backup-stage-target-');
      sourceFiles =
          await Directory.systemTemp.createTemp('backup-stage-files-');
      attachmentTarget =
          Directory('${targetDocuments.path}/managed-attachments');
      ManagedAttachmentStore.debugRootDirectory = attachmentTarget;
      await attachmentTarget.create(recursive: true);
    });

    tearDown(() async {
      ManagedAttachmentStore.debugRootDirectory = null;
      BackupService.debugGeneratedImageDirectoryResolver = null;
      BackupService.debugRoleCardAssetsDirectoryResolver = null;
      BackupService.debugImportFailureInjector = null;
      BackupService.debugResourceRollbackFailureInjector = null;
      AvatarAssetService.debugDocumentsDirectoryResolver = null;
      final oldAttachment = File('${attachmentTarget.path}/old-resource.txt');
      if (await oldAttachment.exists()) await oldAttachment.delete();
      for (final dir in [sourceDocuments, targetDocuments, sourceFiles]) {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });

    test(
        'DB failure after staging preserves avatar, attachment, generated image and role-card resources',
        () async {
      final attachment = File('${sourceFiles.path}/resource.txt');
      await attachment.writeAsBytes([10, 11, 12]);
      final bytes = await exportAllResourceKinds(
        documents: sourceDocuments,
        attachment: attachment,
      );

      AvatarAssetService.debugDocumentsDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;

      final avatarDir =
          await AvatarAssetService.avatarDir(accountHash: 'target-account');
      final oldAvatar = File('${avatarDir.path}/old-avatar.png');
      await oldAvatar.writeAsBytes([21]);
      final generatedDir = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'target-account',
      );
      await generatedDir.create(recursive: true);
      final oldGenerated = File('${generatedDir.path}/old-generated.png');
      await oldGenerated.writeAsBytes([22]);
      final roleDir = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
        accountHash: 'target-account',
      );
      final oldRole = File('${roleDir.path}/1/old.bin');
      await oldRole.parent.create(recursive: true);
      await oldRole.writeAsBytes([23]);
      final oldAttachment = File('${attachmentTarget.path}/old-resource.txt');
      await oldAttachment.writeAsBytes([24]);
      final originalResources = {
        avatarDir.path: await directorySnapshot(avatarDir),
        generatedDir.path: await directorySnapshot(generatedDir),
        roleDir.path: await directorySnapshot(roleDir),
        attachmentTarget.path: await directorySnapshot(attachmentTarget),
      };

      final target = await newDb();
      await ConversationListDao.create(target);
      await target.db.insert('tb_conversation_list', {
        'cid': 900,
        'icon': '',
        'stickTime': 0,
        'title': 'local sentinel',
      });
      BackupService.debugImportFailureInjector = (point) async {
        if (point == BackupImportFailurePoint.beforeResourceSwap) {
          throw StateError('injected database failure');
        }
      };

      await expectLater(
        BackupService(target).importArchive(
          bytes,
          accountHash: 'target-account',
        ),
        throwsA(isA<StateError>()),
      );

      final conversations =
          await target.db.query('tb_conversation_list', columns: ['cid']);
      expect(conversations, hasLength(1));
      expect(conversations.single['cid'], 900);
      expect(await oldAvatar.readAsBytes(), [21]);
      expect(await oldGenerated.readAsBytes(), [22]);
      expect(await oldRole.readAsBytes(), [23]);
      expect(await oldAttachment.readAsBytes(), [24]);
      for (final dir in [avatarDir, generatedDir, roleDir, attachmentTarget]) {
        expect(await directorySnapshot(dir), originalResources[dir.path]);
        expect(await transactionArtifacts(dir), isEmpty);
      }
      await target.db.close();
    });

    test('failure after every directory swap restores DB and every resource',
        () async {
      final attachment = File('${sourceFiles.path}/resource.txt');
      await attachment.writeAsBytes([61, 62, 63]);
      final bytes = await exportAllResourceKinds(
        documents: sourceDocuments,
        attachment: attachment,
      );
      final resources = await seedTargetResources();
      final target = await targetDbWithSentinel(902);
      var swappedDirectoryCount = -1;
      BackupService.debugImportFailureInjector = (point) async {
        if (point == BackupImportFailurePoint.afterResourceSwap) {
          swappedDirectoryCount = 0;
          for (final directory in [
            resources.avatar,
            resources.generated,
            resources.role,
            resources.attachment,
          ]) {
            if ((await transactionArtifacts(directory)).isNotEmpty) {
              swappedDirectoryCount++;
            }
          }
          throw StateError('injected failure after all directory swaps');
        }
      };

      await expectLater(
        BackupService(target).importArchive(
          bytes,
          accountHash: 'target-account',
        ),
        throwsA(isA<StateError>()),
      );

      final conversations =
          await target.db.query('tb_conversation_list', columns: ['cid']);
      expect(swappedDirectoryCount, 4);
      expect(conversations, hasLength(1));
      expect(conversations.single['cid'], 902);
      for (final directory in [
        resources.avatar,
        resources.generated,
        resources.role,
        resources.attachment,
      ]) {
        expect(
          await directorySnapshot(directory),
          resources.snapshots[directory.path],
          reason: 'rollback must restore ${directory.path}',
        );
        expect(await transactionArtifacts(directory), isEmpty);
      }
      await target.db.close();
    });

    test('one rollback operation failure does not stop later directories',
        () async {
      final attachment = File('${sourceFiles.path}/resource.txt');
      await attachment.writeAsBytes([71, 72, 73]);
      final bytes = await exportAllResourceKinds(
        documents: sourceDocuments,
        attachment: attachment,
      );
      final resources = await seedTargetResources();
      final target = await targetDbWithSentinel(903);
      var rollbackFailureInjected = false;
      BackupService.debugImportFailureInjector = (point) async {
        if (point == BackupImportFailurePoint.afterResourceSwap) {
          throw StateError('trigger best-effort rollback');
        }
      };
      BackupService.debugResourceRollbackFailureInjector =
          (rollbackIndex, operation) async {
        if (rollbackIndex == 0 &&
            operation == BackupResourceRollbackOperation.removeStagedTarget) {
          rollbackFailureInjected = true;
          throw const FileSystemException('injected rollback failure');
        }
      };

      await expectLater(
        BackupService(target).importArchive(
          bytes,
          accountHash: 'target-account',
        ),
        throwsA(anything),
      );

      expect(rollbackFailureInjected, isTrue);
      final conversations =
          await target.db.query('tb_conversation_list', columns: ['cid']);
      expect(conversations, hasLength(1));
      expect(conversations.single['cid'], 903);
      // rollback 逆序执行，index 0 是最后 staging 的 avatar。即使该目录
      // 的第一步失败，后续 role/generated/attachment 也必须继续补偿。
      for (final directory in [
        resources.role,
        resources.generated,
        resources.attachment,
      ]) {
        expect(
          await directorySnapshot(directory),
          resources.snapshots[directory.path],
          reason: 'a previous rollback failure must not skip ${directory.path}',
        );
        expect(await transactionArtifacts(directory), isEmpty);
      }
      await target.db.close();
    });

    test('partial final directory swap restores old resources and DB rows',
        () async {
      final generatedSource = Directory(
        '${sourceDocuments.path}/${GeneratedImageSaveService.albumDirectoryName}',
      );
      await generatedSource.create(recursive: true);
      await File('${generatedSource.path}/imported.png').writeAsBytes([31]);
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => sourceDocuments;
      final source = await newDb();
      final bytes = await BackupService(source).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'source-account',
      );
      await source.db.close();

      AvatarAssetService.debugDocumentsDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;
      final generatedTarget = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'target-account',
      );
      await generatedTarget.create(recursive: true);
      final original = File('${generatedTarget.path}/original.png');
      await original.writeAsBytes([32, 33]);
      final originalResources = await directorySnapshot(generatedTarget);
      final target = await newDb();
      await ConversationListDao.create(target);
      await target.db.insert('tb_conversation_list', {
        'cid': 901,
        'icon': '',
        'stickTime': 0,
        'title': 'local sentinel',
      });
      BackupService.debugImportFailureInjector = (point) async {
        if (point == BackupImportFailurePoint.afterFirstResourceDirectorySwap) {
          throw const FileSystemException(
            'injected final directory swap failure',
          );
        }
      };

      await expectLater(
        BackupService(target).importArchive(
          bytes,
          accountHash: 'target-account',
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await original.readAsBytes(), [32, 33]);
      expect(
          File('${generatedTarget.path}/imported.png').existsSync(), isFalse);
      expect(await directorySnapshot(generatedTarget), originalResources);
      expect(await transactionArtifacts(generatedTarget), isEmpty);
      final conversations =
          await target.db.query('tb_conversation_list', columns: ['cid']);
      expect(conversations, hasLength(1));
      expect(conversations.single['cid'], 901);
      await target.db.close();
    });

    for (final scenario in ['created', 'deleted', 'changed']) {
      test('target $scenario after staging fails closed without overwriting it',
          () async {
        final bytes = await exportGeneratedImage(documents: sourceDocuments);
        AvatarAssetService.debugDocumentsDirectoryResolver =
            () async => targetDocuments;
        BackupService.debugGeneratedImageDirectoryResolver =
            () async => targetDocuments;
        BackupService.debugRoleCardAssetsDirectoryResolver =
            () async => targetDocuments;
        final generatedTarget = AccountResourceScope.scopedDirectory(
          base: targetDocuments,
          resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
          accountHash: 'target-account',
        );
        final externalFile = File('${generatedTarget.path}/external.png');
        if (scenario != 'created') {
          await generatedTarget.create(recursive: true);
          await externalFile.writeAsBytes([81, 82, 83], flush: true);
        }

        final target = await targetDbWithSentinel(904);
        var mutationInjected = false;
        BackupService.debugImportFailureInjector = (point) async {
          if (point != BackupImportFailurePoint.beforeResourceSwap) return;
          mutationInjected = true;
          switch (scenario) {
            case 'created':
              await generatedTarget.create(recursive: true);
              await externalFile.writeAsBytes([84, 85, 86], flush: true);
              break;
            case 'deleted':
              await generatedTarget.delete(recursive: true);
              break;
            case 'changed':
              // 保持文件长度相同，确保校验的是内容而不只是 size。
              await externalFile.writeAsBytes([87, 88, 89], flush: true);
              break;
          }
        };

        await expectLater(
          BackupService(target).importArchive(
            bytes,
            accountHash: 'target-account',
          ),
          throwsA(anything),
        );

        final conversations =
            await target.db.query('tb_conversation_list', columns: ['cid']);
        expect(mutationInjected, isTrue);
        expect(conversations, hasLength(1));
        expect(conversations.single['cid'], 904);
        switch (scenario) {
          case 'created':
            expect(await externalFile.readAsBytes(), [84, 85, 86]);
            break;
          case 'deleted':
            expect(await generatedTarget.exists(), isFalse);
            break;
          case 'changed':
            expect(await externalFile.readAsBytes(), [87, 88, 89]);
            break;
        }
        expect(
          File('${generatedTarget.path}/imported.png').existsSync(),
          isFalse,
        );
        expect(await transactionArtifacts(generatedTarget), isEmpty);
        await target.db.close();
      });
    }

    test('rollback never deletes a target replaced after the final swap',
        () async {
      final bytes = await exportGeneratedImage(documents: sourceDocuments);
      AvatarAssetService.debugDocumentsDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;
      final generatedTarget = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'target-account',
      );
      await generatedTarget.create(recursive: true);
      await File('${generatedTarget.path}/original.png')
          .writeAsBytes([91, 92, 93]);
      final externalReplacement =
          File('${generatedTarget.path}/external-after-swap.png');
      final target = await targetDbWithSentinel(906);
      var replaced = false;
      BackupService.debugImportFailureInjector = (point) async {
        if (point != BackupImportFailurePoint.afterResourceSwap) return;
        await generatedTarget.delete(recursive: true);
        await generatedTarget.create(recursive: true);
        await externalReplacement.writeAsBytes([94, 95, 96], flush: true);
        replaced = true;
        throw StateError('trigger rollback after external replacement');
      };

      await expectLater(
        BackupService(target).importArchive(
          bytes,
          accountHash: 'target-account',
        ),
        throwsA(anything),
      );

      expect(replaced, isTrue);
      expect(await externalReplacement.readAsBytes(), [94, 95, 96]);
      expect(
        File('${generatedTarget.path}/imported.png').existsSync(),
        isFalse,
      );
      final conversations =
          await target.db.query('tb_conversation_list', columns: ['cid']);
      expect(conversations, hasLength(1));
      expect(conversations.single['cid'], 906);
      // 外部替换后不可递归删除正式目录；原目录留在随机
      // backup 路径中，不进一步覆盖外部数据。
      expect(await transactionArtifacts(generatedTarget), isNotEmpty);
      await target.db.close();
    });

    test('same-account imports serialize and a failed import does not poison',
        () async {
      final bytes = await exportConversation(
        cid: 777,
        documents: sourceDocuments,
      );
      AvatarAssetService.debugDocumentsDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => targetDocuments;
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;
      final target = await targetDbWithSentinel(905);
      final firstService = BackupService(target);
      final secondService = BackupService(target);
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      final secondEntered = Completer<void>();
      var firstGuardWaited = false;
      var injectedFailures = 0;
      BackupService.debugImportFailureInjector = (point) async {
        if (point == BackupImportFailurePoint.afterResourceSwap &&
            injectedFailures == 0) {
          injectedFailures++;
          throw StateError('first import fails');
        }
      };

      final firstImport = firstService.importArchive(
        bytes,
        accountHash: 'target-account',
        accountGuard: () async {
          if (firstGuardWaited) return;
          firstGuardWaited = true;
          firstEntered.complete();
          await releaseFirst.future;
        },
      );
      final firstFailure = expectLater(firstImport, throwsA(isA<StateError>()));
      await firstEntered.future;

      final secondImport = secondService.importArchive(
        bytes,
        accountHash: 'target-account',
        accountGuard: () {
          if (!secondEntered.isCompleted) secondEntered.complete();
        },
      );
      final secondRanWhileFirstWasBlocked = await Future.any<bool>([
        secondEntered.future.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 75), () => false),
      ]);

      releaseFirst.complete();
      await firstFailure;
      final result = await secondImport;

      expect(secondRanWhileFirstWasBlocked, isFalse);
      expect(injectedFailures, 1);
      expect(secondEntered.isCompleted, isTrue);
      expect(result.conversations, 1);
      final conversations =
          await target.db.query('tb_conversation_list', columns: ['cid']);
      expect(conversations, hasLength(1));
      expect(conversations.single['cid'], 777);
      await target.db.close();
    });
  });
}
