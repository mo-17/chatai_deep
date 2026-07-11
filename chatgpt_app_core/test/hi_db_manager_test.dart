import 'dart:io';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('同名数据库并发初始化只返回已经可用的同一实例', () async {
    final directory = await Directory.systemTemp.createTemp('hi-db-race-');
    addTearDown(() async {
      await HiDBManager.closeAll();
      await directory.delete(recursive: true);
    });
    final dbName = '${directory.path}/account';

    final checks = List.generate(32, (_) async {
      final manager = await HiDBManager.instance(dbName: dbName);
      await manager.db.rawQuery('select 1');
      return manager;
    });
    final managers = await Future.wait(checks);

    expect(managers.toSet(), hasLength(1));
  });
}
