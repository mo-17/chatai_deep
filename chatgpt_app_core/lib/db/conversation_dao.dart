import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:sqflite/sqflite.dart';

///会话列表数据操作接口
abstract class IConversationList {
  ///保存会话并返回数据库记录的id
  Future<int?> saveConversation(ConversationModel model);

  void deleteConversation(ConversationModel model);

  ///分页查询，pageIndex页码从1开始，pageSize每页显示的数据量
  Future<List<ConversationModel>> getConversationList(
      {int pageIndex = 1,
      int pageSize = 20,
      int? projectId,
      bool uncategorized = false});

  ///置顶与取消置顶
  Future<int> updateStickTime(ConversationModel model, {bool isStick = false});

  ///查询置顶的会话
  Future<List<ConversationModel>> getStickConversationList(
      {int? projectId, bool uncategorized = false});

  ///移动会话到项目；projectId 为 null 时移动到「未分类」。
  Future<int> updateProjectId(ConversationModel model, int? projectId);

  ///更新会话自定义头像。type/value 为 null 时恢复默认头像。
  Future<int> updateAvatar(
      ConversationModel model, String? avatarType, String? avatarValue);

  ///更新会话级模型覆盖。providerId/modelId 为 null 时恢复跟随全局设置。
  Future<int> updateModelOverride(
      ConversationModel model, String? providerId, String? modelId);

  ///更新会话级联网搜索覆盖。enabled 为 null 时恢复跟随全局设置。
  Future<int> updateWebSearchOverride(ConversationModel model, bool? enabled);

  ///搜索会话标题、最近消息和全量消息内容。
  Future<List<ConversationSearchResult>> searchConversations(String query,
      {int? projectId,
      bool uncategorized = false,
      int? assistantId,
      String? modelId,
      int? updatedAfter,
      int? updatedBefore,
      int limit = 50});
}

class ConversationSearchResult {
  final ConversationModel conversation;
  final String snippet;

  const ConversationSearchResult({
    required this.conversation,
    required this.snippet,
  });
}

class ConversationListDao implements IConversationList, ITable {
  final HiDBManager storage;

  ConversationListDao._(this.storage);

  static const _kTableName = 'tb_conversation_list';

