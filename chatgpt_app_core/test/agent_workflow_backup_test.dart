import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  late Directory root;
  late PersonalMemoryTestAccount auth;
  final databases = <HiDBManager>[];
  final profiles = {
    for (final r in WorkflowRole.values)
      r: WorkflowModelProfile('local', 'fixture', r.name)
  };
  Future<HiDBManager> database() async {
    final d = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    databases.add(d);
    return d;
  }

  Future<(AgentWorkflowDao, AgentWorkflow)> seed(HiDBManager d, int cid,
      {bool complete = false}) async {
    await (await ConversationListDao.create(d))
        .saveConversation(ConversationModel(cid: cid, title: '合成任务', icon: ''));
    final id = await (await MessageDao.create(d, cid: cid))
        .saveMessageWithBlocks(MessageModel(
            content: '合成任务', ownerType: OwnerType.sender, createdAt: 10));
    final dao = await AgentWorkflowDao.create(d, accountHash: auth.account);
    final scope = AgentWorkflowScope(accountHash: auth.account);
    var w = await dao.createFromSource(scope,
        cid: cid, userRowId: id, profiles: profiles);
    if (complete) {
      w = await dao.claim(scope, w.id, w.revision);
      for (final n in await dao.steps(w.id)) {
        w = await dao.beginStep(scope, WorkflowFence.of(w), n.id,
            inputHash: workflowHash('input'));
        final attempt = await dao.reserveDispatch(
            scope, WorkflowFence.of(w), n.id,
            inputHash: workflowHash('input'), estimatedInput: 1);
        w = await dao.finishAttempt(
            scope, WorkflowFence.of(attempt.workflow), attempt.attemptId!,
            state: WorkflowAttemptState.succeeded, result: '合成已确认成果');
      }
      w = await dao.complete(scope, WorkflowFence.of(w));
      await dao.publishOutputOnce(scope, w, name: 'confirmed.md');
    }
    return (dao, w);
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    auth = PersonalMemoryTestAccount('a')..install();
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('workflow-backup-');
    BackupService.debugGeneratedImageDirectoryResolver = () async => root;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => root;
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/attachments');
  });
  tearDown(() async {
    BackupService.debugImportFailureInjector = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    ManagedAttachmentStore.debugRootDirectory = null;
    for (final d in databases) {
      await d.db.close();
    }
    databases.clear();
    await root.delete(recursive: true);
    LoginSdkConfig.reset();
  });
  for (final mode in BackupImportMode.values) {
    test('备份13 ${mode.name} 不导入执行授权；覆盖清理派生，合并/选择性保留本地记录', () async {
      final source = await database(), target = await database();
      final (_, sourceTask) = await seed(source, 1, complete: true);
      final (targetDao, targetTask) = await seed(target, 2);
      final bytes = await BackupService(source)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.any((f) => f.name.contains('workflow')), false);
      final manifest = jsonDecode(utf8.decode(
          archive.findFile('manifest.json')!.content as List<int>)) as Map;
      expect(manifest['formatVersion'], 13);
      final captured = AgentWorkflowScope(accountHash: 'a');
      await BackupService(target)
          .importArchive(bytes, accountHash: 'a', mode: mode);
      expect(captured.identityCurrent, false);
      final replaces = const [
        BackupImportMode.overwriteAll,
        BackupImportMode.projectConversationsOnly
      ].contains(mode);
      expect(await targetDao.read(targetTask.id),
          replaces ? null : isA<AgentWorkflow>());
      expect(await targetDao.read(sourceTask.id), null);
      if (replaces) {
        for (final table in [
          AgentWorkflowDao.stepTable,
          AgentWorkflowDao.attempts,
          AgentWorkflowDao.publications,
          AgentWorkflowDao.outputPublications
        ]) {
          expect(await target.db.query(table), isEmpty);
        }
      }
      if (mode == BackupImportMode.overwriteAll ||
          mode == BackupImportMode.mergeAppend ||
          mode == BackupImportMode.projectConversationsOnly) {
        final rows = await target.db.query(AgentWorkspaceDao.filesTable,
            where: "kind='output' AND name='confirmed.md'");
        expect(rows, hasLength(1));
        final version = await target.db.query(AgentWorkspaceDao.revisionsTable,
            where: 'fileId=?', whereArgs: [rows.single['id']]);
        expect(version.single['content'], '合成已确认成果');
      }
    });
  }
  test('恢复事务等待/回滚也撤销旧dispatch身份，成功通知tick不能代替维护栅栏', () async {
    final d = await database();
    await seed(d, 1);
    final bytes = await BackupService(d)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
    final captured = AgentWorkflowScope(accountHash: 'a');
    final oldTick = BackupService.restoreTick.value;
    final entered = Completer<void>(), release = Completer<void>();
    BackupService.debugImportFailureInjector = (point) async {
      if (point == BackupImportFailurePoint.beforeResourceSwap) {
        entered.complete();
        await release.future;
        throw StateError('合成回滚');
      }
    };
    final operation = BackupService(d).importArchive(bytes, accountHash: 'a');
    final check = expectLater(operation, throwsStateError);
    await entered.future.timeout(const Duration(seconds: 5));
    expect(BackupService.restoreTick.value, oldTick);
    expect(captured.identityCurrent, false);
    expect(captured.verify, throwsA(isA<WorkflowStale>()));
    release.complete();
    await check;
    expect(await d.db.query(AgentWorkflowDao.workflows), hasLength(1));
    expect(BackupService.restoreTick.value, oldTick);
  });
  test('游客迁移只带已确认工作区成果，不复制父/节点/attempt或后台授权', () async {
    final guest = await database(), target = await database();
    auth.account = 'guest';
    final (_, guestTask) = await seed(guest, 1, complete: true);
    auth.account = 'a';
    final (targetDao, existing) = await seed(target, 1);
    final prior = (await targetDao.read(existing.id))!.toRow();
    await GuestMigrationService.mergeGuestData(
        from: guest, to: target, idempotencyKey: 'workflow-fixture');
    expect(await targetDao.read(guestTask.id), null);
    expect((await targetDao.read(existing.id))!.toRow(), prior);
    expect(
        await target.db.query(AgentWorkspaceDao.filesTable,
            where: "kind='output' AND name='confirmed.md'"),
        hasLength(1));
    expect(await target.db.query(AgentWorkflowDao.workflows), hasLength(1));
    expect(await guest.db.query(AgentWorkflowDao.workflows), hasLength(1));
  });
}
