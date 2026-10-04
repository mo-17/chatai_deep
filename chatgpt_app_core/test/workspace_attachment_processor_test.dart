import 'dart:io';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/workspace_attachment_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_workspace_page.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('任务附件清单不灌入全文，持久副本保留旧字符上限之外的尾部', () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-attachments-');
    addTearDown(() => directory.delete(recursive: true));
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${directory.path}/managed');
    addTearDown(() => ManagedAttachmentStore.debugRootDirectory = null);
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final workspace =
        await AgentWorkspaceService.create(HiDBManager.test(db), cid: 71);
    final source = File('${directory.path}/novel.txt');
    const tail = 'TAIL_BEYOND_OLD_LIMIT';
    await source.writeAsString('${List.filled(250000, '文').join()}\n$tail');
    final processed = await WorkspaceAttachmentProcessor(workspace)
        .process([source.path], limits: const AttachmentProcessingLimits());
    expect(processed.extraText.length, lessThan(4000));
    expect(processed.extraText, isNot(contains(tail)));
    expect(processed.metas.single.workspaceFileId, isNotNull);
    final reloaded = FileMetadata.fromJson(processed.metas.single.toJson());
    final id = reloaded.workspaceFileId!;
    expect((await workspace.getRevision(id)).content, endsWith(tail));
    expect(
        (await workspace.readFile(id, tail: true))['content'], contains(tail));
    await source.delete();
    expect((await workspace.getRevision(id)).content, endsWith(tail));
  });

  test('旧附件字段仍按原值恢复，新引用可选且不改变文本', () {
    final legacy =
        FileMetadata.fromJson({'name': 'old.txt', 'extractedText': '原来的附件正文'});
    expect(legacy.workspaceFileId, isNull);
    expect(legacy.extractedText, '原来的附件正文');
    expect(legacy.toJson().containsKey('workspaceFileId'), isFalse);
  });

  test('删除当前对话清理文件版本，不影响其他对话', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final manager = HiDBManager.test(db);
    final first = await AgentWorkspaceService.create(manager, cid: 1);
    final other = await AgentWorkspaceService.create(manager, cid: 2);
    final file = await first.writeFile(name: 'first.md', content: '第一版');
    await first.writeFile(name: 'first.md', content: '第二版');
    await other.writeFile(name: 'other.md', content: '应保留');
    await db.execute(
        'create table tb_messages(id integer primary key, cid integer)');
    final conversations = await ConversationListDao.create(manager);
    await conversations.deleteConversation(ConversationModel(cid: 1, icon: ''));
    expect(await first.listFiles(), isEmpty);
    expect(
        await db.query('tb_agent_workspace_revisions',
            where: 'fileId = ?', whereArgs: [file.id]),
        isEmpty);
    expect((await other.listFiles()).single.name, 'other.md');
  });

  test('版本差异保留改动并限制大文件渲染量', () {
    expect(workspaceVersionDiff('第一行\n旧正文\n结尾', '第一行\n新正文\n结尾'),
        '@@ 第 2 行 @@\n- 旧正文\n+ 新正文');
    final result = workspaceVersionDiff(List.filled(1000, 'old').join('\n'),
        List.filled(1000, 'new').join('\n'));
    expect(result.split('\n').length, lessThan(410));
    expect(result, contains('可导出完整版本'));
  });
}
