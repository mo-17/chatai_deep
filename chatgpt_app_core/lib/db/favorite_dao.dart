import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:sqflite/sqflite.dart';

///收藏功能数据操作接口
abstract class IFavorite {
  Future<int?> addFavorite(FavoriteModel model);

  Future<int?> removeFavorite(FavoriteModel model);

  Future<List<FavoriteModel>> getFavoriteList();
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
    var results =
        await storage.db.query(tableName, orderBy: 'id desc');
    var list = results.map((item) => FavoriteModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<int?> removeFavorite(FavoriteModel model) async {
    var result = await storage.db.delete(tableName, where: 'id = ?', whereArgs: [model.id]);
    return result;
  }
}
