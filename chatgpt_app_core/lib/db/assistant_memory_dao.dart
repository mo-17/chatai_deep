import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';

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
        ', createdAt integer, updatedAt integer);');
    await storage.db.execute(
        'create index if not exists idx_assistant_memory_assistant_updated '
        'on $_kTableName(assistantId, updatedAt desc);');
    return AssistantMemoryDao._(storage);
  }

  @override
  Future<int?> saveMemory(AssistantMemoryModel model) async {
    final content = model.content.trim();
    if (content.isEmpty || model.assistantId <= 0) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    model
      ..content = content
      ..updatedAt = now;
    if (model.id == null) {
      model.createdAt = now;
      final data = model.toJson()..remove('id');
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      return id;
    }
    await storage.db.update(
      tableName,
      model.toJson(),
      where: 'id = ?',
      whereArgs: [model.id],
    );
    return model.id;
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

  @override
  Future<int> deleteMemory(int id) {
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  static String buildSystemContext(List<AssistantMemoryModel> memories,
      {int limit = 8}) {
    final items = memories
        .where((memory) => memory.content.trim().isNotEmpty)
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
