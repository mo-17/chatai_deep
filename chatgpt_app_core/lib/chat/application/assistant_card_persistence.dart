import 'package:login_sdk/platform/app_io.dart';

import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/platform/app_paths.dart';

typedef AssistantStableMutation = Future<AssistantMutationResult> Function(
    Future<AssistantMutationResult> Function() action);

/// 单张卡以数据库 CAS 为发布点。文件先写入本次独有目录，失败只清理自有文件。
/// 不承诺跨 SQLite/文件系统断电原子性；孤立 generation 可识别且不改有效引用。
class AssistantCardPersistence {
  final AssistantDao dao;
  final AssistantOperationScope scope;
  final RoleCardAssetDirectoryResolver? directoryResolver;
  final AssistantStableMutation? stableMutation;
  final Future<void> Function(Future<void> Function())? stableMaintenance;

  const AssistantCardPersistence(
      {required this.dao,
      required this.scope,
      this.directoryResolver,
      @visibleForTesting this.stableMutation,
      @visibleForTesting this.stableMaintenance});

  Future<AssistantCardSaveResult> save(
    AssistantModel source, {
    AssistantRowSnapshot? expected,
    bool renameOnConflict = false,
    List<AssistantRoleCardResource> resources = const [],
    List<int>? avatarBytes,
    String avatarExtension = '.png',
    @visibleForTesting RoleCardAssetWriteObserver? afterAssetWrite,
    @visibleForTesting Future<void> Function()? afterPrepared,
    @visibleForTesting Future<void> Function(Transaction)? beforeCommit,
    @visibleForTesting Future<void> Function()? beforeCleanup,
    @visibleForTesting Future<void> Function()? afterCleanupReferenceRead,
  }) async {
    scope.verify();
    final candidate = AssistantModel.fromJson(source.toJson());
    final id = expected?.id ?? await dao.nextInsertionId();
    scope.verify();
    final generation = generateUuidV4();
    var resourcesPrepared = false;
    String? ownedAvatar;
    AssistantMutationResult? committed;
    AssistantMutationResult? published;
    final notices = <String>[];
    try {
      if (resources.isNotEmpty) {
        candidate.roleCardAssets = await AssistantRoleCardAssetStore.save(
          assistantId: id,
          generation: generation,
          resources: resources,
          accountHash: scope.accountHash,
          directoryResolver: directoryResolver,
          // 测试故障注入由协调层显式转交，仅非空时触发。
          // ignore: invalid_use_of_visible_for_testing_member
          debugAfterAssetWrite: afterAssetWrite,
        );
        resourcesPrepared = true;
        scope.verify();
      }
      if (avatarBytes != null) {
        ownedAvatar =
            await _prepareAvatar(avatarBytes, generation, avatarExtension);
        candidate.avatarType = AvatarAssetService.imageType;
        candidate.avatarValue = ownedAvatar;
        scope.verify();
      }
      if (afterPrepared != null) await afterPrepared();
      scope.verify();
      Future<AssistantMutationResult> publish() async {
        scope.verify();
        final result = await dao.saveChecked(candidate,
            expected: expected,
            reservedId: expected == null ? id : null,
            renameOnConflict: renameOnConflict,
            validateBeforeCommit: (txn) async {
          if (beforeCommit != null) await beforeCommit(txn);
          scope.verify();
        });
        published = result;
        return result;
      }

      committed = await (stableMutation ??
          scope.runStable<AssistantMutationResult>)(publish);
    } catch (error, stack) {
      // publish 已返回代表 SQLite 已提交；lease 的后置校验不能删除有效文件。
      if (published != null) {
        return AssistantCardSaveResult(published!, ['角色已保存；页面已变化，请刷新查看']);
      }
      if (resourcesPrepared) {
        try {
          await AssistantRoleCardAssetStore.discardGeneration(
              assistantId: id,
              generation: generation,
              accountHash: scope.accountHash,
              directoryResolver: directoryResolver);
        } catch (_) {/* 自有孤立目录仍不影响旧行引用，可在后续清理。 */}
      }
      if (ownedAvatar != null) {
        try {
          await appFile(ownedAvatar).delete();
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stack);
    }
    if (expected != null && resourcesPrepared) {
      try {
        if (beforeCleanup != null) await beforeCleanup();
        await (stableMaintenance ?? scope.runStable<void>)(() async {
          scope.verify();
          await dao.storage.db
              .query(dao.tableName, columns: ['roleCardAssets']);
          if (afterCleanupReferenceRead != null) {
            await afterCleanupReferenceRead();
          }
          scope.verify();
          // 旧引用者并未全部共享本 lease，查询结果不是删除授权。
          // 发布后旧目录保留；只在发布失败时删除本次独有 generation。
          notices.add('角色已保存；旧资源已保留，会继续占用磁盘空间');
        });
      } catch (_) {
        notices.add('角色已保存；旧资源已保留，会继续占用磁盘空间');
      }
    }
    return AssistantCardSaveResult(committed, notices);
  }

  Future<String> _prepareAvatar(
      List<int> bytes, String generation, String extension) async {
    if (bytes.isEmpty ||
        bytes.length > AssistantRoleCardService.maxImportBytes ||
        !const ['.png', '.jpg', '.jpeg'].contains(extension)) {
      throw const FormatException('头像字节或格式无效');
    }
    final base =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    scope.verify();
    final root = appDirectory('${base.path}/chat_avatar');
    final segment =
        scope.accountHash.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final directory = await AccountResourceScope.createManagedDirectory(
        root: root, relativeSegments: [segment]);
    scope.verify();
    final name = 'assistant_operation_$generation$extension';
    await AccountResourceScope.ensureNoLinks(
        root: root, relativeSegments: [segment, name]);
    final file = appFile('${directory.path}/$name');
    await file.create(exclusive: true);
    try {
      await file.writeAsBytes(bytes, flush: true);
      scope.verify();
      await AccountResourceScope.ensureNoLinks(
          root: root, relativeSegments: [segment, name]);
      if (!await AccountResourceScope.isCanonicalDirectChild(file, directory)) {
        throw const FileSystemException('头像文件超出托管目录');
      }
      return file.path;
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

class AssistantCardSaveResult {
  final AssistantMutationResult committed;
  final List<String> notices;
  const AssistantCardSaveResult(this.committed, this.notices);
}
