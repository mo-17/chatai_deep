import 'dart:convert';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_entry.dart';
import 'package:sqflite/sqflite.dart';

abstract class ISkillCatalog {
  Future<void> save(SkillCatalogEntry entry);
  Future<List<SkillCatalogSummary>> list({int limit = 64});
  Future<SkillCatalogEntry?> getForAssistant(int assistantId);
  Future<bool> isCurrentAssistant({
    required int assistantId,
    required int createdAt,
    required String body,
  });
  Future<int> deleteForAssistant(int assistantId);
}

/// 随 HiDBManager 所在账号隔离。正文与引用只来自导入包，不读取磁盘路径。
class SkillCatalogDao implements ISkillCatalog, ITable {
  final HiDBManager storage;

  SkillCatalogDao._(this.storage);

  static const maxTextChars = 1024 * 1024;
  // 保留旧导入器正文预算，并为它已有的引用/脚本桥接说明留出空间。
  static const maxBodyChars = maxTextChars + 64 * 1024;
  static const maxTotalTextChars = 4 * 1024 * 1024;
  static const maxReferences = 256;

  static Future<SkillCatalogDao> create(HiDBManager storage) async {
    await AssistantDao.create(storage);
    await storage.db.execute('''
      create table if not exists tb_skill_catalog (
        assistantId integer primary key,
        assistantCreatedAt integer not null,
        name text not null,
        description text not null,
        body text not null,
        referencesJson text not null
      )
    ''');
    return SkillCatalogDao._(storage);
  }

  @override
  String tableName = 'tb_skill_catalog';

  /// 删除或覆写助手后，旧记录不应被新复用的 assistantId 读到。
  static const _activeOwner = '''
    inner join tb_assistant a on a.id = c.assistantId
      and a.createdAt = c.assistantCreatedAt
      and a.prompt = c.body
  ''';

  static void validateContent({
    required String body,
    required List<SkillCatalogReference> references,
  }) {
    if (body.length > maxBodyChars || references.length > maxReferences) {
      throw const FormatException('技能正文或参考资料数量过大');
    }
    var total = body.length;
    final names = <String>{};
    for (final ref in references) {
      final segments = ref.name.replaceAll('\\', '/').split('/');
      if (ref.name.isEmpty ||
          ref.name.length > 512 ||
          segments.any((part) => part.isEmpty || part == '.' || part == '..') ||
          ref.name.contains(':') ||
          ref.name.contains('\u0000') ||
          !names.add(ref.name)) {
        throw const FormatException('技能参考资料名称不安全或重复');
      }
      if (ref.text.length > maxTextChars) {
        throw const FormatException('技能参考资料过大');
      }
      total += ref.text.length;
      if (total > maxTotalTextChars + 64 * 1024) {
        throw const FormatException('技能文本总量过大');
      }
    }
  }

  @override
  Future<void> save(SkillCatalogEntry entry) async {
    validateContent(body: entry.body, references: entry.references);
    await storage.db.insert(
      tableName,
      {
        'assistantId': entry.assistantId,
        'assistantCreatedAt': entry.assistantCreatedAt,
        'name': entry.name,
        'description': entry.description,
        'body': entry.body,
        'referencesJson': jsonEncode(
          entry.references.map((ref) => ref.toJson()).toList(),
        ),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<SkillCatalogSummary>> list({int limit = 64}) async {
    if (limit < 1 || limit > 128) {
      throw ArgumentError.value(limit, 'limit', '范围为 1 至 128');
    }
    // 目录查询不取 body/referencesJson，避免一开始把全部正文读入内存。
    final rows = await storage.db.rawQuery('''
      select c.assistantId, c.name, c.description
      from $tableName c $_activeOwner
      order by c.assistantId desc limit ?
    ''', [limit]);
    return rows
        .map((row) => SkillCatalogSummary(
              assistantId: row['assistantId'] as int,
              name: row['name'] as String,
              description: row['description'] as String,
            ))
        .toList();
  }

  @override
  Future<SkillCatalogEntry?> getForAssistant(int assistantId) async {
    final rows = await storage.db.rawQuery('''
      select c.* from $tableName c $_activeOwner
      where c.assistantId = ? limit 1
    ''', [assistantId]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final refs = (jsonDecode(row['referencesJson'] as String) as List)
        .map((ref) => SkillCatalogReference.fromJson(
              Map<String, dynamic>.from(ref as Map),
            ))
        .toList();
    final entry = SkillCatalogEntry(
      assistantId: row['assistantId'] as int,
      assistantCreatedAt: row['assistantCreatedAt'] as int,
      name: row['name'] as String,
      description: row['description'] as String,
      body: row['body'] as String,
      references: refs,
    );
    validateContent(body: entry.body, references: entry.references);
    return entry;
  }

  @override
  Future<int> deleteForAssistant(int assistantId) => storage.db.delete(
        tableName,
        where: 'assistantId = ?',
        whereArgs: [assistantId],
      );

  @override
  Future<bool> isCurrentAssistant({
    required int assistantId,
    required int createdAt,
    required String body,
  }) async {
    final rows = await storage.db.query(
      'tb_assistant',
      columns: ['id'],
      where: 'id = ? and createdAt = ? and prompt = ?',
      whereArgs: [assistantId, createdAt, body],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
