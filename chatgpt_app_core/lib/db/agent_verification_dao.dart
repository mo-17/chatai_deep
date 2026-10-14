import 'dart:convert';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:sqflite/sqflite.dart';

class AgentReadInterval {
  final int startOffset;
  final int endOffset;
  final int totalChars;
  const AgentReadInterval(this.startOffset, this.endOffset, this.totalChars);
}

/// 阅读证据和验收报告是任务派生数据；不改写原消息或工作区文件。
class AgentVerificationDao implements ITable {
  final HiDBManager storage;
  AgentVerificationDao._(this.storage);
  @override
  String tableName = 'tb_agent_verification_report';

  static Future<AgentVerificationDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_agent_task_criteria '
        '(cid integer primary key, criteria text not null, armed integer not null)');
    await storage.db.execute(
        'create table if not exists tb_agent_verification_turn '
        '(cid integer not null, userCreatedAt integer not null, snapshot text not null, '
        'primary key (cid, userCreatedAt))');
    await storage.db.execute(
        'create table if not exists tb_agent_read_interval '
        '(id integer primary key autoincrement, cid integer not null, '
        'userCreatedAt integer not null, fileId integer not null, revision integer not null, '
        'startOffset integer not null, endOffset integer not null, totalChars integer not null)');
    await storage.db
        .execute('create index if not exists tb_agent_read_interval_lookup '
            'on tb_agent_read_interval (cid, userCreatedAt, fileId, revision)');
    await storage.db.execute(
        'create table if not exists tb_agent_verification_report '
        '(cid integer not null, userCreatedAt integer not null, report text not null, '
        'updatedAt integer not null, primary key (cid, userCreatedAt))');
    return AgentVerificationDao._(storage);
  }

  Future<Map<String, dynamic>?> loadCriteria(int cid) async {
    final rows = await storage.db.query('tb_agent_task_criteria',
        where: 'cid = ?', whereArgs: [cid], limit: 1);
    return rows.isEmpty ? null : _decode(rows.single['criteria']);
  }

  Future<bool> criteriaArmed(int cid) async {
    final rows = await storage.db.query('tb_agent_task_criteria',
        columns: ['armed'], where: 'cid = ?', whereArgs: [cid], limit: 1);
    return rows.isNotEmpty && rows.single['armed'] == 1;
  }

  Future<void> saveCriteria(int cid, Map<String, dynamic> criteria) async {
    await storage.db.insert('tb_agent_task_criteria',
        {'cid': cid, 'criteria': jsonEncode(criteria), 'armed': 1},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> beginTurn(
      int cid, int userCreatedAt, Map<String, dynamic> snapshot,
      {bool Function()? canCommit,
      Future<void> Function(Transaction)? transactionGuard,
      Future<void> Function(Future<void> Function())? stableOperation}) async {
    await _guardedWrite(stableOperation, (txn) async {
      await _checkParent(txn, cid, canCommit);
      await transactionGuard?.call(txn);
      await txn.delete('tb_agent_read_interval',
          where: 'cid = ? and userCreatedAt = ?',
          whereArgs: [cid, userCreatedAt]);
      await txn.delete(tableName,
          where: 'cid = ? and userCreatedAt = ?',
          whereArgs: [cid, userCreatedAt]);
      await txn.insert(
          'tb_agent_verification_turn',
          {
            'cid': cid,
            'userCreatedAt': userCreatedAt,
            'snapshot': jsonEncode(snapshot),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update('tb_agent_task_criteria', {'armed': 0},
          where: 'cid = ?', whereArgs: [cid]);
      _checkExecution(canCommit);
      await transactionGuard?.call(txn);
    });
  }

  Future<Map<String, dynamic>?> loadTurn(int cid, int userCreatedAt) async {
    final rows = await storage.db.query('tb_agent_verification_turn',
        where: 'cid = ? and userCreatedAt = ?',
        whereArgs: [cid, userCreatedAt],
        limit: 1);
    return rows.isEmpty ? null : _decode(rows.single['snapshot']);
  }

  Future<Map<String, dynamic>?> loadLatestTurn(int cid) async {
    final rows = await storage.db.query('tb_agent_verification_turn',
        where: 'cid = ?',
        whereArgs: [cid],
        orderBy: 'userCreatedAt desc',
        limit: 1);
    return rows.isEmpty ? null : _decode(rows.single['snapshot']);
  }

  Future<void> saveOutput(int cid, int userCreatedAt, int fileId, int revision,
      {bool Function()? canCommit}) async {
    await storage.db.transaction((txn) async {
      await _checkParent(txn, cid, canCommit);
      final rows = await txn.query('tb_agent_verification_turn',
          where: 'cid = ? and userCreatedAt = ?',
          whereArgs: [cid, userCreatedAt],
          limit: 1);
      if (rows.isEmpty) throw StateError('本轮任务尚未开始');
      final snapshot = _decode(rows.single['snapshot'])!;
      final outputs =
          Map<String, dynamic>.from(snapshot['outputs'] as Map? ?? const {});
      outputs['$fileId'] = revision;
      snapshot['outputs'] = outputs;
      _checkExecution(canCommit);
      await txn.update(
          'tb_agent_verification_turn', {'snapshot': jsonEncode(snapshot)},
          where: 'cid = ? and userCreatedAt = ?',
          whereArgs: [cid, userCreatedAt]);
      _checkExecution(canCommit);
    });
  }

  Future<void> recordRead(int cid, int userCreatedAt, int fileId, int revision,
      int startOffset, int endOffset, int totalChars,
      {bool includeInput = false,
      bool Function()? canCommit,
      Future<void> Function(Transaction)? transactionGuard}) async {
    if (startOffset < 0 || endOffset < startOffset || endOffset > totalChars) {
      throw const FormatException('无效的阅读区间');
    }
    await storage.db.transaction((txn) async {
      await _checkParent(txn, cid, canCommit);
      if (includeInput) {
        await transactionGuard?.call(txn);
        final rows = await txn.query('tb_agent_verification_turn',
            where: 'cid = ? and userCreatedAt = ?',
            whereArgs: [cid, userCreatedAt],
            limit: 1);
        if (rows.isEmpty) throw StateError('本轮任务尚未开始');
        final snapshot = _decode(rows.single['snapshot'])!;
        // 手动导入或旧输入一旦实际阅读，也成为本轮验收范围；只增不减。
        final inputs = (snapshot['inputIds'] as List).cast<int>().toSet()
          ..add(fileId);
        snapshot['inputIds'] = inputs.toList();
        _checkExecution(canCommit);
        await txn.update(
            'tb_agent_verification_turn', {'snapshot': jsonEncode(snapshot)},
            where: 'cid = ? and userCreatedAt = ?',
            whereArgs: [cid, userCreatedAt]);
      }
      _checkExecution(canCommit);
      await txn.insert('tb_agent_read_interval', {
        'cid': cid,
        'userCreatedAt': userCreatedAt,
        'fileId': fileId,
        'revision': revision,
        'startOffset': startOffset,
        'endOffset': endOffset,
        'totalChars': totalChars,
      });
      _checkExecution(canCommit);
      await transactionGuard?.call(txn);
    });
  }

  Future<List<AgentReadInterval>> readIntervals(
      int cid, int userCreatedAt, int fileId, int revision) async {
    final rows = await storage.db.query('tb_agent_read_interval',
        where: 'cid = ? and userCreatedAt = ? and fileId = ? and revision = ?',
        whereArgs: [cid, userCreatedAt, fileId, revision],
        orderBy: 'startOffset, endOffset');
    return rows
        .map((row) => AgentReadInterval(row['startOffset'] as int,
            row['endOffset'] as int, row['totalChars'] as int))
        .toList();
  }

  Future<void> saveReport(
      int cid, int userCreatedAt, Map<String, dynamic> report,
      {bool Function()? canCommit,
      Future<void> Function(Transaction)? transactionGuard,
      Future<void> Function(Future<void> Function())? stableOperation}) async {
    await _guardedWrite(stableOperation, (txn) async {
      await _checkParent(txn, cid, canCommit);
      await transactionGuard?.call(txn);
      await txn.insert(
          tableName,
          {
            'cid': cid,
            'userCreatedAt': userCreatedAt,
            'report': jsonEncode(report),
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      _checkExecution(canCommit);
      await transactionGuard?.call(txn);
    });
  }

  Future<void> _guardedWrite(
      Future<void> Function(Future<void> Function())? stable,
      Future<void> Function(Transaction) action) async {
    Future<void> write() => storage.db.transaction(action);
    if (stable == null) {
      await write();
    } else {
      await stable(write);
    }
  }

  static void _checkExecution(bool Function()? canCommit) {
    if (canCommit != null && !canCommit()) {
      throw StateError('任务已停止，验收记录未修改');
    }
  }

  static Future<void> _checkParent(
      Transaction txn, int cid, bool Function()? canCommit) async {
    _checkExecution(canCommit);
    if (canCommit == null) return;
    final parent = await txn.query('tb_conversation_list',
        columns: ['cid'], where: 'cid=?', whereArgs: [cid], limit: 1);
    _checkExecution(canCommit);
    if (parent.isEmpty) throw StateError('原对话已删除，验收记录未修改');
  }

  Future<Map<String, dynamic>?> loadLatestReport(int cid,
      {int? userCreatedAt}) async {
    final rows = await storage.db.query(tableName,
        where:
            userCreatedAt == null ? 'cid = ?' : 'cid = ? and userCreatedAt = ?',
        whereArgs: userCreatedAt == null ? [cid] : [cid, userCreatedAt],
        orderBy: 'updatedAt desc, userCreatedAt desc',
        limit: 1);
    return rows.isEmpty ? null : _decode(rows.single['report']);
  }

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw is! String) return null;
    final value = jsonDecode(raw);
    return value is Map ? value.cast<String, dynamic>() : null;
  }
}
