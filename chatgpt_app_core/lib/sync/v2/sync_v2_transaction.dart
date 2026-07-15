import 'package:sqflite/sqflite.dart';

/// Sync v2 sidecar 多步写入的统一事务边界。
class SyncV2Transaction {
  const SyncV2Transaction._();

  /// 业务 DAO 已传入 [Transaction] 时复用外层事务；直接传
  /// [Database] 或其他 executor 时，在底层 database 上创建事务。
  static Future<T> run<T>(
    DatabaseExecutor executor,
    Future<T> Function(Transaction txn) action,
  ) {
    if (executor is Transaction) return action(executor);
    return executor.database.transaction(action);
  }
}
