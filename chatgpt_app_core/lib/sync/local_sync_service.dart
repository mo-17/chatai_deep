import 'dart:convert';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';

/// 本地同步服务：把 SQLite 里的核心业务表转换成可上传的增量变更，
/// 并把服务端下发的变更按 Last-Write-Wins 应用回本机。
///
/// 网络层由 [CloudSyncClient] 负责；这里保持纯 SQLite 合并逻辑，便于离线测试。
class LocalSyncService {
  static const _specs = [
    _SyncEntitySpec(
      entity: 'project',
      table: 'tb_project',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'conversation',
      table: 'tb_conversation_list',
      idColumns: ['cid'],
      timestampColumn: 'updateAt',
    ),
    _SyncEntitySpec(
      entity: 'message',
      table: 'tb_messages',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'assistant',
      table: 'tb_assistant',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'favorite',
      table: 'tb_favorite',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'knowledge_doc',
      table: 'tb_kb_doc',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'knowledge_chunk',
      table: 'tb_kb_chunk',
      idColumns: ['id'],
    ),
    _SyncEntitySpec(
      entity: 'project_knowledge',
      table: 'tb_project_kb',
      idColumns: ['projectId', 'docId'],
    ),
    _SyncEntitySpec(
      entity: 'story_room',
      table: 'tb_story_room',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'story_participant',
      table: 'tb_story_participant',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'story_message',
      table: 'tb_story_message',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
  ];

  final HiDBManager storage;

  const LocalSyncService(this.storage);

  Future<List<SyncChange>> exportChanges({int updatedAfter = 0}) async {
    await _ensureTables();
    final changes = <SyncChange>[];
    for (final spec in _specs) {
      final rows = await storage.db.query(
        spec.table,
        where: spec.timestampColumn == null || updatedAfter <= 0
            ? null
            : '${spec.timestampColumn} > ?',
        whereArgs: spec.timestampColumn == null || updatedAfter <= 0
            ? null
            : [updatedAfter],
        orderBy: spec.timestampColumn,
      );
      for (final row in rows) {
        changes.add(spec.changeFromRow(row));
      }
    }
    final tombstones = await storage.db.query(
      SyncTombstoneStore.tableName,
      where: updatedAfter <= 0 ? null : 'updatedAt > ?',
      whereArgs: updatedAfter <= 0 ? null : [updatedAfter],
      orderBy: 'updatedAt asc',
    );
    for (final row in tombstones) {
      changes.add(SyncChange(
        entity: row['entity'] as String,
        id: '${row['entityId']}',
        op: SyncOp.delete,
        updatedAt: row['updatedAt'] as int,
        payload: const {},
      ));
    }
    changes.sort((a, b) {
      final byTime = a.updatedAt.compareTo(b.updatedAt);
      return byTime == 0 ? a.key.compareTo(b.key) : byTime;
    });
    return changes;
  }

  Future<SyncMergeResult> applyRemoteChanges(
      Iterable<SyncChange> remoteChanges) async {
    await _ensureTables();
    final accepted = <SyncChange>[];
    final rejectedStale = <SyncChange>[];
    final conflicts = <String>[];

    await storage.db.transaction((txn) async {
      for (final remote in remoteChanges) {
        final spec = _specFor(remote.entity);
        if (spec == null) {
          rejectedStale.add(remote);
          continue;
        }
        final currentRows = await txn.query(
          spec.table,
          where: spec.whereClause,
          whereArgs: spec.whereArgs(remote.id),
          limit: 1,
        );
        final current = currentRows.isEmpty ? null : currentRows.first;
        final currentUpdatedAt =
            current == null ? -1 : spec.updatedAtOf(current);
        if (currentUpdatedAt > remote.updatedAt) {
          rejectedStale.add(remote);
          continue;
        }
        if (currentUpdatedAt == remote.updatedAt &&
            current != null &&
            !_samePayload(current, remote.payload, spec.idColumns)) {
          conflicts.add(remote.key);
          continue;
        }
        if (remote.op == SyncOp.delete) {
          await txn.delete(
            spec.table,
            where: spec.whereClause,
            whereArgs: spec.whereArgs(remote.id),
          );
        } else if (current == null) {
          await txn.insert(spec.table, remote.payload);
        } else {
          await txn.update(
            spec.table,
            remote.payload,
            where: spec.whereClause,
            whereArgs: spec.whereArgs(remote.id),
          );
        }
        await SyncTombstoneStore.remove(
          txn,
          entity: remote.entity,
          id: remote.id,
        );
        accepted.add(remote);
      }
    });

    return SyncMergeResult(
      accepted: accepted,
      rejectedStale: rejectedStale,
      conflicts: conflicts.toSet().toList()..sort(),
    );
  }

  static _SyncEntitySpec? _specFor(String entity) {
    for (final spec in _specs) {
      if (spec.entity == entity) return spec;
    }
    return null;
  }

  Future<void> _ensureTables() async {
    await DbMigration.run(storage.db);
    await StoryRoomDao.create(storage);
    await SyncTombstoneStore.ensure(storage.db);
  }

  static bool _samePayload(
    Map<String, Object?> current,
    Map<String, dynamic> incoming,
    List<String> idColumns,
  ) {
    final normalizedCurrent = Map<String, Object?>.from(current);
    for (final key in idColumns) {
      normalizedCurrent[key] = incoming[key] ?? normalizedCurrent[key];
    }
    return jsonEncode(_sorted(normalizedCurrent)) ==
        jsonEncode(_sorted(incoming));
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((e) => e.toString()).toList()..sort();
      return {
        for (final key in keys) key: _sorted(value[key]),
      };
    }
    if (value is Iterable) return value.map(_sorted).toList();
    return value;
  }
}

class _SyncEntitySpec {
  final String entity;
  final String table;
  final List<String> idColumns;
  final String? timestampColumn;

  const _SyncEntitySpec({
    required this.entity,
    required this.table,
    required this.idColumns,
    this.timestampColumn,
  });

  String get whereClause => idColumns.map((c) => '$c = ?').join(' and ');

  List<Object?> whereArgs(String id) {
    final parts = id.split(':');
    return [
      for (var i = 0; i < idColumns.length; i++)
        int.tryParse(i < parts.length ? parts[i] : '') ??
            (i < parts.length ? parts[i] : ''),
    ];
  }

  SyncChange changeFromRow(Map<String, Object?> row) {
    return SyncChange(
      entity: entity,
      id: idOf(row),
      op: SyncOp.upsert,
      updatedAt: updatedAtOf(row),
      payload: Map<String, dynamic>.from(row),
    );
  }

  String idOf(Map<String, Object?> row) =>
      idColumns.map((c) => '${row[c]}').join(':');

  int updatedAtOf(Map<String, Object?> row) {
    if (timestampColumn == null) return 0;
    final raw = row[timestampColumn];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }
}
