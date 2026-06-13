import 'dart:io';

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
          onUpgrade: _onUpgrade,
          onCreate: (db, version) async {
            await db.execute(
                'create table if not exists tb_messages (id integer primary key autoincrement'
                ', cid integer not null, content text, createdAt integer'
                ', ownerName text, ownerType text, avatar text)');
            await db.execute(
                'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
          });
    }
    return this;
  }

  /// 迁移：将旧的 tb_<cid> 表合并到 tb_messages
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // 检测并迁移旧的 per-cid 消息表
      final tables = await db.rawQuery(
          "select name from sqlite_master where type='table' and name like 'tb\\_%' escape '\\'");
      final knownTables = {'tb_conversation_list', 'tb_favorite', 'tb_messages'};
      // 确保 tb_messages 存在
      await db.execute(
          'create table if not exists tb_messages (id integer primary key autoincrement'
          ', cid integer not null, content text, createdAt integer'
          ', ownerName text, ownerType text, avatar text)');
      await db.execute(
          'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
      for (final row in tables) {
        final name = row['name'] as String;
        if (knownTables.contains(name)) continue;
        // tb_<cid> 格式
        final cidStr = name.substring(3); // 去掉 'tb_' 前缀
        final cid = int.tryParse(cidStr);
        if (cid == null) continue;
        try {
          await db.rawInsert(
              'insert into tb_messages (cid, content, createdAt, ownerName, ownerType, avatar) '
              'select $cid, content, createdAt, ownerName, ownerType, avatar from "$name"');
          await db.execute('drop table if exists "$name"');
          debugPrint('migrated table $name -> tb_messages');
        } catch (e) {
          debugPrint('migrate $name failed: $e');
        }
      }
    }
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
