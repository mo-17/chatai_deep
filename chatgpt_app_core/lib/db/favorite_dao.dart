import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:sqflite/sqflite.dart';

///收藏功能数据操作接口
abstract class IFavorite {
  Future<int?> addFavorite(FavoriteModel model);

  Future<int?> removeFavorite(FavoriteModel model);

  Future<List<FavoriteModel>> getFavoriteList();

  Future<List<FavoriteModel>> searchFavorites(String query, {int limit = 50});

  Future<List<FavoriteSearchResult>> searchFavoriteResults(String query,
      {int limit = 50});
}

class FavoriteSearchResult {
  final FavoriteModel favorite;
  final int? cid;
  final String? conversationTitle;

  const FavoriteSearchResult({
    required this.favorite,
    this.cid,
    this.conversationTitle,
  });
}

class FavoriteDao implements IFavorite, ITable {
  final HiDBManager storage;
  @override
  String tableName = 'tb_favorite';

  FavoriteDao._(this.storage);

  /// 静态工厂，确保表创建完成后再返回实例
  static Future<FavoriteDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_favorite (id integer primary key autoincrement'
        ', ownerName text, content text, createdAt integer);');
    return FavoriteDao._(storage);
  }

  @override
  Future<int?> addFavorite(FavoriteModel model) async {
    var result = await storage.db.insert(tableName, model.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return result;
  }

  @override
  Future<List<FavoriteModel>> getFavoriteList() async {
    var results = await storage.db.query(tableName, orderBy: 'id desc');
    var list = results.map((item) => FavoriteModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<List<FavoriteModel>> searchFavorites(String query,
      {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await storage.db.query(
      tableName,
      where: 'content like ? or ownerName like ?',
      whereArgs: ['%$q%', '%$q%'],
      orderBy: 'id desc',
      limit: limit.clamp(1, 100),
    );
    return rows.map((item) => FavoriteModel.fromJson(item)).toList();
  }

  @override
  Future<List<FavoriteSearchResult>> searchFavoriteResults(String query,
      {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await storage.db.rawQuery(
      'select f.*, m.cid as cid, c.title as conversationTitle '
      'from $tableName f '
      'left join tb_messages m on m.createdAt = f.createdAt and m.content = f.content '
      'left join tb_conversation_list c on c.cid = m.cid '
      'where f.content like ? or f.ownerName like ? '
      'group by f.id '
      'order by f.id desc limit ?',
      ['%$q%', '%$q%', limit.clamp(1, 100)],
    );
    return [
      for (final row in rows)
        FavoriteSearchResult(
          favorite: FavoriteModel.fromJson(row),
          cid: row['cid'] as int?,
          conversationTitle: row['conversationTitle'] as String?,
        ),
    ];
  }

  @override
  Future<int?> removeFavorite(FavoriteModel model) async {
    var result = await storage.db
        .delete(tableName, where: 'id = ?', whereArgs: [model.id]);
    return result;
  }
}