  /// 静态工厂，确保表和索引创建完成后再返回实例
  static Future<ConversationListDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', cid integer, title	text, icon	text, updateAt	integer'
        ', messageCount	integer, lastMessage	text, stickTime	integer'
        ', assistantId	integer, projectId integer'
        ', avatarType text, avatarValue text'
        ', modelProviderId text, modelId text, webSearchEnabled integer'
        ', toolIds text);');
    await storage.db.execute(
        'create unique index if not exists ${_kTableName}_cid_idx on $_kTableName (cid);');
    // 兼容旧表：无 assistantId 列时自动新增（阶段七 会话绑定助手）。
    try {
      await storage.db
          .execute('alter table $_kTableName add column assistantId integer');
    } catch (_) {
      // 列已存在，忽略
    }
    // 兼容旧表：无 projectId 列时自动新增。null 表示未分类。
    try {
      await storage.db
          .execute('alter table $_kTableName add column projectId integer');
    } catch (_) {
      // 列已存在，忽略
    }
    try {
      await storage.db
          .execute('alter table $_kTableName add column avatarType text');
    } catch (_) {
      // 列已存在，忽略
    }
    try {
      await storage.db
          .execute('alter table $_kTableName add column avatarValue text');
    } catch (_) {
      // 列已存在，忽略
    }
    try {
      await storage.db
          .execute('alter table $_kTableName add column modelProviderId text');
    } catch (_) {
      // 列已存在，忽略
    }
    try {
      await storage.db
          .execute('alter table $_kTableName add column modelId text');
    } catch (_) {
      // 列已存在，忽略
    }
    try {
      await storage.db.execute(
          'alter table $_kTableName add column webSearchEnabled integer');
    } catch (_) {
      // 列已存在，忽略
    }
    try {
      await storage.db
          .execute('alter table $_kTableName add column toolIds text');
    } catch (_) {
      // 列已存在，忽略
    }
    //复合索引：置顶+更新时间排序优化
    await storage.db.execute(
        'create index if not exists ${_kTableName}_stick_update_idx on $_kTableName(stickTime, updateAt desc);');
    await storage.db.execute(
        'create index if not exists ${_kTableName}_project_update_idx on $_kTableName(projectId, updateAt desc);');
    return ConversationListDao._(storage);
  }

  @override
  String tableName = 'tb_conversation_list';

  @override
  void deleteConversation(ConversationModel model) {
    if (model.id == null) {
      storage.db.delete(tableName, where: 'cid = ?', whereArgs: [model.cid]);
    } else {
      storage.db.delete(tableName, where: 'id = ?', whereArgs: [model.id]);
    }

    ///删除对应聊天记录（统一 tb_messages 表，按 cid 删除）
    storage.db.delete('tb_messages', where: 'cid = ?', whereArgs: [model.cid]);
  }

  @override
  Future<List<ConversationModel>> getConversationList(
      {int pageIndex = 1,
      int pageSize = 20,
      int? projectId,
      bool uncategorized = false}) async {
    var offset = (pageIndex - 1) * pageSize;
    final filter = _projectWhere(
        baseWhere: 'stickTime <= 0',
        projectId: projectId,
        uncategorized: uncategorized);
    var results = await storage.db.query(tableName,
        where: filter.$1,
        whereArgs: filter.$2,
        orderBy: 'updateAt desc',
        limit: pageSize,
        offset: offset);

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => ConversationModel.fromJson(item)).toList();
    AILogger.log('conversation list count:${list.length}');
    return list;
  }

  @override
  Future<int?> saveConversation(ConversationModel model) async {
    final id = await storage.db.insert(tableName, model.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    model.id = id;
    return id;
  }

  @override
  Future<List<ConversationModel>> getStickConversationList(
      {int? projectId, bool uncategorized = false}) async {
    final filter = _projectWhere(
        baseWhere: 'stickTime > 0',
        projectId: projectId,
        uncategorized: uncategorized);
    var results = await storage.db.query(tableName,
        where: filter.$1, whereArgs: filter.$2, orderBy: 'stickTime desc');

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => ConversationModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<int> updateStickTime(ConversationModel model, {bool isStick = false}) {
    if (isStick) {
      model.stickTime = DateTime.now().millisecondsSinceEpoch;
    } else {
      model.stickTime = 0;
    }
    return storage.db.update(
      tableName,
      {'stickTime': model.stickTime},
      where: model.id == null ? 'cid = ?' : 'id = ?',
      whereArgs: [model.id ?? model.cid],
    );
  }

  @override
  Future<int> updateProjectId(ConversationModel model, int? projectId) {
    model.projectId = projectId;
    return storage.db.update(tableName, {'projectId': projectId},
        where: model.id == null ? 'cid = ?' : 'id = ?',
        whereArgs: [model.id ?? model.cid]);
  }

  @override
  Future<int> updateAvatar(
      ConversationModel model, String? avatarType, String? avatarValue) {
    model.avatarType = avatarType;
    model.avatarValue = avatarValue;
    return storage.db.update(
        tableName, {'avatarType': avatarType, 'avatarValue': avatarValue},
        where: model.id == null ? 'cid = ?' : 'id = ?',
        whereArgs: [model.id ?? model.cid]);
  }

  @override
  Future<int> updateModelOverride(
      ConversationModel model, String? providerId, String? modelId) {
    model.modelProviderId = providerId;
    model.modelId = modelId;
    return storage.db.update(
        tableName, {'modelProviderId': providerId, 'modelId': modelId},
        where: model.id == null ? 'cid = ?' : 'id = ?',
        whereArgs: [model.id ?? model.cid]);
  }

  @override
  Future<int> updateWebSearchOverride(ConversationModel model, bool? enabled) {
    model.webSearchEnabled = enabled;
    return storage.db.update(tableName,
        {'webSearchEnabled': enabled == null ? null : (enabled ? 1 : 0)},
        where: model.id == null ? 'cid = ?' : 'id = ?',
        whereArgs: [model.id ?? model.cid]);
  }

  @override
  Future<List<ConversationSearchResult>> searchConversations(String query,
      {int? projectId,
      bool uncategorized = false,
      int? assistantId,
      String? modelId,
      int? updatedAfter,
      int? updatedBefore,
      int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final ftsCids = await _ftsCandidateCids(q);
    final useFts = ftsCids != null;
    final filter = _projectWhere(
        baseWhere: useFts
            ? (ftsCids.isEmpty
                ? '1 = 0'
                : 'c.cid in (${List.filled(ftsCids.length, '?').join(',')})')
            : '(c.title like ? or c.lastMessage like ? or m.content like ?)',
        projectId: projectId,
        uncategorized: uncategorized);
    final extraClauses = <String>[];
    final extraArgs = <Object?>[];
    if (assistantId != null) {
      extraClauses.add('c.assistantId = ?');
      extraArgs.add(assistantId);
    }
    final normalizedModel = modelId?.trim();
    if (normalizedModel != null && normalizedModel.isNotEmpty) {
      extraClauses.add('c.modelId = ?');
      extraArgs.add(normalizedModel);
    }
    if (updatedAfter != null) {
      extraClauses.add('c.updateAt >= ?');
      extraArgs.add(updatedAfter);
    }
    if (updatedBefore != null) {
      extraClauses.add('c.updateAt <= ?');
      extraArgs.add(updatedBefore);
    }
    final where = [
      filter.$1,
      ...extraClauses,
    ].join(' and ');
    final like = '%$q%';
    final whereArgs = <Object?>[
      if (useFts) ...ftsCids else ...[like, like, like],
      ...?filter.$2,
      ...extraArgs,
    ];
    final rows = await storage.db.rawQuery(
      'select c.*, '
      'max(case when m.content like ? then m.content else null end) as hitMessage '
      'from $tableName c '
      'left join tb_messages m on m.cid = c.cid '
      'where $where '
      'group by c.id '
      'order by c.stickTime desc, c.updateAt desc '
      'limit ?',
      [
        like,
        ...whereArgs,
        limit.clamp(1, 100),
      ],
    );
    return [
      for (final row in rows)
        ConversationSearchResult(
          conversation: ConversationModel.fromJson(row),
          snippet: _searchSnippet(
            q,
            row['title'] as String?,
            row['lastMessage'] as String?,
            row['hitMessage'] as String?,
          ),
        ),
    ];
  }

  (String, List<Object?>?) _projectWhere({
    required String baseWhere,
    int? projectId,
    bool uncategorized = false,
  }) {
    if (uncategorized) {
      return ('$baseWhere and projectId is null', null);
    }
    if (projectId != null) {
      return ('$baseWhere and projectId = ?', [projectId]);
    }
    return (baseWhere, null);
  }

  static String _searchSnippet(
      String query, String? title, String? lastMessage, String? hitMessage) {
    for (final text in [title, lastMessage, hitMessage]) {
      if (text != null && text.toLowerCase().contains(query.toLowerCase())) {
        return _capAround(text, query);
      }
    }
    return _capAround(hitMessage ?? lastMessage ?? title ?? '', query);
  }

  static String _capAround(String text, String query) {
    if (text.length <= 120) return text;
    final lower = text.toLowerCase();
    final index = lower.indexOf(query.toLowerCase());
    if (index < 0) return '${text.substring(0, 120)}...';
    final start = (index - 40).clamp(0, text.length);
    final end = (index + query.length + 80).clamp(0, text.length);
    return '${start > 0 ? '...' : ''}${text.substring(start, end)}${end < text.length ? '...' : ''}';
  }

  Future<List<int>?> _ftsCandidateCids(String query) async {
    final ftsQuery = _ftsQuery(query);
    if (ftsQuery.isEmpty) return null;
    try {
      final enabled = await storage.db.rawQuery(
          "select sqlite_compileoption_used('ENABLE_FTS5') as enabled");
      if (enabled.isEmpty || enabled.first['enabled'] != 1) return null;
      await storage.db.execute(
          'create virtual table if not exists tb_conversation_search_fts '
          'using fts5(cid unindexed, title, lastMessage, content);');
      await storage.db.delete('tb_conversation_search_fts');
      await storage.db.rawInsert(
        'insert into tb_conversation_search_fts(cid, title, lastMessage, content) '
        'select c.cid, coalesce(c.title, ""), coalesce(c.lastMessage, ""), '
        'coalesce(m.content, "") from tb_conversation_list c '
        'left join tb_messages m on m.cid = c.cid',
      );
      final rows = await storage.db.rawQuery(
        'select distinct cid from tb_conversation_search_fts '
        'where tb_conversation_search_fts match ? limit 200',
        [ftsQuery],
      );
      return [
        for (final row in rows)
          if (row['cid'] is int) row['cid'] as int,
      ];
    } catch (_) {
      return null;
    }
  }

  static String _ftsQuery(String query) => query
      .trim()
      .split(RegExp(r'\s+'))
      .map((term) => term.replaceAll(RegExp(r'[^0-9A-Za-z_\u4e00-\u9fa5]'), ''))
      .where((term) => term.isNotEmpty)
      .map((term) => '$term*')
      .join(' ');
}
