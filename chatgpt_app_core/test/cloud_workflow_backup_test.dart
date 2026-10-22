import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/cloud_workflow_fixture.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager db;
  late CloudWorkflowDao dao;
  late Directory root;
  late PersonalMemoryTestAccount auth;
  late CloudLocalReceipt receipt;
  late CloudFixtureResult cloud;
  AgentWorkflowScope scope() => AgentWorkflowScope(accountHash: 'a');
  setUp(() async {
    auth = PersonalMemoryTestAccount('a')..install();
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('chatai-cloud-C2-backup-');
    BackupService.debugGeneratedImageDirectoryResolver = () async => root;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => root;
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/attachments');
    db = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(db))
        .saveConversation(ConversationModel(cid: 1, title: '仅合成', icon: ''));
    final id = await (await MessageDao.create(db, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: '仅本次任务', ownerType: OwnerType.sender, createdAt: 1));
    dao = await CloudWorkflowDao.create(db, accountHash: 'a');
    final source = await dao.capture(scope(), cid: 1, messageId: id);
    final payload = cloudFixturePayload(source);
    cloud = CloudFixtureResult(payload);
    final local = await dao.recordSubmission(scope(),
        origin: cloudFixtureOrigin,
        ownerId: 7,
        snapshot: source,
        payload: payload);
    receipt = await dao.bindReceipt(
        scope(), local.receipt, CloudServerReceipt.fromJson(cloud.receipt()));
  });
  tearDown(() async {
    BackupService.debugImportFailureInjector = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    ManagedAttachmentStore.debugRootDirectory = null;
    await db.db.close();
    await root.delete(recursive: true);
    LoginSdkConfig.reset();
  });
  for (final mode in BackupImportMode.values) {
    test('真实备份 ${mode.name} 不导出cloud关联且旧来源永久失效', () async {
      final bytes = await BackupService(db)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.any((f) => f.name.contains('cloud')), false);
      final manifest = jsonDecode(
          utf8.decode(archive.findFile('manifest.json')!.content as List<int>));
      expect(manifest['formatVersion'], BackupService.formatVersion);
      final old = scope();
      await BackupService(db)
          .importArchive(bytes, accountHash: 'a', mode: mode);
      expect(old.identityCurrent, false);
      await expectLater(
          dao.publish(scope(), receipt, cloud.parsedDetail, cloud.parsedResult),
          throwsStateError);
      expect(await db.db.query('tb_cloud_publications'), isEmpty);
      expect((await db.db.query('tb_cloud_sources')).single['valid'], 0);
    });
  }
  test('恢复失败回滚后重新取得scope仍不能补签旧receipt', () async {
    final bytes = await BackupService(db)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
    final original = await db.db.query('tb_messages');
    BackupService.debugImportFailureInjector = (point) async {
      if (point == BackupImportFailurePoint.beforeResourceSwap) {
        throw StateError('合成回滚');
      }
    };
    await expectLater(BackupService(db).importArchive(bytes, accountHash: 'a'),
        throwsStateError);
    expect(await db.db.query('tb_messages'), original);
    await expectLater(
        dao.publish(scope(), receipt, cloud.parsedDetail, cloud.parsedResult),
        throwsStateError);
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
  });
  test('无sidecar旧库恢复不初始化云表，也不改变备份清单', () async {
    final old = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    try {
      await (await ConversationListDao.create(old))
          .saveConversation(ConversationModel(cid: 2, title: '旧库', icon: ''));
      final backup = BackupService(old);
      final bytes = await backup.exportArchive(
          settings: AISettings.defaults(), accountHash: 'a');
      await backup.importArchive(bytes, accountHash: 'a');
      expect(
          await old.db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'tb_cloud_%'"),
          isEmpty);
    } finally {
      await old.db.close();
    }
  });
  test('游客迁移不复制receipt/source/publication/stop权限', () async {
    final target = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    try {
      await CloudWorkflowDao.create(target, accountHash: 'b');
      auth.account = 'b';
      await GuestMigrationService.mergeGuestData(
          from: db, to: target, idempotencyKey: 'synthetic-cloud-C2');
      for (final table in [
        'tb_cloud_receipts',
        'tb_cloud_sources',
        'tb_cloud_publications',
        'tb_cloud_stop_intents'
      ]) {
        expect(await target.db.query(table), isEmpty);
      }
      expect(await db.db.query('tb_cloud_receipts'), hasLength(1));
    } finally {
      await target.db.close();
    }
  });
}
