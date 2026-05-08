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

  ///初始化数据库
  Future<HiDBManager> _init() async {
    if (Platform.isWindows) {
      sqfliteFfiInit();
      _db = await databaseFactoryFfi.openDatabase(_dbName);
    } else {
      _db = await openDatabase(_dbName);
    }
    debugPrint('db ver:${await _db.getVersion()}');
    return this;
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
