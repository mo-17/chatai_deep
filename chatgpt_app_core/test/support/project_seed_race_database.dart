import 'dart:async';
// 仅fixture：sqflite全局setter要求内部factory标记；所有操作仍委托实际FFI。
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 所有SQL委托真实私有SQLite；仅在事务已释放与首次seed SELECT前加屏障。
class ProjectSeedRaceGate {
  bool holdSave = false, holdSnapshot = false;
  final saveCommitted = Completer<void>();
  final releaseSave = Completer<void>();
  final snapshotEntered = Completer<void>();
  final releaseSnapshot = Completer<void>();
  bool saveReleased = false;
}

class ProjectSeedRaceFactory implements SqfliteDatabaseFactory {
  final DatabaseFactory native;
  final ProjectSeedRaceGate gate;
  ProjectSeedRaceFactory(this.native, this.gate);
  @override
  Future<Database> openDatabase(String path,
          {OpenDatabaseOptions? options}) async =>
      _RaceDatabase(await native.openDatabase(path, options: options), gate);
  @override
  Future<String> getDatabasesPath() => native.getDatabasesPath();
  @override
  Future<void> setDatabasesPath(String path) => native.setDatabasesPath(path);
  @override
  Future<void> deleteDatabase(String path) => native.deleteDatabase(path);
  @override
  Future<bool> databaseExists(String path) => native.databaseExists(path);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused factory operation');
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

class _RaceDatabase with _ForwardExecutor implements Database {
  final Database native;
  final ProjectSeedRaceGate gate;
  _RaceDatabase(this.native, this.gate);
  @override
  DatabaseExecutor get delegate => native;
  @override
  String get path => native.path;
  @override
  bool get isOpen => native.isOpen;
  @override
  Future<void> close() => native.close();
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    var changed = false;
    final result = await native.transaction(
        (tx) => action(_RaceTransaction(tx, () => changed = true)),
        exclusive: exclusive);
    if (changed && gate.holdSave) {
      gate.holdSave = false;
      gate.saveCommitted.complete();
      await gate.releaseSave.future;
      gate.saveReleased = true;
    }
    return result;
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
    if (table == 'tb_project' && where == 'id=?' && gate.holdSnapshot) {
      gate.holdSnapshot = false;
      gate.snapshotEntered.complete();
      await gate.releaseSnapshot.future;
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused database operation');
}

class _RaceTransaction with _ForwardExecutor implements Transaction {
  final Transaction native;
  final void Function() changed;
  _RaceTransaction(this.native, this.changed);
  @override
  DatabaseExecutor get delegate => native;
  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    final n = await native.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
    if (n > 0 &&
        table == 'tb_project' &&
        values.containsKey('backendSelection')) {
      changed();
    }
    return n;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused transaction operation');
}
