import 'package:sqflite/sqflite.dart';

/// SQLite 表结构的增量自愈工具。
///
/// 新库的 `CREATE TABLE` 通常已经包含最新列。先读取真实 schema，能避免把
/// “列已存在”当作异常反复触发原生日志，同时仍为旧库补齐缺失列。
class SchemaGuard {
  static final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  static Future<void> ensureColumns(
    DatabaseExecutor db, {
    required String table,
    required Map<String, String> columns,
  }) async {
    _validateIdentifier(table, label: 'table');
    for (final column in columns.keys) {
      _validateIdentifier(column, label: 'column');
    }

    var existing = await _columnNames(db, table);
    if (existing.isEmpty) {
      throw StateError('Table "$table" does not exist');
    }

    for (final entry in columns.entries) {
      final column = entry.key;
      final normalized = column.toLowerCase();
      if (existing.contains(normalized)) continue;

      final definition = entry.value.trim();
      if (definition.isEmpty || definition.contains(';')) {
        throw ArgumentError.value(
          entry.value,
          'columns[$column]',
          'Column definition must be non-empty and contain no semicolon',
        );
      }

      try {
        await db.execute(
          'alter table "$table" add column "$column" $definition',
        );
        existing.add(normalized);
      } on DatabaseException {
        // 极小概率下另一个初始化任务可能先一步补列；仅此情形可安全忽略。
        existing = await _columnNames(db, table);
        if (!existing.contains(normalized)) rethrow;
      }
    }
  }

  static Future<Set<String>> _columnNames(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery('pragma table_info("$table")');
    return rows.map((row) => (row['name']! as String).toLowerCase()).toSet();
  }

  static void _validateIdentifier(String value, {required String label}) {
    if (!_identifierPattern.hasMatch(value)) {
      throw ArgumentError.value(value, label, 'Invalid SQLite identifier');
    }
  }
}
