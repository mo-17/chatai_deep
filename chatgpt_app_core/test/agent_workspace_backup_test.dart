import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/workspace_attachment_processor.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _derivedTables = [
  'tb_agent_task_session',
  'tb_chat_semantic_summary',
  'tb_agent_read_interval',
  'tb_agent_verification_report',
  'tb_agent_verification_turn',
  'tb_agent_task_criteria',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  final databases = <HiDBManager>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace-backup-test-');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/attachments');
    BackupService.debugGeneratedImageDirectoryResolver =
        () async => Directory('${root.path}/images');
    BackupService.debugRoleCardAssetsDirectoryResolver =
        () async => Directory('${root.path}/role-assets');
  });
  tearDown(() async {
    BackupService.debugImportFailureInjector = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    ManagedAttachmentStore.debugRootDirectory = null;
    for (final storage in databases) {
      await storage.db.close();
    }
    databases.clear();
    await root.delete(recursive: true);
  });
  Future<HiDBManager> newDb() async {
    final storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
      '${root.path}/${databases.length}.db',
      options: OpenDatabaseOptions(singleInstance: false),
    ));
    databases.add(storage);
    return storage;
  }

  Future<List<int>> export(HiDBManager storage) =>
      BackupService(storage).exportArchive(
          settings: AISettings.defaults(), accountHash: 'test-account');

  test(
      'v12 roundtrip keeps full text, PDF pages, output revisions and remaps references',
      () async {
    final source = await newDb();
    final sourceFiles = await _seed(source, label: 'source', longText: true);
    final bytes = await export(source);
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifest = _jsonEntry(archive, 'manifest.json') as Map;
    expect(manifest['formatVersion'], BackupService.formatVersion);
    expect(manifest['entries'], contains('workspace_files.json'));
    expect(manifest['entries'], contains('workspace_revisions.json'));
    expect(_jsonEntry(archive, 'workspace_revisions.json'), hasLength(3));

    final target = await newDb();
    final old = await _seed(target, label: 'old');
    await _seedDerived(target);
    await BackupService(target)
        .importArchive(bytes, accountHash: 'test-account');
    final dao = await AgentWorkspaceDao.create(target, cid: 1001);
    final files = await dao.listFiles();
    expect(files, hasLength(2));
    final input = files.singleWhere((file) => file.isInput);
    final output = files.singleWhere((file) => !file.isInput);
    expect(input.id, isNot(old.input.id));
    expect((await dao.getRevision(input.id)).content,
        'source full text\n${'完整文件原文' * 6000}');
    expect((await dao.getRevision(input.id)).pageTexts,
        ['source PDF page 1', 'source PDF page 2']);
    expect((await dao.revisions(output.id)).map((r) => r.content).toList(),
        ['source output v2', 'source output v1']);
    expect(output.revision, 2);
    final message = (await target.db.query('tb_messages')).single;
    final attachment = _workspaceMetadata(message);
    expect(attachment['workspaceFileId'], input.id);
    final description = _description(attachment);
    expect(description['id'], input.id);
    expect(description['cid'], 1001);
    expect(description['name'], 'input-1-1001.pdf');
    expect(message['content'], 'source ordinary numbers 1 1001');
    expect(_ordinaryMetadata(message)['extractedText'], 'ordinary text 1 1001');
    expect(sourceFiles.input.id, old.input.id);
    for (final table in _derivedTables) {
      expect(await target.db.query(table), isEmpty, reason: table);
      expect(archive.findFile('$table.json'), isNull);
    }
  });

  test(
      'older v11 backup clears stale workspace and dangling manifests without changing ordinary files',
      () async {
    final source = await newDb();
    await _seed(source, label: 'source');
    final bytes = _rewriteArchive(await export(source), (entries) {
      entries.remove('workspace_files.json');
      entries.remove('workspace_revisions.json');
    });
    final target = await newDb();
    await _seed(target, label: 'old');
    await BackupService(target)
        .previewArchive(bytes, accountHash: 'test-account');
    await BackupService(target)
        .importArchive(bytes, accountHash: 'test-account');
    expect(await target.db.query(AgentWorkspaceDao.filesTable), isEmpty);
    expect(await target.db.query(AgentWorkspaceDao.revisionsTable), isEmpty);
    final message = (await target.db.query('tb_messages')).single;
    final attachment = _workspaceMetadata(message);
    expect(attachment.containsKey('workspaceFileId'), isFalse);
    final description = _description(attachment);
    expect(description.containsKey('id'), isFalse);
    expect(description.containsKey('cid'), isFalse);
    expect(description['available'], isFalse);
    expect(message['content'], 'source ordinary numbers 1 1001');
    expect(_ordinaryMetadata(message)['extractedText'], 'ordinary text 1 1001');
  });

  test(
      'append merge keeps existing same-named outputs and all imported versions under a new cid',
      () async {
    final source = await newDb();
    await _seed(source, label: 'source');
    final target = await newDb();
    final local = await _seed(target, label: 'local');
    await _seedDerived(target);
    await BackupService(target).importArchive(await export(source),
        accountHash: 'test-account', mode: BackupImportMode.mergeAppend);
    await _expectMerged(target, local);
    for (final table in _derivedTables) {
      expect(await target.db.query(table), hasLength(1), reason: table);
    }
  });

  test(
      'project/conversation overwrite also restores workspace versions and clears derived state',
      () async {
    final source = await newDb();
    await _seed(source, label: 'source');
    final target = await newDb();
    await _seed(target, label: 'local');
    await _seedDerived(target);
    await BackupService(target).importArchive(await export(source),
        accountHash: 'test-account',
        mode: BackupImportMode.projectConversationsOnly);
    final dao = await AgentWorkspaceDao.create(target, cid: 1001);
    final files = await dao.listFiles();
    expect(files, hasLength(2));
    expect(
        (await dao.getRevision(files.singleWhere((f) => !f.isInput).id))
            .content,
        'source output v2');
    expect(
        _workspaceMetadata(
            (await target.db.query('tb_messages')).single)['workspaceFileId'],
        files.singleWhere((f) => f.isInput).id);
    for (final table in _derivedTables) {
      expect(await target.db.query(table), isEmpty, reason: table);
    }
  });

  test(
      'guest merge remaps files and manifests, keeps versions and remains idempotent',
      () async {
    final guest = await newDb();
    await _seed(guest, label: 'source');
    final before = jsonEncode(await guest.db.query('tb_messages'));
    final target = await newDb();
    final local = await _seed(target, label: 'local');
    await _seedDerived(target);
    for (var retry = 0; retry < 2; retry++) {
      final result = await GuestMigrationService.mergeGuestData(
          from: guest, to: target, idempotencyKey: 'workspace-test');
      expect(result.conversations, 1);
      expect(result.messages, 1);
      await _expectMerged(target, local);
    }
    expect(jsonEncode(await guest.db.query('tb_messages')), before);
    expect(await guest.db.query(AgentWorkspaceDao.filesTable), hasLength(2));
    for (final table in _derivedTables) {
      expect(await target.db.query(table), hasLength(1), reason: table);
    }
  });

  test(
      'overwrite failure rolls back workspace, message references and cleared verification state',
      () async {
    final source = await newDb();
    await _seed(source, label: 'source');
    final target = await newDb();
    await _seed(target, label: 'local');
    await _seedDerived(target);
    final originalFiles = await target.db.query(AgentWorkspaceDao.filesTable);
    final originalVersions =
        await target.db.query(AgentWorkspaceDao.revisionsTable);
    final originalMessages = await target.db.query('tb_messages');
    BackupService.debugImportFailureInjector =
        (_) async => throw StateError('injected transaction failure');
    await expectLater(
        BackupService(target)
            .importArchive(await export(source), accountHash: 'test-account'),
        throwsStateError);
    expect(await target.db.query(AgentWorkspaceDao.filesTable), originalFiles);
    expect(await target.db.query(AgentWorkspaceDao.revisionsTable),
        originalVersions);
    expect(await target.db.query('tb_messages'), originalMessages);
    for (final table in _derivedTables) {
      expect(await target.db.query(table), hasLength(1), reason: table);
    }
  });

  test('missing current revision rejects preview and guest merge atomically',
      () async {
    final source = await newDb();
    final files = await _seed(source, label: 'source');
    final bytes = _rewriteArchive(await export(source), (entries) {
      final rows =
          jsonDecode(utf8.decode(entries['workspace_revisions.json']!)) as List;
      rows.removeWhere(
          (row) => row['fileId'] == files.output.id && row['revision'] == 2);
      entries['workspace_revisions.json'] = utf8.encode(jsonEncode(rows));
    });
    final target = await newDb();
    await _seed(target, label: 'local');
    await expectLater(
        BackupService(target)
            .previewArchive(bytes, accountHash: 'test-account'),
        throwsFormatException);
    await source.db.delete(AgentWorkspaceDao.revisionsTable,
        where: 'fileId=? AND revision=2', whereArgs: [files.output.id]);
    final originalMessages = await target.db.query('tb_messages');
    await expectLater(
        GuestMigrationService.mergeGuestData(
            from: source, to: target, idempotencyKey: 'bad-workspace'),
        throwsFormatException);
    expect(await target.db.query('tb_messages'), originalMessages);
    expect(await target.db.query('tb_conversation_list'), hasLength(1));
    expect(await target.db.query(AgentWorkspaceDao.filesTable), hasLength(2));
    final journals = await target.db.query('sqlite_master',
        where: 'name=?', whereArgs: ['tb_guest_migration_journal']);
    expect(journals, isEmpty);
  });
}

