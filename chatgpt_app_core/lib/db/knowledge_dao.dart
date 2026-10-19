import 'dart:convert';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/data/knowledge_chunker.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 检索命中的一段知识（L4a）。
class KnowledgeHit {
  final String docTitle;
  final String content;

  const KnowledgeHit({required this.docTitle, required this.content});
}

class KnowledgeVectorIndexStats {
  final int chunks;
  final int indexed;

  const KnowledgeVectorIndexStats({
    required this.chunks,
    required this.indexed,
  });

  int get missing => chunks - indexed;
  bool get isComplete => missing <= 0;
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
        'create table if not exists tb_kb_vector (chunkId integer primary key'
        ', docId integer not null, vector text not null, updatedAt integer not null);');
    await storage.db.execute(
        'create index if not exists tb_kb_chunk_doc_idx on tb_kb_chunk(docId);');
    await storage.db.execute(
        'create index if not exists tb_kb_vector_doc_idx on tb_kb_vector(docId);');
    await storage.db.execute(
        'create table if not exists tb_project_kb (projectId integer not null'
        ', docId integer not null, primary key(projectId, docId));');
    await storage.db.execute(
        'create index if not exists tb_project_kb_doc_idx on tb_project_kb(docId);');
    await SchemaGuard.ensureColumns(storage.db,
        table: 'tb_kb_doc',
        columns: const {
          'uid': 'text',
          'revision': 'integer not null default 1',
          'folder': "text not null default ''",
          'tags': "text not null default '[]'",
          'contentHash': "text not null default ''",
          'updatedAt': 'integer not null default 0',
          'archived': 'integer not null default 0',
          'sourceKind': "text not null default 'text'",
          'sourceAsset': "text not null default ''",
          'syncParent': "text not null default ''",
        });
    await SchemaGuard.ensureColumns(storage.db,
        table: 'tb_kb_chunk', columns: const {'pageNumber': 'integer'});
    final legacy = await storage.db
        .query('tb_kb_doc', columns: ['id'], where: "uid is null or uid = ''");
    for (final row in legacy) {
      await storage.db.update('tb_kb_doc', {'uid': generateUuidV4()},
          where: "id = ? and (uid is null or uid = '')",
          whereArgs: [row['id']]);
    }
    await storage.db.rawUpdate(
        'update tb_kb_doc set updatedAt = createdAt where updatedAt = 0');
    await storage.db.execute(
        'create table if not exists tb_kb_deleted (uid text primary key, updatedAt integer not null)');
    return KnowledgeDao._(storage);
  }

  @override
  Future<int?> addDocument(String title, String text) async {
    return addPagedDocument(title, [text], isPdf: false);
  }

  Future<int?> addPagedDocument(String title, List<String> pages,
      {bool isPdf = true,
      bool rejectDuplicates = false,
      void Function()? beforeCommit}) async {
    final chunks = <(String, int?)>[
      for (var page = 0; page < pages.length; page++)
        for (final chunk in KnowledgeChunker.split(pages[page]))
          (chunk, isPdf ? page + 1 : null),
    ];
    if (chunks.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hash =
        sha256.convert(utf8.encode(pages.join('\n\n').trim())).toString();
    final docId = await storage.db.transaction((txn) async {
      beforeCommit?.call();
      if (rejectDuplicates) {
        final same = await txn.query('tb_kb_doc',
            where: 'contentHash = ?', whereArgs: [hash], limit: 1);
        if (same.isNotEmpty) {
          throw FormatException('内容已存在于「${same.single['title']}」，未重复导入');
        }
      }
      beforeCommit?.call();
      final docId = await txn.insert('tb_kb_doc', {
        'title': title.trim().isEmpty ? '未命名文档' : title.trim(),
        'chunkCount': chunks.length,
        'createdAt': now,
        'updatedAt': now,
        'uid': generateUuidV4(),
        'contentHash': hash,
        'sourceKind': isPdf ? 'pdf' : 'text',
      });
      final batch = txn.batch();
      for (var i = 0; i < chunks.length; i++) {
        batch.insert('tb_kb_chunk', {
          'docId': docId,
          'seq': i,
          'content': chunks[i].$1,
          'pageNumber': chunks[i].$2
        });
      }
      await batch.commit(noResult: true);
      beforeCommit?.call();
      return docId;
    });
    await rebuildVectorIndex(docId: docId);
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
    final docs = await storage.db.query('tb_kb_doc',
        columns: ['uid'], where: 'id = ?', whereArgs: [docId]);
    if (docs.isNotEmpty && (docs.single['uid'] as String? ?? '').isNotEmpty) {
      await storage.db.insert(
          'tb_kb_deleted',
          {
            'uid': docs.single['uid'],
            'updatedAt': DateTime.now().millisecondsSinceEpoch
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await storage.db
        .delete('tb_kb_chunk', where: 'docId = ?', whereArgs: [docId]);
    await storage.db
        .delete('tb_kb_vector', where: 'docId = ?', whereArgs: [docId]);
    await storage.db
        .delete('tb_project_kb', where: 'docId = ?', whereArgs: [docId]);
    return storage.db.delete('tb_kb_doc', where: 'id = ?', whereArgs: [docId]);
  }

  Future<KnowledgeVectorIndexStats> vectorIndexStats({int? docId}) async {
    final chunkWhere = docId == null ? '' : 'where docId = ?';
    final args = docId == null ? const <Object?>[] : <Object?>[docId];
    final chunkRows = await storage.db.rawQuery(
      'select count(*) as count from tb_kb_chunk $chunkWhere',
      args,
    );
    final indexRows = await storage.db.rawQuery(
      'select count(*) as count from tb_kb_vector $chunkWhere',
      args,
    );
    return KnowledgeVectorIndexStats(
      chunks: ((chunkRows.first['count'] as num?) ?? 0).toInt(),
      indexed: ((indexRows.first['count'] as num?) ?? 0).toInt(),
    );
  }

  Future<KnowledgeVectorIndexStats> rebuildVectorIndex({int? docId}) async {
    final where = docId == null ? '' : 'where c.docId = ?';
    final rows = await storage.db.rawQuery(
      'select c.id as chunkId, c.docId as docId, c.content as content, '
      'd.title as title from tb_kb_chunk c '
      'left join tb_kb_doc d on d.id = c.docId '
      '$where order by c.id',
      docId == null ? const <Object?>[] : <Object?>[docId],
    );
    await storage.db.transaction((txn) async {
      if (docId == null) {
        await txn.delete('tb_kb_vector');
      } else {
        await txn
            .delete('tb_kb_vector', where: 'docId = ?', whereArgs: [docId]);
      }
      final batch = txn.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        final title = (row['title'] as String?) ?? '';
        final content = (row['content'] as String?) ?? '';
        batch.insert('tb_kb_vector', {
          'chunkId': row['chunkId'],
          'docId': row['docId'],
          'vector':
              jsonEncode(LightweightVectorRag.vectorOf('$title $content')),
          'updatedAt': now,
        });
      }
      await batch.commit(noResult: true);
    });
    return vectorIndexStats(docId: docId);
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
      'd.archived = 0',
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
    final keywordHits = [
      for (final r in rows)
        KnowledgeHit(
          docTitle: (r['title'] as String?) ?? '(未命名文档)',
          content: (r['content'] as String?) ?? '',
        ),
    ];
    if (keywordHits.isNotEmpty) return keywordHits;

    return _vectorFallback(query, limit: limit, scopedDocIds: scopedDocIds);
  }

  Future<List<KnowledgeHit>> _vectorFallback(String query,
      {required int limit, required List<int> scopedDocIds}) async {
    final useProjectScope = scopedDocIds.isNotEmpty;
    final where = useProjectScope
        ? 'where d.archived = 0 and c.docId in (${List.filled(scopedDocIds.length, '?').join(',')})'
        : 'where d.archived = 0';
    final rows = await storage.db.rawQuery(
      'select c.id as chunkId, c.docId as docId, c.content as content, '
      'd.title as title, v.vector as vector from tb_kb_chunk c '
      'left join tb_kb_doc d on d.id = c.docId '
      'left join tb_kb_vector v on v.chunkId = c.id '
      '$where order by c.id limit 200',
      useProjectScope ? scopedDocIds : const <Object?>[],
    );
    final titles = <String, String>{};
    final qv = LightweightVectorRag.vectorOf(query);
    final hits = <RagHit>[];
    for (final row in rows) {
      final id = '${row['docId']}:${row['chunkId']}';
      final title = (row['title'] as String?) ?? '(未命名文档)';
      final content = (row['content'] as String?) ?? '';
      titles[id] = title;
      final vector = _decodeVector(row['vector']) ??
          LightweightVectorRag.vectorOf('$title $content');
      final score = LightweightVectorRag.cosine(qv, vector);
      if (score <= 0) continue;
      final doc = RagDocument(
        id: id,
        title: title,
        content: content,
      );
      hits.add(RagHit(
        document: doc,
        score: score,
        snippet:
            content.length <= 120 ? content : '${content.substring(0, 120)}...',
      ));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return [
      for (final hit in hits.take(limit))
        KnowledgeHit(
          docTitle: titles[hit.document.id] ?? hit.document.title,
          content: hit.snippet,
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

  static Map<String, double>? _decodeVector(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is num)
            entry.key as String: (entry.value as num).toDouble(),
      };
    } catch (_) {
      return null;
    }
  }
}
