import 'dart:convert';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:sqflite/sqflite.dart';
import 'knowledge_evidence.dart';
import 'knowledge_hybrid_search.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';

class KnowledgeScopeException implements Exception {
  final String message;
  const KnowledgeScopeException(this.message);
  @override
  String toString() => message;
}

/// 沿用账号的知识表；可信问答历史单独存储，不写进普通聊天上下文。
abstract class IKnowledgeRepository {
  Future<List<KnowledgeDoc>> documents();
  Future<List<KnowledgeEvidence>> retrieve(String question, Set<int> ids);
  Future<void> verifySources(Set<int> ids, List<KnowledgeEvidence> sources);
  Future<KnowledgeAnswer> save(
      KnowledgeAnswer answer, Set<int> ids, bool Function() isCurrent);
  Future<List<KnowledgeAnswer>> history({int? beforeId});
  Future<bool> sourceUnchanged(KnowledgeEvidence source);
  Future<void> clearHistory();
}

class KnowledgeRepository implements IKnowledgeRepository, ITable {
  final HiDBManager storage;
  final KnowledgeDao knowledge;
  @override
  String tableName = 'tb_knowledge_answer';
  KnowledgeRepository._(this.storage, this.knowledge);
  static Future<KnowledgeRepository> create(HiDBManager storage) async {
    final knowledge = await KnowledgeDao.create(storage);
    await storage.db.execute('create table if not exists tb_knowledge_answer '
        '(id integer primary key autoincrement, createdAt integer not null, '
        'payload text not null)');
    await SchemaGuard.ensureColumns(storage.db,
        table: 'tb_knowledge_answer',
        columns: {'uid': 'text', 'deletedAt': 'integer not null default 0'});
    for (final row in await storage.db.query('tb_knowledge_answer',
        columns: ['id'], where: "uid is null or uid = ''")) {
      await storage.db.update('tb_knowledge_answer', {'uid': generateUuidV4()},
          where: "id = ? and (uid is null or uid = '')",
          whereArgs: [row['id']]);
    }
    return KnowledgeRepository._(storage, knowledge);
  }

  @override
  Future<List<KnowledgeDoc>> documents() async =>
      (await knowledge.getDocuments()).where((d) => !d.archived).toList();

  static void _validateIds(Set<int> ids) {
    if (ids.isEmpty || ids.length > 100 || ids.any((id) => id <= 0)) {
      throw const KnowledgeScopeException('请选择 1～100 篇文档作为本次问答范围');
    }
  }

  @override
  Future<List<KnowledgeEvidence>> retrieve(
      String question, Set<int> ids) async {
    _validateIds(ids);
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await storage.db.rawQuery(
        'select c.id as chunkId, c.docId, c.seq, c.content, c.pageNumber, d.uid, '
        'd.revision, d.sourceAsset, d.title, '
        'd.createdAt as importedAt from tb_kb_chunk c '
        'inner join tb_kb_doc d on d.id = c.docId '
        'where d.archived = 0 and c.docId in ($marks) order by c.id limit 5001',
        ids.toList());
    if (rows.length > 5000) {
      throw const KnowledgeScopeException('所选资料超过 5000 个片段，请缩小文档范围');
    }
    await _verifySources(storage.db, ids, const []);
    return KnowledgeHybridSearch.search(question, rows.map(_source).toList())
        .map((hit) => hit.source)
        .toList();
  }

  static KnowledgeEvidence _source(Map<String, Object?> r) => KnowledgeEvidence(
      docId: r['docId'] as int,
      chunkId: r['chunkId'] as int,
      seq: r['seq'] as int,
      importedAt: r['importedAt'] as int,
      title: r['title'] as String? ?? '未命名文档',
      content: r['content'] as String,
      uid: r['uid'] as String? ?? '',
      revision: r['revision'] as int? ?? 0,
      pageNumber: r['pageNumber'] as int?,
      sourceAsset: r['sourceAsset'] as String? ?? '');