Future<({AgentWorkspaceFile input, AgentWorkspaceFile output})> _seed(
    HiDBManager storage,
    {required String label,
    bool longText = false}) async {
  final conversations = await ConversationListDao.create(storage);
  await conversations.saveConversation(ConversationModel(cid: 1001, icon: '')
    ..title = label
    ..updateAt = 1);
  final dao = await AgentWorkspaceDao.create(storage, cid: 1001);
  final content = '$label full text${longText ? '\n${'完整文件原文' * 6000}' : ''}';
  final input = await dao.saveInput(
      name: 'input-1-1001.pdf',
      sourceKey: '/unreadable/source-path/$label.pdf',
      contentHash: '$label-input-hash',
      content: content,
      pageTexts: ['$label PDF page 1', '$label PDF page 2'],
      sizeBytes: utf8.encode(content).length);
  final first = await dao.saveOutput(
      name: 'result.md',
      content: '$label output v1',
      contentHash: '$label-output-v1',
      sizeBytes: 20,
      note: 'first');
  final output = await dao.saveOutput(
      fileId: first.id,
      name: 'result.md',
      content: '$label output v2',
      contentHash: '$label-output-v2',
      sizeBytes: 20,
      note: 'second');
  await MessageDao.create(storage, cid: 1001);
  await storage.db.insert('tb_messages', {
    'cid': 1001,
    'createdAt': 111,
    'ownerType': 'sender',
    'ownerName': 'user',
    'content': '$label ordinary numbers 1 1001',
    'blocks': MessageBlock.encodeList([
      FileBlock(
        id: 'workspace',
        messageId: 'msg_111',
        createdAt: 111,
        status: MessageBlockStatus.success,
          file: FileMetadata(
              name: input.name,
              workspaceFileId: input.id,
              extractedText:
                  WorkspaceAttachmentProcessor.describe(input.toJson()))),
      const FileBlock(
        id: 'ordinary',
        messageId: 'msg_111',
        createdAt: 111,
        status: MessageBlockStatus.success,
          file: FileMetadata(
              name: 'ordinary.txt', extractedText: 'ordinary text 1 1001')),
    ]),
  });
  return (input: input, output: output);
}

