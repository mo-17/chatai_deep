import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_service.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  final stores = <HiDBManager>[];
  late Directory assets;

  setUp(() async {
    assets = await Directory.systemTemp.createTemp('skill_backup_assets');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${assets.path}/attachments');
    BackupService.debugGeneratedImageDirectoryResolver = () async => assets;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => assets;
  });

  tearDown(() async {
    for (final store in stores) {
      await store.db.close();
    }
    stores.clear();
    ManagedAttachmentStore.debugRootDirectory = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    BackupService.debugImportFailureInjector = null;
    await assets.delete(recursive: true);
  });

  Future<HiDBManager> newDb() async {
    final store = HiDBManager.test(await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    ));
    stores.add(store);
    return store;
  }

  Future<AssistantModel> importSkill(
    HiDBManager store, {
    String name = 'writing',
    String reference = '黄金三章和伏笔结构',
  }) async {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
        '$name/SKILL.md',
        utf8.encode('---\nname: $name\ndescription: 小说结构分析\n---\n分析结构。'),
      ))
      ..addFile(ArchiveFile.bytes(
        '$name/references/structure.md',
        utf8.encode(reference),
      ));
    final assistants = await AssistantDao.create(store);
    final result = await SkillImportService.import(
      SkillImportService.parseArchive(ZipEncoder().encodeBytes(archive)),
      assistantDao: assistants,
      knowledgeDao: await KnowledgeDao.create(store),
    );
    return (await assistants.getAssistant(result.assistantId))!;
  }

  Future<List<int>> export(HiDBManager store) =>
      BackupService(store).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'test',
      );

  List<int> rewrite(
    List<int> bytes,
    void Function(Map<String, List<int>> entries) mutate,
  ) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entries = {
      for (final file in archive.files.where((file) => file.isFile))
        file.name: List<int>.from(file.content),
    };
    final manifest = Map<String, dynamic>.from(jsonDecode(
      utf8.decode(entries.remove('manifest.json')!),
    ) as Map);
    mutate(entries);
    manifest['entries'] = {
      for (final entry in digestEntries(entries).entries)
        entry.key: entry.value.toJson(),
    };
    final result = Archive()
      ..addFile(ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(jsonEncode(manifest)),
      ));
    for (final entry in entries.entries) {
      result.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    return ZipEncoder().encodeBytes(result);
  }

  Future<void> expectReference(
    HiDBManager store,
    String name,
    String reference,
  ) async {
    final snapshot = await (await SkillCatalogService.create(store)).prepare();
    expect(snapshot.systemPrompt, contains(name));
    final result = jsonDecode((await snapshot.tools.single.execute({
      'name': name,
      'reference': 'references/structure.md',
    }))
        .content) as Map;
    expect(result['text'], reference);
  }

  test('新 Skill ZIP 导入后覆盖/仅助手/合并恢复都保留精确引用与助手归属', () async {
    final source = await newDb();
    final assistant = await importSkill(source);
    final bytes = await export(source);
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.findFile('skill_catalog.json'), isNotNull);
    final manifest = jsonDecode(utf8.decode(
      archive.findFile('manifest.json')!.content,
    )) as Map;
    expect((manifest['entries'] as Map), contains('skill_catalog.json'));

    for (final mode in [
      BackupImportMode.overwriteAll,
      BackupImportMode.assistantsOnly,
      BackupImportMode.mergeAppend,
    ]) {
      final target = await newDb();
      await importSkill(target, name: 'local', reference: '本地引用');
      final preview = await BackupService(target).previewArchive(
        bytes,
        accountHash: 'test',
      );
      expect(preview.integrityVerified, isTrue);
      await BackupService(target).importArchive(
        bytes,
        accountHash: 'test',
        mode: mode,
      );
      await expectReference(target, 'writing', '黄金三章和伏笔结构');
      final row = (await target.db.query(
        'tb_skill_catalog',
        where: 'name = ?',
        whereArgs: ['writing'],
      ))
          .single;
      expect(row['assistantCreatedAt'], assistant.createdAt);
      if (mode == BackupImportMode.mergeAppend) {
        expect(row['assistantId'], isNot(assistant.id));
        await expectReference(target, 'local', '本地引用');
      } else {
        expect(row['assistantId'], assistant.id);
      }
    }
  });

  test('旧 v11 备份无可选目录时覆盖清空旧记录，原助手 prompt 仍能 fallback', () async {
    final source = await newDb();
    final assistant = await importSkill(source);
    final bytes = rewrite(await export(source), (entries) {
      entries.remove('skill_catalog.json');
    });
    final target = await newDb();
    await importSkill(target, name: 'old-target');
    await BackupService(target).importArchive(bytes, accountHash: 'test');
    expect(await target.db.query('tb_skill_catalog'), isEmpty);
    final restored = (await (await AssistantDao.create(target))
        .getAssistant(assistant.id!))!;
    final snapshot = await (await SkillCatalogService.create(target))
        .prepare(assistant: restored);
    final result = jsonDecode((await snapshot.tools.single.execute({
      'name': 'writing',
    }))
        .content) as Map;
    expect(result['text'], assistant.prompt);
  });

  test('尚无目录表的旧账号导出不产生可选 entry', () async {
    final source = await newDb();
    await (await AssistantDao.create(source)).saveAssistant(
      AssistantModel(name: '普通助手', prompt: '正常提示词'),
    );
    final archive = ZipDecoder().decodeBytes(await export(source));
    expect(archive.findFile('skill_catalog.json'), isNull);
  });

  test('Skill 归属或引用路径损坏在恢复修改数据库前拒绝', () async {
    final source = await newDb();
    await importSkill(source);
    final bytes = await export(source);
    final target = await newDb();
    await importSkill(target, name: 'keep');
    for (final tamper in ['createdAt', 'reference']) {
      final invalid = rewrite(bytes, (entries) {
        final rows =
            jsonDecode(utf8.decode(entries['skill_catalog.json']!)) as List;
        final row = rows.single as Map;
        if (tamper == 'createdAt') {
          row['assistantCreatedAt'] = 0;
        } else {
          final refs = jsonDecode(row['referencesJson'] as String) as List;
          (refs.single as Map)['name'] = '../../secret.txt';
          row['referencesJson'] = jsonEncode(refs);
        }
        entries['skill_catalog.json'] = utf8.encode(jsonEncode(rows));
      });
      await expectLater(
        BackupService(target).previewArchive(invalid, accountHash: 'test'),
        throwsFormatException,
      );
      await expectLater(
        BackupService(target).importArchive(invalid, accountHash: 'test'),
        throwsFormatException,
      );
      await expectReference(target, 'keep', '黄金三章和伏笔结构');
    }
  });

  test('游客 Skill 同事务映射新助手 id、保留原引用，幂等重试不重复导入', () async {
    final guest = await newDb();
    final account = await newDb();
    final guestAssistant = await importSkill(guest);
    final accountAssistant = await importSkill(
      account,
      name: 'local',
      reference: '正式账号已有引用',
    );
    expect(guestAssistant.id, accountAssistant.id);
    for (var i = 0; i < 2; i++) {
      await GuestMigrationService.mergeGuestData(
        from: guest,
        to: account,
        idempotencyKey: 'skill-import-test',
      );
    }
    final rows = await account.db.query('tb_skill_catalog');
    expect(rows, hasLength(2));
    final migrated = rows.singleWhere((row) => row['name'] == 'writing');
    expect(migrated['assistantId'], isNot(guestAssistant.id));
    expect(migrated['assistantCreatedAt'], guestAssistant.createdAt);
    expect(await account.db.query('tb_assistant'), hasLength(2));
    await expectReference(account, 'writing', '黄金三章和伏笔结构');
    await expectReference(account, 'local', '正式账号已有引用');
  });

  test('覆盖会话清理本机任务/摘要派生状态，追加合并保留旧状态', () async {
    final source = await newDb();
    final conversations = await ConversationListDao.create(source);
    await conversations.saveConversation(
      ConversationModel(cid: 123, icon: '')..title = '恢复会话',
    );
    final bytes = await export(source);
    for (final mode in [
      BackupImportMode.overwriteAll,
      BackupImportMode.projectConversationsOnly,
      BackupImportMode.mergeAppend,
    ]) {
      final target = await newDb();
      await (await ConversationListDao.create(target)).saveConversation(
        ConversationModel(cid: 123, icon: '')..title = '本机会话',
      );
      for (final table in [
        'tb_agent_task_session',
        'tb_chat_semantic_summary',
      ]) {
        await target.db.execute(
          'create table $table (cid integer primary key, payload text)',
        );
        await target.db.insert(table, {'cid': 123, 'payload': '旧消息派生状态'});
      }
      await BackupService(target).importArchive(
        bytes,
        accountHash: 'test',
        mode: mode,
      );
      for (final table in [
        'tb_agent_task_session',
        'tb_chat_semantic_summary',
      ]) {
        expect(
          await target.db.query(table),
          mode == BackupImportMode.mergeAppend ? hasLength(1) : isEmpty,
        );
      }
    }
  });

  test('覆盖恢复提交前失败时原 Skill 与任务/摘要清理一同回滚', () async {
    final source = await newDb();
    await importSkill(source);
    final bytes = await export(source);
    final target = await newDb();
    await importSkill(target, name: 'keep', reference: '原始引用');
    for (final table in [
      'tb_agent_task_session',
      'tb_chat_semantic_summary',
    ]) {
      await target.db.execute(
        'create table $table (cid integer primary key, payload text)',
      );
      await target.db.insert(table, {'cid': 123, 'payload': '原派生状态'});
    }
    BackupService.debugImportFailureInjector = (point) async {
      if (point == BackupImportFailurePoint.beforeResourceSwap) {
        throw StateError('injected-before-commit');
      }
    };
    await expectLater(
      BackupService(target).importArchive(bytes, accountHash: 'test'),
      throwsStateError,
    );
    await expectReference(target, 'keep', '原始引用');
    for (final table in [
      'tb_agent_task_session',
      'tb_chat_semantic_summary',
    ]) {
      expect(await target.db.query(table), hasLength(1));
    }
  });
}
