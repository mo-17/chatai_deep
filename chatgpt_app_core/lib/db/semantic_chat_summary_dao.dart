import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/semantic_chat_summary.dart';
import 'package:chatgpt_app_core/db/database_platform.dart';

abstract class SemanticChatSummaryStore {
  Future<SemanticChatSummary?> get(int cid, String sourceFingerprint);
  Future<void> save(SemanticChatSummary summary);
  Future<void> deleteForConversation(int cid);
}

/// 每个账号自己的 SQLite 中保存摘要，每个会话只缓存最近一个源区间。
/// 按需建表，老会话无行就是无缓存，不要求升级或修改消息表。
class SemanticChatSummaryDao implements SemanticChatSummaryStore, ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_chat_semantic_summary';

  SemanticChatSummaryDao._(this.storage);

  static Future<SemanticChatSummaryDao> create(HiDBManager storage) async {
    await storage.db.execute(
      'create table if not exists tb_chat_semantic_summary '
      '(cid integer primary key, sourceFingerprint text not null, '
      'sourceMessageCount integer not null, content text not null, '
      'createdAt integer not null)',
    );
    return SemanticChatSummaryDao._(storage);
  }

  @override
  Future<SemanticChatSummary?> get(int cid, String sourceFingerprint) async {
    final rows = await storage.db.query(
      tableName,
      where: 'cid = ? and sourceFingerprint = ?',
      whereArgs: [cid, sourceFingerprint],
      limit: 1,
    );
    return rows.isEmpty ? null : SemanticChatSummary.fromRow(rows.single);
  }

  @override
  Future<void> save(SemanticChatSummary summary) async {
    await storage.db.insert(tableName, summary.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteForConversation(int cid) async {
    await storage.db.delete(tableName, where: 'cid = ?', whereArgs: [cid]);
  }
}
