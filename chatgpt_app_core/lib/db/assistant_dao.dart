import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

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
    // 兼容旧表：无 tools 列时自动新增（L1 助手绑定工具）。
    try {
      await storage.db
          .execute('alter table $_kTableName add column tools text');
    } catch (_) {
      // 列已存在，忽略
    }
    // 兼容旧表：无 providerId 列时自动新增（MVP 级助手模型供应商覆盖）。
    try {
      await storage.db
          .execute('alter table $_kTableName add column providerId text');
    } catch (_) {
      // 列已存在，忽略
    }
    for (final column in const [
      'description text',
      'openingMessage text',
      'exampleDialogs text',
      'memoryBook text',
      'worldBookJson text',
      'roleCardAssets text',
      'defaultVoiceStyle text',
      'avatarType text',
      'avatarValue text',
    ]) {
      try {
        await storage.db.execute('alter table $_kTableName add column $column');
      } catch (_) {
        // 列已存在，忽略
      }
    }
    return AssistantDao._(storage);
  }

  @override
  String tableName = 'tb_assistant';

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
  Future<int> deleteAssistant(int id) {
    // 不级联清理会话的 assistantId：引用悬空时 getAssistant 返回 null，
    // 会话自然回落「无助手」（见 ConversationPage._loadAssistant）。
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
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
