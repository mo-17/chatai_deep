import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:sqflite/sqflite.dart';

///助手数据操作接口（阶段七）
abstract class IAssistant {
  ///保存助手（无 id 插入，有 id 更新），返回数据库记录的 id
  Future<int?> saveAssistant(AssistantModel model);

  Future<int> deleteAssistant(int id);

  ///全量列表（按更新时间倒序）
  Future<List<AssistantModel>> getAssistants();

  ///按 id 查单个，不存在（如已被删除）返回 null
  Future<AssistantModel?> getAssistant(int id);
}

class AssistantDao implements IAssistant, ITable {
  final HiDBManager storage;

  AssistantDao._(this.storage);

  static const _kTableName = 'tb_assistant';

  /// 静态工厂，确保表创建完成后再返回实例
  static Future<AssistantDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', name text, emoji text, avatarType text, avatarValue text'
        ', prompt text, description text'
        ', openingMessage text, exampleDialogs text, memoryBook text, worldBookJson text, roleCardAssets text'
        ', defaultVoiceStyle text'
        ', providerId text, model text'
        ', useTools integer, tools text, createdAt integer, updatedAt integer);');
    // 兼容旧表：仅补齐真实缺失的助手字段。
    await SchemaGuard.ensureColumns(
      storage.db,
      table: _kTableName,
      columns: const {
        'tools': 'text',
        'providerId': 'text',
        'description': 'text',
        'openingMessage': 'text',
        'exampleDialogs': 'text',
        'memoryBook': 'text',
        'worldBookJson': 'text',
        'roleCardAssets': 'text',
        'defaultVoiceStyle': 'text',
        'avatarType': 'text',
        'avatarValue': 'text',
      },
    );
    return AssistantDao._(storage);
  }

  @override
  String tableName = 'tb_assistant';

  Future<AssistantRowSnapshot?> snapshot(int id) async {
    final rows = await storage.db
        .query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : AssistantRowSnapshot(rows.single);
  }

  /// 新卡资源可以先写入独立 generation；事务插入时仍检查预留 id 未被占用。
  Future<int> nextInsertionId() async {
    final rows =
        await storage.db.rawQuery('select max(id) as lastId from $tableName');
    final sequences = await storage.db.rawQuery(
        'select seq from sqlite_sequence where name = ?', [tableName]);
    final maximum = rows.single['lastId'] as int? ?? 0;
    final sequence =
        sequences.isEmpty ? 0 : sequences.single['seq'] as int? ?? 0;
    return (maximum > sequence ? maximum : sequence) + 1;
  }

  /// 管理页用原行快照做 CAS，不以旧内存整行复活已删除/编辑的对象。
  /// 返回值和输入对象分离，提交成功后才由页面接纳。
  Future<AssistantMutationResult> saveChecked(
    AssistantModel source, {
    AssistantRowSnapshot? expected,
    int? reservedId,
    bool renameOnConflict = false,
    Future<void> Function(Transaction)? validateBeforeCommit,
  }) async {
    final candidate = AssistantModel.fromJson(source.toJson());
    return storage.db.transaction((txn) async {
      Map<String, Object?>? current;
      if (expected != null) {
        final rows = await txn.query(tableName,
            where: 'id = ?', whereArgs: [expected.id], limit: 1);
        if (rows.isEmpty ||
            !expected.matches(rows.single) ||
            candidate.id != expected.id) {
          throw const AssistantMutationStale();
        }
        current = rows.single;
      } else if (candidate.id != null) {
        throw const AssistantMutationStale();
      }
      final names = await txn.query(tableName, columns: ['id', 'name']);
      final taken = names
          .where((row) => row['id'] != expected?.id)
          .map((row) => (row['name'] as String? ?? '').trim().toLowerCase())
          .toSet();
      final name = candidate.name.trim();
      if (name.isEmpty) throw const FormatException('请输入角色名称');
      if (taken.contains(name.toLowerCase())) {
        if (!renameOnConflict) throw const AssistantNameConflict();
        var suffix = 2;
        while (taken.contains('$name ($suffix)'.toLowerCase())) {
          suffix++;
        }
        candidate.name = '$name ($suffix)';
      } else {
        candidate.name = name;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final previousTime = current?['updatedAt'] as int? ?? 0;
      candidate.updatedAt = now > previousTime ? now : previousTime + 1;
      candidate.createdAt = current?['createdAt'] as int? ?? now;
      if (expected == null) {
        final data = candidate.toJson()..remove('id');
        if (reservedId != null) data['id'] = reservedId;
        candidate.id = await txn.insert(tableName, data);
      } else {
        final data = candidate.toJson()..remove('id');
        final changed = await txn.update(tableName, data,
            where: 'id = ? and updatedAt is ?',
            whereArgs: [expected.id, current?['updatedAt']]);
        if (changed != 1) throw const AssistantMutationStale();
      }
      if (validateBeforeCommit != null) await validateBeforeCommit(txn);
      final rows = await txn.query(tableName,
          where: 'id = ?', whereArgs: [candidate.id], limit: 1);
      return AssistantMutationResult(
          candidate, AssistantRowSnapshot(rows.single));
    });
  }

  Future<void> deleteChecked(AssistantRowSnapshot expected) async {
    await storage.db.transaction((txn) async {
      final rows = await txn.query(tableName,
          where: 'id = ?', whereArgs: [expected.id], limit: 1);
      if (rows.isEmpty || !expected.matches(rows.single)) {
        throw const AssistantMutationStale();
      }
      final tables = await txn.rawQuery(
          "select name from sqlite_master where type = 'table' and name = ?",
          ['tb_assistant_memory']);
      if (tables.isNotEmpty) {
        await txn.delete('tb_assistant_memory',
            where: 'assistantId = ?', whereArgs: [expected.id]);
      }
      if (await txn
              .delete(tableName, where: 'id = ?', whereArgs: [expected.id]) !=
          1) {
        throw const AssistantMutationStale();
      }
    });
  }

  @override
  Future<int?> saveAssistant(AssistantModel model) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    model.updatedAt = now;
    if (model.id == null) {
      model.createdAt = now;
      final data = model.toJson()..remove('id');
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      AILogger.log('assistant created: ${model.name}#$id');
      return id;
    }
    await storage.db.update(tableName, model.toJson(),
        where: 'id = ?', whereArgs: [model.id]);
    AILogger.log('assistant updated: ${model.name}#${model.id}');
    return model.id;
  }

  @override
  Future<int> deleteAssistant(int id) async {
    // 不级联清理会话的 assistantId：引用悬空时 getAssistant 返回 null，
    // 会话自然回落「无助手」（见 ConversationPage._loadAssistant）。
    return storage.db.transaction((txn) async {
      final memoryTable = await txn.rawQuery(
        "select name from sqlite_master where type = 'table' and name = ?",
        const ['tb_assistant_memory'],
      );
      if (memoryTable.isNotEmpty) {
        await txn.delete(
          'tb_assistant_memory',
          where: 'assistantId = ?',
          whereArgs: [id],
        );
      }
      return txn.delete(tableName, where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<List<AssistantModel>> getAssistants() async {
    final results =
        await storage.db.query(tableName, orderBy: 'updatedAt desc');
    final assistants =
        results.map((item) => AssistantModel.fromJson(item)).toList();
    for (final assistant in assistants) {
      await _resolveAssistantAvatar(assistant);
    }
    return assistants;
  }

  @override
  Future<AssistantModel?> getAssistant(int id) async {
    final results = await storage.db
        .query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
    if (results.isEmpty) return null;
    final assistant = AssistantModel.fromJson(results.first);
    await _resolveAssistantAvatar(assistant);
    return assistant;
  }

  Future<void> _resolveAssistantAvatar(AssistantModel assistant) async {
    if (assistant.avatarType != AvatarAssetService.imageType) return;
    final current = assistant.avatarValue?.trim() ?? '';
    if (current.isEmpty) return;
    final resolved = await AvatarAssetService.resolveManagedPath(current);
    if (resolved == null || resolved == current) return;
    assistant.avatarValue = resolved;
    final id = assistant.id;
    if (id == null) return;
    await storage.db.update(
      tableName,
      {'avatarValue': resolved},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

class AssistantRowSnapshot {
  final Map<String, Object?> row;
  final String fingerprint;
  AssistantRowSnapshot(Map<String, Object?> source)
      : row = Map.unmodifiable(source),
        fingerprint = _fingerprint(source);
  int get id => row['id'] as int;
  bool matches(Map<String, Object?> current) =>
      fingerprint == _fingerprint(current);
  bool matchesModel(AssistantModel model) =>
      jsonEncode(AssistantModel.fromJson(row).toJson()) ==
      jsonEncode(model.toJson());
  static String _fingerprint(Map<String, Object?> value) {
    final keys = value.keys.toList()..sort();
    return sha256
        .convert(
            utf8.encode(jsonEncode({for (final key in keys) key: value[key]})))
        .toString();
  }
}

class AssistantMutationResult {
  final AssistantModel assistant;
  final AssistantRowSnapshot snapshot;
  const AssistantMutationResult(this.assistant, this.snapshot);
}

class AssistantMutationStale implements Exception {
  const AssistantMutationStale();
  @override
  String toString() => '角色已被修改、删除或恢复，请刷新后重试';
}

class AssistantNameConflict implements Exception {
  const AssistantNameConflict();
  @override
  String toString() => '同名角色已存在，请另存或重新选择覆盖目标';
}
