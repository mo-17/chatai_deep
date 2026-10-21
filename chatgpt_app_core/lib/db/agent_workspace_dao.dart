import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';

abstract class IAgentWorkspace {
  Future<List<AgentWorkspaceFile>> listFiles();
  Future<AgentWorkspaceFile?> getFile(int id);
  Future<AgentWorkspaceRevision> getRevision(int fileId, {int? revision});
  Future<List<AgentWorkspaceRevision>> revisions(int fileId);
}

/// 账号数据库中的对话文件。输入不可变；输出正文保存在版本表。
class AgentWorkspaceDao implements IAgentWorkspace, ITable {
  static const filesTable = 'tb_agent_workspace_files';
  static const revisionsTable = 'tb_agent_workspace_revisions';
  final HiDBManager storage;
  final int cid;

  @override
  String tableName = filesTable;

  AgentWorkspaceDao._(this.storage, this.cid);

  static Future<AgentWorkspaceDao> create(HiDBManager storage,
      {required int cid}) async {
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $filesTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cid INTEGER NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('input','output')),
      currentRevision INTEGER NOT NULL,
      sourceKey TEXT NOT NULL DEFAULT '',
      contentHash TEXT NOT NULL,
      sizeBytes INTEGER NOT NULL,
      characterCount INTEGER NOT NULL,
      lineCount INTEGER NOT NULL,
      pageCount INTEGER NOT NULL,
      sections TEXT NOT NULL DEFAULT '[]',
      sectionCount INTEGER NOT NULL DEFAULT 0,
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL
    )''');
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $revisionsTable (
      fileId INTEGER NOT NULL,
      revision INTEGER NOT NULL,
      content TEXT NOT NULL,
      pageTexts TEXT NOT NULL DEFAULT '[]',
      note TEXT NOT NULL DEFAULT '',
      createdAt INTEGER NOT NULL,
      PRIMARY KEY(fileId, revision)
    )''');
    await storage.db.execute('CREATE INDEX IF NOT EXISTS '
        'agent_workspace_cid_idx ON $filesTable(cid, id)');
    await storage.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS '
        'agent_workspace_input_idx ON $filesTable(cid, sourceKey, contentHash) '
        "WHERE kind='input'");
    await storage.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS '
        'agent_workspace_output_idx ON $filesTable(cid, name) '
        "WHERE kind='output'");
    return AgentWorkspaceDao._(storage, cid);
  }

  @override
  Future<List<AgentWorkspaceFile>> listFiles() async {
    final rows = await storage.db
        .query(filesTable, where: 'cid=?', whereArgs: [cid], orderBy: 'id ASC');
    return rows.map(AgentWorkspaceFile.fromJson).toList();
  }

  @override
  Future<AgentWorkspaceFile?> getFile(int id) async {
    final rows = await storage.db.query(filesTable,
        where: 'id=? AND cid=?', whereArgs: [id, cid], limit: 1);
    return rows.isEmpty ? null : AgentWorkspaceFile.fromJson(rows.single);
  }

  @override
  Future<AgentWorkspaceRevision> getRevision(int fileId,
      {int? revision}) async {
    final rows = await storage.db.rawQuery('''SELECT r.* FROM $revisionsTable r
      JOIN $filesTable f ON f.id=r.fileId
      WHERE f.id=? AND f.cid=? AND r.revision=${revision == null ? 'f.currentRevision' : '?'}''',
        [fileId, cid, if (revision != null) revision]);
    if (rows.isEmpty) throw const FormatException('工作区文件或版本不存在');
    return AgentWorkspaceRevision.fromJson(rows.single);
  }

  @override
  Future<List<AgentWorkspaceRevision>> revisions(int fileId) async {
    if (await getFile(fileId) == null) {
      throw const FormatException('工作区文件不存在');
    }
    final rows = await storage.db.rawQuery('''SELECT r.* FROM $revisionsTable r
      JOIN $filesTable f ON f.id=r.fileId
      WHERE f.id=? AND f.cid=? ORDER BY r.revision DESC''', [fileId, cid]);
    return rows.map(AgentWorkspaceRevision.fromJson).toList();
  }

  Future<AgentWorkspaceFile> saveInput({
    required String name,
    required String sourceKey,
    required String contentHash,
    required String content,
    required List<String> pageTexts,
    required int sizeBytes,
    List<Map<String, dynamic>> sections = const [],
    bool Function()? canCommit,
  }) async {
    return storage.db.transaction((txn) async {
      void check() {
        if (canCommit?.call() == false) throw StateError('任务已停止，工作区未修改');
      }

      check();
      final existing = await txn.query(filesTable,
          where: "cid=? AND kind='input' AND sourceKey=? AND contentHash=?",
          whereArgs: [cid, sourceKey, contentHash],
          limit: 1);
      if (existing.isNotEmpty) {
        check();
        return AgentWorkspaceFile.fromJson(existing.single);
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = _metadata(name, 'input', 1, sourceKey, contentHash, content,
          pageTexts, sizeBytes, now);
      row['sections'] = jsonEncode(_briefSections(sections));
      row['sectionCount'] = sections.length;
      final id = await txn.insert(filesTable, row);
      await txn.insert(
          revisionsTable, _revision(id, 1, content, pageTexts, '', now));
      check();
      return AgentWorkspaceFile.fromJson({...row, 'id': id});
    });
  }

  Future<AgentWorkspaceFile> saveOutput({
    int? fileId,
    required String name,
    required String content,
    required String contentHash,
    required int sizeBytes,
    required String note,
    List<Map<String, dynamic>> sections = const [],
    bool Function()? canCommit,
    Transaction? transaction,
  }) async {
    Future<AgentWorkspaceFile> save(Transaction txn) async {
      void checkExecution() {
        if (canCommit != null && !canCommit()) {
          throw StateError('任务已停止，工作区未修改');
        }
      }

      checkExecution();
      if (canCommit != null) {
        final parent = await txn.query('tb_conversation_list',
            columns: ['cid'], where: 'cid=?', whereArgs: [cid], limit: 1);
        checkExecution();
        if (parent.isEmpty) throw StateError('原对话已删除，工作区未修改');
      }
      final rows = await txn.query(filesTable,
          where: fileId == null
              ? "cid=? AND kind='output' AND name=?"
              : 'cid=? AND id=?',
          whereArgs: [cid, fileId ?? name],
          limit: 1);
      checkExecution();
      if (fileId != null && rows.isEmpty) {
        throw const FormatException('工作区文件不存在');
      }
      final old =
          rows.isEmpty ? null : AgentWorkspaceFile.fromJson(rows.single);
      if (old?.isInput ?? false) throw const FormatException('输入文件只读，不能覆盖');
      if (old != null && old.name != name) {
        throw const FormatException('请使用原输出文件名，或不传 fileId 创建新文件');
      }
      if (old != null && old.contentHash == contentHash) return old;
      final now = DateTime.now().millisecondsSinceEpoch;
      final revision = (old?.revision ?? 0) + 1;
      final row = _metadata(name, 'output', revision, '', contentHash, content,
          const [], sizeBytes, now);
      row['sections'] = jsonEncode(_briefSections(sections));
      row['sectionCount'] = sections.length;
      row['createdAt'] = old?.createdAt ?? now;
      final id = old?.id ?? await txn.insert(filesTable, row);
      if (old != null) {
        checkExecution();
        await txn.update(filesTable, row,
            where: 'id=? AND cid=?', whereArgs: [id, cid]);
      }
      checkExecution();
      await txn.insert(revisionsTable,
          _revision(id, revision, content, const [], note, now));
      // 取消可能发生在任意 SQLite await；提交前拒绝会回滚整份输出事务。
      checkExecution();
      return AgentWorkspaceFile.fromJson({...row, 'id': id});
    }

    return transaction != null
        ? save(transaction)
        : storage.db.transaction(save);
  }

  Map<String, Object?> _metadata(
          String name,
          String kind,
          int revision,
          String sourceKey,
          String hash,
          String content,
          List<String> pages,
          int bytes,
          int now) =>
      {
        'cid': cid,
        'name': name,
        'kind': kind,
        'currentRevision': revision,
        'sourceKey': sourceKey,
        'contentHash': hash,
        'sizeBytes': bytes,
        'characterCount': content.length,
        'lineCount': content.isEmpty ? 0 : '\n'.allMatches(content).length + 1,
        'pageCount': pages.length,
        'createdAt': now,
        'updatedAt': now,
      };

  Map<String, Object?> _revision(int id, int revision, String content,
          List<String> pages, String note, int now) =>
      {
        'fileId': id,
        'revision': revision,
        'content': content,
        'pageTexts': jsonEncode(pages),
        'note': note,
        'createdAt': now,
      };

  List<Map<String, dynamic>> _briefSections(
          List<Map<String, dynamic>> sections) =>
      sections.take(40).map((section) {
        final title = section['title'] as String;
        var end = title.length.clamp(0, 80);
        if (end < title.length &&
            end > 0 &&
            title.codeUnitAt(end - 1) >= 0xD800 &&
            title.codeUnitAt(end - 1) <= 0xDBFF &&
            title.codeUnitAt(end) >= 0xDC00 &&
            title.codeUnitAt(end) <= 0xDFFF) {
          end--;
        }
        return {
          ...section,
          'title': title.substring(0, end),
          if (end < title.length) 'titleTruncated': true
        };
      }).toList();
}
