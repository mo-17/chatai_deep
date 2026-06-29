import 'package:chatgpt_app_core/data/knowledge_chunker.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 检索命中的一段知识（L4a）。
class KnowledgeHit {
  final String docTitle;
  final String content;

  const KnowledgeHit({required this.docTitle, required this.content});
}

///知识库数据操作接口（L4a 关键词版）。
abstract class IKnowledge {
  /// 导入一篇文档：切块后落库，返回 docId（文本为空则返回 null，不建文档）。
  Future<int?> addDocument(String title, String text);

  /// 文档列表（按导入时间倒序）。
  Future<List<KnowledgeDoc>> getDocuments();

  /// 删除文档及其全部 chunk。
  Future<int> deleteDocument(int docId);

  /// 关键词检索 chunk：空格分隔的多词为「与」（都命中才返回）。
  Future<List<KnowledgeHit>> search(String query,
      {int limit = 6, int? projectId});
}

/// 知识库 DAO（L4a）。两张表：`tb_kb_doc`（文档元信息）+ `tb_kb_chunk`（切块正文）。
/// 关键词检索用 SQL LIKE（无向量、无新依赖）；向量版留待 L4b。
class KnowledgeDao implements IKnowledge, ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_kb_doc';

  KnowledgeDao._(this.storage);

  /// 静态工厂，确保两张表与索引创建完成后再返回实例。
  static Future<KnowledgeDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_kb_doc (id integer primary key autoincrement'
        ', title text, chunkCount integer, createdAt integer);');
    await storage.db.execute(
        'create table if not exists tb_kb_chunk (id integer primary key autoincrement'
        ', docId integer, seq integer, content text);');
    await storage.db.execute(
        'create index if not exists tb_kb_chunk_doc_idx on tb_kb_chunk(docId);');
    await storage.db.execute(
        'create table if not exists tb_project_kb (projectId integer not null'
        ', docId integer not null, primary key(projectId, docId));');
    await storage.db.execute(
        'create index if not exists tb_project_kb_doc_idx on tb_project_kb(docId);');
    return KnowledgeDao._(storage);
  }

  @override
  Future<int?> addDocument(String title, String text) async {
    final chunks = KnowledgeChunker.split(text);
    if (chunks.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final docId = await storage.db.insert('tb_kb_doc', {
      'title': title.trim().isEmpty ? '未命名文档' : title.trim(),
      'chunkCount': chunks.length,
      'createdAt': now,
    });
    final batch = storage.db.batch();
    for (var i = 0; i < chunks.length; i++) {
      batch.insert(
          'tb_kb_chunk', {'docId': docId, 'seq': i, 'content': chunks[i]});
    }
    await batch.commit(noResult: true);
    AILogger.log('kb add doc "$title" -> $docId (${chunks.length} chunks)');
    return docId;
  }

  @override
  Future<List<KnowledgeDoc>> getDocuments() async {
    final rows = await storage.db.query('tb_kb_doc', orderBy: 'createdAt desc');
    return rows.map((r) => KnowledgeDoc.fromJson(r)).toList();
  }

  @override
  Future<int> deleteDocument(int docId) async {
    await storage.db
        .delete('tb_kb_chunk', where: 'docId = ?', whereArgs: [docId]);
    await storage.db
        .delete('tb_project_kb', where: 'docId = ?', whereArgs: [docId]);
    return storage.db.delete('tb_kb_doc', where: 'id = ?', whereArgs: [docId]);
  }

  @override
  Future<List<KnowledgeHit>> search(String query,
      {int limit = 6, int? projectId}) async {
    final terms =
        query.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) return const [];
    final scopedDocIds =
        projectId == null ? const <int>[] : await getProjectDocIds(projectId);
    final useProjectScope = scopedDocIds.isNotEmpty;
    // 多词「与」：每个词一个 LIKE，全部命中才返回。
    final clauses = <String>[
      ...List.filled(terms.length, 'c.content like ?'),
      if (useProjectScope)
        'c.docId in (${List.filled(scopedDocIds.length, '?').join(',')})',
    ];
    final whereArgs = [
      for (final t in terms) '%$t%',
      if (useProjectScope) ...scopedDocIds,
      limit
    ];
    final rows = await storage.db.rawQuery(
      'select c.content as content, d.title as title '
      'from tb_kb_chunk c left join tb_kb_doc d on d.id = c.docId '
      'where ${clauses.join(' and ')} order by c.id limit ?',
      whereArgs,
    );
    return [
      for (final r in rows)
        KnowledgeHit(
          docTitle: (r['title'] as String?) ?? '(未命名文档)',
          content: (r['content'] as String?) ?? '',
        ),
    ];
  }

  Future<List<int>> getProjectDocIds(int projectId) async {
    final rows = await storage.db.query('tb_project_kb',
        columns: ['docId'], where: 'projectId = ?', whereArgs: [projectId]);
    return [
      for (final row in rows)
        if (row['docId'] is int) row['docId'] as int,
    ];
  }

  Future<void> setProjectDocIds(int projectId, List<int> docIds) async {
    final unique = docIds.toSet().toList();
    await storage.db.transaction((txn) async {
      await txn.delete('tb_project_kb',
          where: 'projectId = ?', whereArgs: [projectId]);
      final batch = txn.batch();
      for (final docId in unique) {
        batch.insert('tb_project_kb', {'projectId': projectId, 'docId': docId});
      }
      await batch.commit(noResult: true);
    });
  }
}
