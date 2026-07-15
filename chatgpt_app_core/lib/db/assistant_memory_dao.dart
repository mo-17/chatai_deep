import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:sqflite/sqflite.dart';

abstract class IAssistantMemory {
  Future<int?> saveMemory(AssistantMemoryModel model);

  Future<List<AssistantMemoryModel>> getMemories(int assistantId,
      {int limit = 20});

  Future<int> deleteMemory(int id);
}

class AssistantMemoryDao implements IAssistantMemory, ITable {
  final HiDBManager storage;

  AssistantMemoryDao._(this.storage);

  static const _kTableName = 'tb_assistant_memory';

  @override
  String tableName = _kTableName;

  static Future<AssistantMemoryDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', assistantId integer, content text, source text'
        ', createdAt integer, updatedAt integer'
        ', memoryId text, assistantSyncId text, sourceType text'
        ', sourceConversationId text, sourceMessageId text, status text'
        ', confirmedByUser integer, revision integer);');
    for (final column in const [
      'memoryId text',
      'assistantSyncId text',
      'sourceType text',
      'sourceConversationId text',
      'sourceMessageId text',
      'status text',
      'confirmedByUser integer',
      'revision integer',
    ]) {
      try {
        await storage.db.execute('alter table $_kTableName add column $column');
      } catch (_) {
        // 旧库逐列补齐；列已存在时保持原数据不动。
      }
    }
    await storage.db.execute(
      "update $_kTableName set memoryId = 'legacy:' || "
      "coalesce(assistantId, 0) || ':' || id "
      "where memoryId is null or trim(memoryId) = ''",
    );
    await storage.db.execute(
      "update $_kTableName set assistantSyncId = 'legacy:' || "
      'coalesce(assistantId, 0) '
      "where assistantSyncId is null or trim(assistantSyncId) = ''",
    );
    await storage.db.execute(
      "update $_kTableName set sourceType = 'legacy' "
      "where sourceType is null or trim(sourceType) = ''",
    );
    await storage.db.execute(
      "update $_kTableName set sourceConversationId = '' "
      'where sourceConversationId is null',
    );
    await storage.db.execute(
      "update $_kTableName set sourceMessageId = '' "
      'where sourceMessageId is null',
    );
    await storage.db.execute(
      "update $_kTableName set status = 'active' "
      'where status is null',
    );
    await storage.db.execute(
      'update $_kTableName set confirmedByUser = 1 '
      'where confirmedByUser is null',
    );
    await storage.db.execute(
      'update $_kTableName set revision = 1 '
      'where revision is null or revision < 1',
    );
    await storage.db.execute(
        'create index if not exists idx_assistant_memory_assistant_updated '
        'on $_kTableName(assistantId, updatedAt desc);');
    await _repairDuplicateMemoryIdsAndCreateIndex(storage);
    return AssistantMemoryDao._(storage);
  }

  static Future<void> _repairDuplicateMemoryIdsAndCreateIndex(
    HiDBManager storage,
  ) async {
    await storage.db.transaction((txn) async {
      final identityRows = await txn.query(
        _kTableName,
        columns: const ['memoryId'],
        where: "memoryId is not null and trim(memoryId) <> ''",
      );
      final used = identityRows
          .map((row) => row['memoryId']?.toString() ?? '')
          .where((identity) => identity.isNotEmpty)
          .toSet();
      final duplicates = await txn.rawQuery(
        'select memoryId from $_kTableName '
        'where memoryId is not null '
        'group by memoryId having count(*) > 1',
      );
      for (final duplicate in duplicates) {
        final memoryId = duplicate['memoryId']?.toString() ?? '';
        if (memoryId.isEmpty) continue;
        final rows = await txn.query(
          _kTableName,
          columns: const ['id'],
          where: 'memoryId = ?',
          whereArgs: [memoryId],
          orderBy: 'id asc',
        );
        for (final row in rows.skip(1)) {
          var replacement = generateUuidV4();
          while (used.contains(replacement)) {
            replacement = generateUuidV4();
          }
          used.add(replacement);
          await txn.update(
            _kTableName,
            {'memoryId': replacement},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
      await txn.execute(
        'create unique index if not exists '
        'idx_assistant_memory_memory_id_uq '
        'on $_kTableName(memoryId)',
      );
    });
  }

  @override
  Future<int?> saveMemory(AssistantMemoryModel model) async {
    final content = model.content.trim();
    if (content.isEmpty || (model.id == null && model.assistantId <= 0)) {
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (model.id == null) {
      model
        ..content = content
        ..updatedAt = now
        ..memoryId = model.memoryId.trim().isEmpty
            ? generateUuidV4()
            : model.memoryId.trim()
        ..assistantSyncId = model.assistantSyncId.trim().isEmpty
            ? 'legacy:${model.assistantId}'
            : model.assistantSyncId.trim()
        ..sourceType = model.sourceType.trim().isEmpty
            ? model.source.trim()
            : model.sourceType.trim()
        ..sourceConversationId = model.sourceConversationId.trim()
        ..sourceMessageId = model.sourceMessageId.trim()
        ..revision = model.revision < 1 ? 1 : model.revision
        ..createdAt = now;
      final data = model.toJson()..remove('id');
      try {
        final id = await storage.db.insert(tableName, data);
        model.id = id;
        return id;
      } on DatabaseException catch (error) {
        if (error.isUniqueConstraintError()) return null;
        rethrow;
      }
    }

    final saved =
        await storage.db.transaction<AssistantMemoryModel?>((txn) async {
      final existingRows = await txn.query(
        tableName,
        where: 'id = ?',
        whereArgs: [model.id],
        limit: 1,
      );
      if (existingRows.isEmpty) return null;
      final existing = AssistantMemoryModel.fromJson(existingRows.single);
      final existingSourceType = existing.sourceType;
      existing
        ..content = content
        ..source = model.source
        ..updatedAt = now
        ..sourceType = model.sourceType.trim().isEmpty
            ? existingSourceType
            : model.sourceType.trim()
        ..sourceConversationId = model.sourceConversationId.trim()
        ..sourceMessageId = model.sourceMessageId.trim()
        ..status = model.status
        ..confirmedByUser = model.confirmedByUser;
      existing.revision += 1;
      final updated = await txn.update(
        tableName,
        existing.toJson(),
        where: 'id = ?',
        whereArgs: [existing.id],
      );
      return updated == 1 ? existing : null;
    });
    if (saved == null) return null;
    _copyPersistedFields(saved, model);
    return model.id;
  }

  static void _copyPersistedFields(
    AssistantMemoryModel source,
    AssistantMemoryModel target,
  ) {
    target
      ..id = source.id
      ..assistantId = source.assistantId
      ..content = source.content
      ..source = source.source
      ..createdAt = source.createdAt
      ..updatedAt = source.updatedAt
      ..memoryId = source.memoryId
      ..assistantSyncId = source.assistantSyncId
      ..sourceType = source.sourceType
      ..sourceConversationId = source.sourceConversationId
      ..sourceMessageId = source.sourceMessageId
      ..status = source.status
      ..confirmedByUser = source.confirmedByUser
      ..revision = source.revision;
  }

  @override
  Future<List<AssistantMemoryModel>> getMemories(int assistantId,
      {int limit = 20}) async {
    if (assistantId <= 0) return const [];
    final rows = await storage.db.query(
      tableName,
      where: 'assistantId = ?',
      whereArgs: [assistantId],
      orderBy: 'updatedAt desc, id desc',
      limit: limit.clamp(1, 100),
    );
    return rows.map((row) => AssistantMemoryModel.fromJson(row)).toList();
  }

  Future<List<AssistantMemoryModel>> getActiveMemories(int assistantId,
      {int limit = 20}) async {
    if (assistantId <= 0) return const [];
    final rows = await storage.db.query(
      tableName,
      where: 'assistantId = ? and status = ? and confirmedByUser = 1',
      whereArgs: [assistantId, AssistantMemoryStatus.active.name],
      orderBy: 'updatedAt desc, id desc',
      limit: limit.clamp(1, 100),
    );
    return rows.map((row) => AssistantMemoryModel.fromJson(row)).toList();
  }

  @override
  Future<int> deleteMemory(int id) {
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  static String buildSystemContext(List<AssistantMemoryModel> memories,
      {int limit = 8}) {
    final items = memories
        .where((memory) =>
            memory.status == AssistantMemoryStatus.active &&
            memory.confirmedByUser &&
            memory.content.trim().isNotEmpty)
        .take(limit.clamp(1, 50))
        .map((memory) => '- ${memory.content.trim()}')
        .toList();
    if (items.isEmpty) return '';
    return '[长期记忆]\n${items.join('\n')}';
  }

  static bool hasDuplicateContent(
    List<AssistantMemoryModel> memories,
    String content,
  ) {
    final normalized = _normalizeContent(content);
    if (normalized.isEmpty) return false;
    return memories
        .map((memory) => _normalizeContent(memory.content))
        .any((item) => item == normalized);
  }

  static String _normalizeContent(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), '');
}
