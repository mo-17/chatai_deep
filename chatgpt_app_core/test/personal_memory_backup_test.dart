import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/backup/personal_memory_backup.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  late HiDBManager source;
  late HiDBManager target;
  late PersonalMemoryDao personal;
  late PersonalMemoryTestAccount auth;
  late Directory tmp;
  Future<HiDBManager> database() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false)));
  Future<void> prefs(PersonalMemoryDao dao) async {
    final p = await dao.preferences();
    await dao.setPreferences(
        revision: p.revision, enabled: true, suggestionsEnabled: true);
  }

  Future<void> seed() async {
    await (await ConversationListDao.create(source))
        .saveConversation(ConversationModel(cid: 1, title: '源', icon: ''));
    final messages = await MessageDao.create(source, cid: 1);
    personal = await PersonalMemoryDao.create(source, accountHash: 'a');
    await prefs(personal);
    await personal.save('手动合成偏好');
    const input = '我希望回答简短清楚';
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, content: input, createdAt: 10));
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.receiver, content: '成功合成回复', createdAt: 11));
    await personal.save('本人消息合成偏好',
        source: await personal.sourceForMessage(1, 10));
    final turn = (await personal.beginTurn(
        cid: 1,
        assistantId: null,
        taskMode: false,
        rawInput: input,
        startedAt: DateTime.now().millisecondsSinceEpoch))!;
    await personal.suggestAfterPersist(turn,
        userCreatedAt: 10, replyCreatedAt: 11);
    final discarded = await personal.save('被删除的合成条目');
    await personal.delete(discarded);
  }

  Future<List<int>> export() => BackupService(source)
      .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
  List<int> rewrite(List<int> bytes,
      void Function(Map<String, List<int>>, Map<String, dynamic>) mutate) {
    final entries = {
      for (final f in ZipDecoder().decodeBytes(bytes).files)
        f.name: List<int>.from(f.content)
    };
    final manifest = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(entries.remove('manifest.json')!)) as Map);
    mutate(entries, manifest);
    manifest['entries'] = {
      for (final e in digestEntries(entries).entries) e.key: e.value.toJson()
    };
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
          'manifest.json', utf8.encode(jsonEncode(manifest))));
    for (final e in entries.entries) {
      archive.addFile(ArchiveFile.bytes(e.key, e.value));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  setUp(() async {
    sqfliteFfiInit();
    auth = PersonalMemoryTestAccount('a')..install();
    source = await database();
    target = await database();
    tmp = await Directory.systemTemp.createTemp('chatai_memory_backup_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${tmp.path}/attachments');
    BackupService.debugGeneratedImageDirectoryResolver = () async => tmp;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => tmp;
    await seed();
  });
  tearDown(() async {
    await source.db.close();
    await target.db.close();
    await tmp.delete(recursive: true);
    ManagedAttachmentStore.debugRootDirectory = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    LoginSdkConfig.reset();
  });
  test('格式12完整counts/digest/preview；overwrite往返保留来源和抑制，授权关闭', () async {
    final bytes = await export();
    final preview =
        await BackupService(target).previewArchive(bytes, accountHash: 'a');
    expect(preview.formatVersion, BackupService.formatVersion);
    expect(preview.personalMemories, 3);
    expect(preview.integrityVerified, isTrue);
    final dao = await PersonalMemoryDao.create(target, accountHash: 'a');
    await prefs(dao);
    final before = await dao.preferences();
    final result =
        await BackupService(target).importArchive(bytes, accountHash: 'a');
    expect(result.personalMemories, 3);
    final rows = await dao.list();
    expect(rows, hasLength(3));
    expect(
        rows.where((m) => m.sourceType == 'user_message').single.invalidReason,
        isEmpty);
    expect(rows.where((m) => m.sourceType == 'local_suggestion').single.status,
        PersonalMemoryStatus.archived);
    expect((await dao.preferences()).enabled, isFalse);
    expect((await dao.preferences()).suggestionsEnabled, isFalse);
    expect((await dao.preferences()).epoch, greaterThan(before.epoch));
    expect(
        await target.db.query('tb_personal_memory_suppression'), hasLength(1));
    expect(await target.db.query('tb_personal_memory_tombstone'), hasLength(1));
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        isEmpty);
    await prefs(dao);
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        contains('本人消息合成偏好'));
  });
  test('merge cid重映射、UUID内容幂等；删除后同次merge重试不复活', () async {
    final bytes = await export();
    await (await ConversationListDao.create(target))
        .saveConversation(ConversationModel(cid: 1, title: '目标', icon: ''));
    final service = BackupService(target);
    final first = await service.importArchive(bytes,
        accountHash: 'a', mode: BackupImportMode.mergeAppend);
    expect(first.personalMemories, 3);
    final dao = await PersonalMemoryDao.create(target, accountHash: 'a');
    final original =
        (await dao.list()).firstWhere((m) => m.sourceType == 'user_message');
    expect(original.sourceCid, isNot(1));
    expect(original.invalidReason, isEmpty);
    await dao.delete(original);
    final second = await service.importArchive(bytes,
        accountHash: 'a', mode: BackupImportMode.mergeAppend);
    expect(second.personalMemories, 0);
    expect(await dao.list(), hasLength(2));
    expect((await dao.preferences()).enabled, isFalse);
    final preview = await service.previewArchive(bytes, accountHash: 'a');
    expect(
        preview.conflictSummary.tableConflicts
            .any((t) => t.table == 'tb_personal_memory'),
        isTrue);
  });
  for (final mode in [
    BackupImportMode.assistantsOnly,
    BackupImportMode.projectConversationsOnly,
    BackupImportMode.knowledgeBaseOnly
  ]) {
    test('$mode 不导入个人表/开关/抑制元数据', () async {
      final dao = await PersonalMemoryDao.create(target, accountHash: 'a');
      await dao.save('本地手动保留');
      await prefs(dao);
      final result = await BackupService(target)
          .importArchive(await export(), accountHash: 'a', mode: mode);
      expect(result.personalMemories, 0);
      expect((await dao.list()).single.content, '本地手动保留');
      expect((await dao.preferences()).enabled, isTrue);
      expect(await target.db.query('tb_personal_memory_suppression'), isEmpty);
    });
  }
  for (final guest in [false, true]) {
    test('${guest ? '游客迁移' : '合并备份'} 来源新快照删除不删除目标同UUID行；目标删除仍阻止旧快照复活',
        () async {
      final oldSnapshot = await export();
      final targetDao =
          await PersonalMemoryDao.create(target, accountHash: 'a');
      final service = BackupService(target);
      await service.importArchive(oldSnapshot,
          accountHash: 'a', mode: BackupImportMode.mergeAppend);
      var kept =
          (await targetDao.list()).singleWhere((m) => m.sourceType == 'manual');
      kept = await targetDao.save('目标本地已编辑并停用的偏好', existing: kept);
      await targetDao.setStatus(kept, PersonalMemoryStatus.archived);
      kept = (await targetDao.list())
          .singleWhere((m) => m.memoryId == kept.memoryId);
      final preserved = kept.toJson();
      final removed = (await targetDao.list())
          .firstWhere((m) => m.sourceType == 'user_message');
      await targetDao.delete(removed);
      final sourceOriginal = (await personal.list())
          .singleWhere((m) => m.memoryId == kept.memoryId);
      await personal.delete(sourceOriginal);
      // 第二个来源快照只含该 UUID 的 tombstone，目标仍持有自己的编辑结果。
      final deletedSnapshot = await export();
      for (var attempt = 0; attempt < 2; attempt++) {
        await prefs(targetDao);
        if (guest) {
          await GuestMigrationService.mergeGuestData(
              from: source,
              to: target,
              idempotencyKey: 'new-snapshot-$attempt');
        } else {
          await service.importArchive(deletedSnapshot,
              accountHash: 'a', mode: BackupImportMode.mergeAppend);
        }
        final rows = await targetDao.list();
        expect(rows.singleWhere((m) => m.memoryId == kept.memoryId).toJson(),
            preserved);
        expect(rows.where((m) => m.memoryId == removed.memoryId), isEmpty);
        expect(
            await target.db.query('tb_personal_memory_tombstone',
                where: 'memoryId=?', whereArgs: [kept.memoryId]),
            isEmpty);
        expect((await targetDao.preferences()).enabled, isFalse);
        expect((await targetDao.preferences()).suggestionsEnabled, isFalse);
      }
      await service.importArchive(oldSnapshot,
          accountHash: 'a', mode: BackupImportMode.mergeAppend);
      expect(
          (await targetDao.list())
              .singleWhere((m) => m.memoryId == kept.memoryId)
              .toJson(),
          preserved);
      expect(
          (await targetDao.list()).where((m) => m.memoryId == removed.memoryId),
          isEmpty);
    });
  }
  test('旧v11按空个人记忆恢复；坏数量/凭证在事务前拒绝且库不变', () async {
    final bytes = await export();
    final legacy = rewrite(bytes, (entries, manifest) {
      manifest['formatVersion'] = 11;
      entries.remove('knowledge_workbench.json');
      (manifest['counts'] as Map).remove('knowledgeWorkbench');
      for (final file in PersonalMemoryBackup.rowFiles.entries) {
        entries.remove(file.key);
        (manifest['counts'] as Map).remove(file.value);
      }
    });
    final dao = await PersonalMemoryDao.create(target, accountHash: 'a');
    await dao.save('本地手动');
    await prefs(dao);
    await BackupService(target).importArchive(legacy, accountHash: 'a');
    expect(await dao.list(), isEmpty);
    expect((await dao.preferences()).enabled, isFalse);
    await dao.save('仍然保留');
    final bad = rewrite(bytes, (entries, manifest) {
      final rows =
          jsonDecode(utf8.decode(entries['personal_memories.json']!)) as List;
      (rows.first as Map)['content'] = 'api_key=synthetic-credential';
      entries['personal_memories.json'] = utf8.encode(jsonEncode(rows));
    });
    await expectLater(
        BackupService(target).importArchive(bad, accountHash: 'a'),
        throwsA(anything));
    expect((await dao.list()).single.content, '仍然保留');
  });
  test('游客迁移个人来源 remap/幂等统计/关闭授权/源账号不变/事务失败回滚', () async {
    await (await ConversationListDao.create(target))
        .saveConversation(ConversationModel(cid: 1, title: '已有', icon: ''));
    final first = await GuestMigrationService.mergeGuestData(
        from: source, to: target, idempotencyKey: 'memory-fixture');
    expect(first.personalMemories, 3);
    final second = await GuestMigrationService.mergeGuestData(
        from: source, to: target, idempotencyKey: 'memory-fixture');
    expect(second.personalMemories, 3);
    final dao = await PersonalMemoryDao.create(target, accountHash: 'a');
    expect(await dao.list(), hasLength(3));
    expect((await dao.preferences()).enabled, isFalse);
    expect((await personal.preferences()).enabled, isTrue);
    expect(
        (await dao.list())
            .firstWhere((m) => m.sourceType == 'user_message')
            .sourceCid,
        isNot(1));
    expect(
        await target.db.query('tb_personal_memory_suppression'), hasLength(1));
    final rollback = await database();
    await PersonalMemoryDao.ensureSchema(rollback.db);
    await rollback.db.execute(
        "create trigger fail_personal before insert on tb_personal_memory begin select raise(abort,'synthetic failure'); end");
    await expectLater(
        GuestMigrationService.mergeGuestData(
            from: source, to: rollback, idempotencyKey: 'failure'),
        throwsA(anything));
    expect(await rollback.db.query('tb_messages'), isEmpty);
    expect(
        await rollback.db.rawQuery(
            "select name from sqlite_master where name='tb_guest_migration_journal'"),
        isEmpty);
    await rollback.db.close();
    auth.account = 'other';
    await expectLater(dao.list(), throwsA(anything));
  });
}
