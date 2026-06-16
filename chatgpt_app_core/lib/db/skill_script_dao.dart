import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/skill_script.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 技能脚本数据操作接口。一个脚本绑定一个助手（assistantId），
/// 同一助手下按 name 唯一定位。
abstract class ISkillScript {
  /// 保存脚本（无 id 插入、有 id 更新），返回 id。
  Future<int?> saveScript(SkillScript model);

  /// 某助手的全部脚本。
  Future<List<SkillScript>> getScripts(int assistantId);

  /// 按助手 + 文件名取单个脚本，不存在返回 null。
  Future<SkillScript?> getScript(int assistantId, String name);

  /// 删除某助手的全部脚本（助手删除时调用）。
  Future<int> deleteForAssistant(int assistantId);

  /// 更新一条脚本的审计结论。
  Future<int> updateAudit(int id, String level, String summary);
}

/// 技能脚本 DAO。表 `tb_skill_script`：id, assistantId, name, code,
/// auditLevel, auditSummary, createdAt；按 assistantId 建索引。
class SkillScriptDao implements ISkillScript, ITable {
  final HiDBManager storage;

  SkillScriptDao._(this.storage);

  static const _kTableName = 'tb_skill_script';

  /// 静态工厂，确保表与索引创建完成后再返回实例。
  static Future<SkillScriptDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', assistantId integer, name text, code text'
        ', auditLevel text, auditSummary text, createdAt integer);');
    await storage.db.execute(
        'create index if not exists ${_kTableName}_assistant_idx on $_kTableName(assistantId);');
    return SkillScriptDao._(storage);
  }

  @override
  String tableName = 'tb_skill_script';

  @override
  Future<int?> saveScript(SkillScript model) async {
    if (model.createdAt == 0) {
      model.createdAt = DateTime.now().millisecondsSinceEpoch;
    }
    if (model.id == null) {
      final data = model.toJson()..remove('id');
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      AILogger.log('skill script saved: ${model.name}#$id (a=${model.assistantId})');
      return id;
    }
    await storage.db.update(tableName, model.toJson(),
        where: 'id = ?', whereArgs: [model.id]);
    return model.id;
  }

  @override
  Future<List<SkillScript>> getScripts(int assistantId) async {
    final rows = await storage.db.query(tableName,
        where: 'assistantId = ?', whereArgs: [assistantId], orderBy: 'id asc');
    return rows.map((r) => SkillScript.fromJson(r)).toList();
  }

  @override
  Future<SkillScript?> getScript(int assistantId, String name) async {
    final rows = await storage.db.query(tableName,
        where: 'assistantId = ? and name = ?',
        whereArgs: [assistantId, name],
        limit: 1);
    if (rows.isEmpty) return null;
    return SkillScript.fromJson(rows.first);
  }

  @override
  Future<int> deleteForAssistant(int assistantId) {
    return storage.db
        .delete(tableName, where: 'assistantId = ?', whereArgs: [assistantId]);
  }

  @override
  Future<int> updateAudit(int id, String level, String summary) {
    return storage.db.update(
        tableName, {'auditLevel': level, 'auditSummary': summary},
        where: 'id = ?', whereArgs: [id]);
  }
}
