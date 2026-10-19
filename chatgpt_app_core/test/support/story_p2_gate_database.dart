import 'dart:async';
// 仅fixture：包装真实私有SQLite，屏障位于COMMIT后或DDL完成后，不持锁等UI。
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class StoryP2Gate {
  bool holdRefresh = false, assistantSaved = false, holdFavoriteDdl = false;
  final refreshEntered = Completer<void>(), refreshRelease = Completer<void>();
  final ddlEntered = Completer<void>(), ddlRelease = Completer<void>();
}

class StoryP2Factory implements SqfliteDatabaseFactory {
  final DatabaseFactory native;
  final StoryP2Gate gate;
  StoryP2Factory(this.native, this.gate);
  @override
  Future<Database> openDatabase(String path,
          {OpenDatabaseOptions? options}) async =>
      StoryP2Database(await native.openDatabase(path, options: options), gate);
  @override
  Future<String> getDatabasesPath() => native.getDatabasesPath();
  @override
  Future<void> setDatabasesPath(String path) => native.setDatabasesPath(path);
  @override
  Future<void> deleteDatabase(String path) => native.deleteDatabase(path);
  @override
  Future<bool> databaseExists(String path) => native.databaseExists(path);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('unused fixture factory');
}

mixin _ForwardExecutor implements DatabaseExecutor {
  DatabaseExecutor get delegate;
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      delegate.execute(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      delegate.rawQuery(sql, arguments);
  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      delegate.rawInsert(sql, arguments);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      delegate.rawUpdate(sql, arguments);
  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      delegate.rawDelete(sql, arguments);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      delegate.delete(table, where: where, whereArgs: whereArgs);
  @override
  Batch batch() => delegate.batch();
  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      delegate.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
}

class StoryP2Database with _ForwardExecutor implements Database {
  final Database native;
  final StoryP2Gate gate;
  StoryP2Database(this.native, this.gate);
  @override
  DatabaseExecutor get delegate => native;
  @override
  String get path => native.path;
  @override
  bool get isOpen => native.isOpen;
  @override
  Future<void> close() => native.close();
  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    await native.execute(sql, args);
    if (gate.holdFavoriteDdl &&
        sql.toLowerCase().contains('create table') &&
        sql.contains('tb_favorite')) {
      gate.holdFavoriteDdl = false;
      gate.ddlEntered.complete();
      await gate.ddlRelease.future;
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    var assistant = false;
    final value = await native.transaction(
        (tx) => action(_StoryP2Transaction(tx, () => assistant = true)),
        exclusive: exclusive);
    if (assistant) gate.assistantSaved = true;
    return value;
  }

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    if (gate.holdRefresh && gate.assistantSaved && table == 'tb_story_room') {
      gate.holdRefresh = false;
      gate.refreshEntered.complete();
      await gate.refreshRelease.future;
    }
    return native.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('unused fixture database');
}

class _StoryP2Transaction with _ForwardExecutor implements Transaction {
  final Transaction native;
  final void Function() assistantSaved;
  _StoryP2Transaction(this.native, this.assistantSaved);
  @override
  DatabaseExecutor get delegate => native;
  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    final id = await native.insert(table, values,
        nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
    if (table == 'tb_story_message' && values['speakerRole'] != 'user') {
      assistantSaved();
    }
    return id;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('unused fixture transaction');
}