  static Future<void> _verifySources(DatabaseExecutor db, Set<int> ids,
      List<KnowledgeEvidence> sources) async {
    _validateIds(ids);
    final rows = await db.rawQuery(
        'select id from tb_kb_doc where archived = 0 and id in '
        '(${List.filled(ids.length, '?').join(',')})',
        ids.toList());
    if (rows.length != ids.length) {
      throw const KnowledgeScopeException('所选文档已删除或变化，请刷新后重新提问');
    }
    for (final source in sources) {
      final rows = await db.rawQuery(
          'select c.id as chunkId, c.docId, c.seq, c.content, c.pageNumber, d.uid, '
          'd.revision, d.sourceAsset, d.title, '
          'd.createdAt as importedAt from tb_kb_chunk c '
          'inner join tb_kb_doc d on d.id = c.docId '
          'where d.archived = 0 and ${source.uid.isEmpty ? "c.id = ? and c.docId = ?" : "d.uid = ? and c.seq = ?"}',
          source.uid.isEmpty
              ? [source.chunkId, source.docId]
              : [source.uid, source.seq]);
      if (rows.length != 1 ||
          !ids.contains(rows.single['docId']) ||
          !_matches(_source(rows.single), source)) {
        throw const KnowledgeScopeException('引用原文已变化，请重新检索后提问');
      }
    }
  }

  static bool _matches(KnowledgeEvidence current, KnowledgeEvidence saved) =>
      saved.uid.isNotEmpty
          ? current.digest == saved.digest
          : KnowledgeEvidence(
                      docId: current.docId,
                      chunkId: current.chunkId,
                      seq: current.seq,
                      importedAt: current.importedAt,
                      title: current.title,
                      content: current.content)
                  .digest ==
              saved.digest;

  @override
  Future<void> verifySources(Set<int> ids, List<KnowledgeEvidence> sources) =>
      _verifySources(storage.db, ids, sources);

  @override
  Future<KnowledgeAnswer> save(
      KnowledgeAnswer answer, Set<int> ids, bool Function() isCurrent) async {
    final id = await storage.db.transaction((tx) async {
      void guard() {
        if (!isCurrent()) {
          throw const KnowledgeScopeException('会话环境已变化，本次结果未保存');
        }
      }

      guard();
      await _verifySources(tx, ids, answer.sources);
      guard();
      final id = await tx.insert(tableName, {
        'uid': generateUuidV4(),
        'createdAt': answer.createdAt,
        'payload': jsonEncode(answer.toJson())
      });
      guard();
      return id;
    });
    return KnowledgeAnswer.fromJson(answer.toJson(), id: id);
  }

  @override
  Future<List<KnowledgeAnswer>> history({int? beforeId}) async {
    final rows = await storage.db.query(tableName,
        where: beforeId == null ? 'deletedAt = 0' : 'deletedAt = 0 and id < ?',
        whereArgs: beforeId == null ? null : [beforeId],
        orderBy: 'id desc',
        limit: 20);
    return rows
        .map((r) => KnowledgeAnswer.fromJson(
            (jsonDecode(r['payload'] as String) as Map).cast<String, dynamic>(),
            id: r['id'] as int))
        .toList();
  }

  @override
  Future<bool> sourceUnchanged(KnowledgeEvidence source) async {
    try {
      final docs = source.uid.isEmpty
          ? const <Map<String, Object?>>[]
          : await storage.db.query('tb_kb_doc',
              columns: ['id'], where: 'uid = ?', whereArgs: [source.uid]);
      await verifySources(
          {docs.isEmpty ? source.docId : docs.single['id'] as int}, [source]);
      return true;
    } on KnowledgeScopeException {
      return false;
    }
  }

  @override
  Future<void> clearHistory() async => storage.db.transaction((tx) async {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final row in await tx.query(tableName,
            columns: ['id', 'createdAt'], where: 'deletedAt = 0')) {
          await tx.update(
              tableName,
              {
                'deletedAt': now > (row['createdAt'] as int)
                    ? now
                    : (row['createdAt'] as int) + 1,
                'payload': emptyHistoryPayload(row['createdAt'] as int)
              },
              where: 'id = ?',
              whereArgs: [row['id']]);
        }
      });
  static String emptyHistoryPayload(int createdAt) =>
      jsonEncode(KnowledgeAnswer(
              question: '',
              model: '',
              createdAt: createdAt,
              status: KnowledgeAnswerStatus.insufficient)
          .toJson());
}
