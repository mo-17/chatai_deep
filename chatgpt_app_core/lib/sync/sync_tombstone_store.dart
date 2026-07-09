import 'package:sqflite/sqflite.dart';

class SyncTombstoneStore {
  static const tableName = 'tb_sync_tombstone';

  const SyncTombstoneStore._();

  static Future<void> ensure(DatabaseExecutor db) async {
    await db.execute(
      'create table if not exists $tableName ('
      'entity text not null, entityId text not null, updatedAt integer not null, '
      'primary key(entity, entityId))',
    );
  }

  static Future<void> record(
    DatabaseExecutor db, {
    required String entity,
    required Object id,
    required int updatedAt,
  }) async {
    await ensure(db);
    await db.insert(
      tableName,
      {'entity': entity, 'entityId': '$id', 'updatedAt': updatedAt},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> remove(
    DatabaseExecutor db, {
    required String entity,
    required String id,
  }) async {
    await ensure(db);
    await db.delete(
      tableName,
      where: 'entity = ? and entityId = ?',
      whereArgs: [entity, id],
    );
  }
}
