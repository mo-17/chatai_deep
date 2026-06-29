import 'dart:io';

import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:flutter/cupertino.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

///用于管理数据库的创建和销毁
class HiDBManager {
  ///多实例
  static final Map<String, HiDBManager> _storageMap = {};

  ///数据库名称
  final String _dbName;

  ///数据库实例
  late Database _db;

  ///获取HiStorage实例
  static Future<HiDBManager> instance({required String dbName}) async {
    if (!dbName.endsWith(".db")) {
      dbName = '$dbName.db';
    }
    var storage = _storageMap[dbName];
    storage ??= await HiDBManager._(dbName: dbName)._init();
    return storage;
  }

  Database get db {
    return _db;
  }

  ///多实例模式，一个数据库一个实例
  HiDBManager._({required String dbName}) : _dbName = dbName {
    _storageMap[_dbName] = this;
  }

  ///仅供测试：用现成的 [Database]（如 sqflite_common_ffi 内存库）构造，
  ///不注册多实例缓存、不走平台初始化，便于各 Dao 走真实代码路径做单测。
  @visibleForTesting
  HiDBManager.test(Database db, {String dbName = ':memory:'})
      : _dbName = dbName {
    _db = db;
  }

  /// 当前数据库 schema 版本
  static const int _kSchemaVersion = 2;

  ///初始化数据库
  Future<HiDBManager> _init() async {
    if (Platform.isWindows) {
      sqfliteFfiInit();
      _db = await databaseFactoryFfi.openDatabase(_dbName,
          options: OpenDatabaseOptions(
              version: _kSchemaVersion,
              onUpgrade: _onUpgrade,
              onCreate: (db, version) async {
                // 新安装：创建统一消息表
                await db.execute(
                    'create table if not exists tb_messages (id integer primary key autoincrement'
                    ', cid integer not null, content text, createdAt integer'
                    ', ownerName text, ownerType text, avatar text)');
                await db.execute(
                    'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
              }));
    } else {
      _db = await openDatabase(_dbName,
          version: _kSchemaVersion,
          onUpgrade: _onUpgrade, onCreate: (db, version) async {
        await db.execute(
            'create table if not exists tb_messages (id integer primary key autoincrement'
            ', cid integer not null, content text, createdAt integer'
            ', ownerName text, ownerType text, avatar text)');
        await db.execute(
            'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
      });
    }
    await DbMigration.run(_db);
    return this;
  }

  /// 迁移：将旧的 tb_<cid> 表合并到 tb_messages
  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await DbMigration.migrateLegacyMessageTables(db);
    }
    await DbMigration.run(db);
  }

  ///销毁数据库
  void destroy() {
    _db.close();
    _storageMap.remove(_dbName);
  }

  ///关闭所有数据库连接（登出时调用）
  static Future<void> closeAll() async {
    for (final mgr in _storageMap.values.toList()) {
      try {
        await mgr._db.close();
      } catch (_) {}
    }
    _storageMap.clear();
    debugPrint('HiDBManager: all dbs closed');
  }

  ///账号唯一标识
  static String getAccountHash() {
    return LoginDao.getAccountHash() ?? "test";
  }
}