Future<void> _seedDerived(HiDBManager storage) async {
  for (final table in _derivedTables) {
    await storage.db
        .execute('CREATE TABLE $table (cid INTEGER, snapshot TEXT)');
    await storage.db.insert(table, {'cid': 1001, 'snapshot': 'local state'});
  }
}

Future<void> _expectMerged(HiDBManager target,
    ({AgentWorkspaceFile input, AgentWorkspaceFile output}) local) async {
  final conversations = await target.db.query('tb_conversation_list');
  expect(conversations, hasLength(2));
  final importedCid =
      conversations.singleWhere((r) => r['title'] == 'source')['cid'] as int;
  expect(importedCid, isNot(1001));
  final localDao = await AgentWorkspaceDao.create(target, cid: 1001);
  expect(
      (await localDao.getRevision(local.output.id)).content, 'local output v2');
  expect((await localDao.revisions(local.output.id)), hasLength(2));
  final dao = await AgentWorkspaceDao.create(target, cid: importedCid);
  final files = await dao.listFiles();
  expect(files, hasLength(2));
  final input = files.singleWhere((f) => f.isInput);
  final output = files.singleWhere((f) => !f.isInput);
  expect(output.name, 'result.md');
  expect((await dao.revisions(output.id)).map((r) => r.content).toList(),
      ['source output v2', 'source output v1']);
  final message = (await target.db
          .query('tb_messages', where: 'cid=?', whereArgs: [importedCid]))
      .single;
  final attachment = _workspaceMetadata(message);
  expect(attachment['workspaceFileId'], input.id);
  expect(_description(attachment)['id'], input.id);
  expect(_description(attachment)['cid'], importedCid);
  expect(message['content'], 'source ordinary numbers 1 1001');
  expect(_ordinaryMetadata(message)['extractedText'], 'ordinary text 1 1001');
  expect(await target.db.query(AgentWorkspaceDao.filesTable), hasLength(4));
}

Map<String, dynamic> _workspaceMetadata(Map<String, Object?> message) =>
    Map<String, dynamic>.from((jsonDecode(message['blocks'] as String) as List)
        .singleWhere((block) => block['id'] == 'workspace')['file'] as Map);
Map<String, dynamic> _ordinaryMetadata(Map<String, Object?> message) =>
    Map<String, dynamic>.from((jsonDecode(message['blocks'] as String) as List)
        .singleWhere((block) => block['id'] == 'ordinary')['file'] as Map);
Map<String, dynamic> _description(Map<String, dynamic> file) =>
    Map<String, dynamic>.from(
        jsonDecode((file['extractedText'] as String).split('\n')[1]) as Map);
Object? _jsonEntry(Archive archive, String name) =>
    jsonDecode(utf8.decode(archive.findFile(name)!.content as List<int>));

List<int> _rewriteArchive(
    List<int> bytes, void Function(Map<String, List<int>> entries) mutate) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final entries = {
    for (final file in archive.files)
      if (file.name != 'manifest.json') file.name: file.content as List<int>,
  };
  mutate(entries);
  final manifest =
      Map<String, dynamic>.from(_jsonEntry(archive, 'manifest.json') as Map);
  manifest['entries'] = {
    for (final digest in digestEntries(entries).entries)
      digest.key: digest.value.toJson(),
  };
  final result = Archive()
    ..addFile(
        ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))));
  for (final entry in entries.entries) {
    result.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(result);
}
