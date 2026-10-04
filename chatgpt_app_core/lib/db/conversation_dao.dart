import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:sqflite/sqflite.dart';

///会话列表数据操作接口
abstract class IConversationList {
  ///保存会话并返回数据库记录的id
  Future<int?> saveConversation(ConversationModel model);

  Future<void> deleteConversation(ConversationModel model);

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

  ///更新当前会话的 DeepSeek 思考强度；null 恢复跟随默认。
  Future<int> updateReasoningEffort(
      ConversationModel model, DeepSeekReasoningEffort? effort);

  ///更新会话级语音偏好。bool 为 null 时恢复默认；locale/rate/style 为 null 时跟随系统/默认。
  Future<int> updateVoicePrefs(
    ConversationModel model, {
    bool? speechInputEnabled,
    bool? readAloudEnabled,
    String? voiceLocale,
    double? voiceRate,
    String? voiceStyle,
    String? readAloudTriggerMode,
  });

  ///更新会话级角色状态。只作用于当前会话，用于补充场景、关系和语气备注。
  Future<int> updateRoleState(
    ConversationModel model, {
    String? roleScene,
    String? roleRelationship,
    String? roleToneNote,
  });

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
  final String sourceLabel;
  final int? targetMessageCreatedAt;
  final List<ConversationSearchHit> messageHits;

  ConversationSearchResult({
    required this.conversation,
    required this.snippet,
    this.sourceLabel = '',
    this.targetMessageCreatedAt,
    List<ConversationSearchHit>? messageHits,
    List<String> messageSnippets = const [],
  }) : messageHits = messageHits ??
            [
              for (final snippet in messageSnippets)
                ConversationSearchHit(snippet: snippet),
            ];

  List<String> get messageSnippets =>
      messageHits.map((hit) => hit.snippet).toList(growable: false);
}

class ConversationSearchHit {
  final String snippet;
  final int? createdAt;

  const ConversationSearchHit({
    required this.snippet,
    this.createdAt,
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
        ', deepSeekReasoningEffort text'
        ', toolIds text, speechInputEnabled integer, readAloudEnabled integer'
        ', voiceLocale text, voiceRate real, voiceStyle text'
        ', readAloudTriggerMode text'
        ', roleScene text, roleRelationship text, roleToneNote text);');
    await storage.db.execute(
        'create unique index if not exists ${_kTableName}_cid_idx on $_kTableName (cid);');
    // 兼容旧表：仅在字段真实缺失时补齐，避免每次启动触发 duplicate-column。
    await SchemaGuard.ensureColumns(
      storage.db,
      table: _kTableName,
      columns: const {
        'assistantId': 'integer',
        'projectId': 'integer',
        'avatarType': 'text',
        'avatarValue': 'text',
        'modelProviderId': 'text',
        'modelId': 'text',
        'webSearchEnabled': 'integer',
        'deepSeekReasoningEffort': 'text',
        'toolIds': 'text',
        'speechInputEnabled': 'integer',
        'readAloudEnabled': 'integer',
        'voiceLocale': 'text',
        'voiceRate': 'real',
        'voiceStyle': 'text',
        'readAloudTriggerMode': 'text',
        'roleScene': 'text',
        'roleRelationship': 'text',
        'roleToneNote': 'text',
      },
    );
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
  Future<void> deleteConversation(ConversationModel model) async {
    await storage.db.transaction((txn) async {
      if (model.id == null) {
        await txn.delete(tableName, where: 'cid = ?', whereArgs: [model.cid]);
      } else {
        await txn.delete(tableName, where: 'id = ?', whereArgs: [model.id]);
      }
      await txn.delete('tb_messages', where: 'cid = ?', whereArgs: [model.cid]);
      // 老数据库可能从未开启任务模式；只清理已经存在的派生表。
      final workspaceTables = await txn.rawQuery(
          "select name from sqlite_master where type = 'table' and "
          "name in ('tb_agent_workspace_files', 'tb_agent_workspace_revisions')");
      if (workspaceTables.length == 2) {
        await txn.rawDelete(
            'delete from tb_agent_workspace_revisions where fileId in '
            '(select id from tb_agent_workspace_files where cid = ?)',
            [model.cid]);
      }
      final existing = await txn
          .rawQuery("select name from sqlite_master where type = 'table' and "
              "name in ('tb_agent_task_session', 'tb_chat_semantic_summary', "
              "'tb_agent_workspace_files', 'tb_agent_task_criteria', "
              "'tb_agent_verification_turn', 'tb_agent_read_interval', "
              "'tb_agent_verification_report')");
      for (final row in existing) {
        await txn.delete(row['name'] as String,
            where: 'cid = ?', whereArgs: [model.cid]);
      }
    });
  }

  @override
  Future<List<ConversationModel>> getConversationList(
      {int pageIndex = 1,
      int pageSize = 20,
      int? projectId,
      bool uncategorized = false}) async {
    final offset = (pageIndex - 1) * pageSize;
    final filter = _projectWhere(
        baseWhere: 'stickTime <= 0 and title is not null and '
            "trim(title) != '' and lower(trim(title)) != 'null'",
        projectId: projectId,
        uncategorized: uncategorized);
    final results = await storage.db.query(tableName,
        where: filter.$1,
        whereArgs: filter.$2,
        orderBy: 'updateAt desc',
        limit: pageSize,
        offset: offset);

    ///将查询结果转成Dart Model以方便使用
    final list =
        results.map((item) => ConversationModel.fromJson(item)).toList();
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
        baseWhere: 'stickTime > 0 and title is not null and '
            "trim(title) != '' and lower(trim(title)) != 'null'",
        projectId: projectId,
        uncategorized: uncategorized);
    final results = await storage.db.query(tableName,
        where: filter.$1, whereArgs: filter.$2, orderBy: 'stickTime desc');

    ///将查询结果转成Dart Model以方便使用
    final list =
        results.map((item) => ConversationModel.fromJson(item)).toList();
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
  Future<int> updateReasoningEffort(
      ConversationModel model, DeepSeekReasoningEffort? effort) async {
    final changed = await storage.db.update(
        tableName, {'deepSeekReasoningEffort': effort?.wireValue},
        where: model.id == null ? 'cid = ?' : 'id = ?',
        whereArgs: [model.id ?? model.cid]);
    if (changed == 0 && model.id != null) {
      throw StateError('会话已不存在，无法保存思考强度');
    }
    // 新会话暂未落库时只改内存，首次发送/保存草稿会随整行一起保存。
    model.deepSeekReasoningEffort = effort;
    return changed;
  }

  @override
  Future<int> updateVoicePrefs(
    ConversationModel model, {
    bool? speechInputEnabled,
    bool? readAloudEnabled,
    String? voiceLocale,
    double? voiceRate,
    String? voiceStyle,
    String? readAloudTriggerMode,
  }) {
    model.speechInputEnabled = speechInputEnabled;
    model.readAloudEnabled = readAloudEnabled;
    model.voiceLocale = voiceLocale;
    model.voiceRate = voiceRate;
    model.voiceStyle = voiceStyle;
    model.readAloudTriggerMode = readAloudTriggerMode;
    return storage.db.update(
        tableName,
        {
          'speechInputEnabled':
              speechInputEnabled == null ? null : (speechInputEnabled ? 1 : 0),
          'readAloudEnabled':
              readAloudEnabled == null ? null : (readAloudEnabled ? 1 : 0),
          'voiceLocale': voiceLocale,
          'voiceRate': voiceRate,
          'voiceStyle': voiceStyle,
          'readAloudTriggerMode': readAloudTriggerMode,
        },
        where: model.id == null ? 'cid = ?' : 'id = ?',
        whereArgs: [model.id ?? model.cid]);
  }

  @override
  Future<int> updateRoleState(
    ConversationModel model, {
    String? roleScene,
    String? roleRelationship,
    String? roleToneNote,
  }) {
    model.roleScene = roleScene;
    model.roleRelationship = roleRelationship;
    model.roleToneNote = roleToneNote;
    return storage.db.update(
        tableName,
        {
          'roleScene': roleScene,
          'roleRelationship': roleRelationship,
          'roleToneNote': roleToneNote,
        },
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
      ', max(case when m.content like ? then m.createdAt else null end) as hitMessageCreatedAt '
      ', (case when c.title like ? then 100 else 0 end '
      '+ case when c.lastMessage like ? then 50 else 0 end '
      '+ max(case when m.content like ? then 10 else 0 end)) as relevance '
      'from $tableName c '
      'left join tb_messages m on m.cid = c.cid '
      'where $where '
      'group by c.id '
      'order by relevance desc, c.stickTime desc, c.updateAt desc '
      'limit ?',
      [
        like,
        like,
        like,
        like,
        like,
        ...whereArgs,
        limit.clamp(1, 100),
      ],
    );
    final results = <ConversationSearchResult>[];
    for (final row in rows) {
      final title = row['title'] as String?;
      final lastMessage = row['lastMessage'] as String?;
      final hitMessage = row['hitMessage'] as String?;
      final sourceLabel = _searchSourceLabel(q, title, lastMessage, hitMessage);
      final conversation = ConversationModel.fromJson(row);
      final messageHits = sourceLabel == '历史消息'
          ? await _messageHitSnippets(conversation.cid, q)
          : const <ConversationSearchHit>[];
      results.add(ConversationSearchResult(
        conversation: conversation,
        snippet: messageHits.isNotEmpty
            ? messageHits.first.snippet
            : _searchSnippet(q, title, lastMessage, hitMessage),
        sourceLabel: sourceLabel,
        targetMessageCreatedAt: messageHits.isNotEmpty
            ? messageHits.first.createdAt
            : (sourceLabel == '历史消息'
                ? _asInt(row['hitMessageCreatedAt'])
                : null),
        messageHits: messageHits,
      ));
    }
    return results;
  }

  Future<List<ConversationSearchHit>> _messageHitSnippets(
    int cid,
    String query,
  ) async {
    final rows = await storage.db.query(
      'tb_messages',
      columns: ['content', 'createdAt'],
      where: 'cid = ? and content like ?',
      whereArgs: [cid, '%$query%'],
      orderBy: 'createdAt desc',
      limit: 4,
    );
    final seen = <String>{};
    final hits = <ConversationSearchHit>[];
    for (final row in rows) {
      final content = row['content'] as String? ?? '';
      final snippet = _capAround(content, query);
      if (!seen.add(snippet)) continue;
      final createdAt = _asInt(row['createdAt']);
      if (createdAt == null) continue;
      hits.add(ConversationSearchHit(snippet: snippet, createdAt: createdAt));
    }
    return hits;
  }

  static int? _asInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
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

  static String _searchSourceLabel(
      String query, String? title, String? lastMessage, String? hitMessage) {
    final lower = query.toLowerCase();
    if (title?.toLowerCase().contains(lower) == true) return '标题';
    if (lastMessage?.toLowerCase().contains(lower) == true) return '最近消息';
    if (hitMessage?.toLowerCase().contains(lower) == true) return '历史消息';
    return '';
  }

  static String _capAround(String text, String query) {
    const maxFullLength = 160;
    const contextBefore = 48;
    const contextAfter = 96;
    if (text.length <= maxFullLength) return text;
    final lower = text.toLowerCase();
    final index = lower.indexOf(query.toLowerCase());
    if (index < 0) return '${text.substring(0, maxFullLength)}...';
    final rawStart = (index - contextBefore).clamp(0, text.length);
    final rawEnd = (index + query.length + contextAfter).clamp(0, text.length);
    var start = rawStart;
    var end = rawEnd;

    if (rawStart > 0) {
      final boundary = _lastContextBoundary(text, rawStart, index);
      if (boundary != null) start = boundary + 1;
    }
    final trailingBoundary =
        _firstContextBoundary(text, index + query.length, rawEnd);
    if (trailingBoundary != null) end = trailingBoundary + 1;
    final body = text.substring(start, end).trim();
    return '${start > 0 ? '...' : ''}$body${end < text.length ? '...' : ''}';
  }

  static int? _lastContextBoundary(String text, int start, int end) {
    for (var i = end - 1; i >= start; i--) {
      if (_isSearchContextBoundary(text[i])) return i;
    }
    return null;
  }

  static int? _firstContextBoundary(String text, int start, int end) {
    for (var i = start; i < end; i++) {
      if (_isSearchContextBoundary(text[i])) return i;
    }
    return null;
  }

  static bool _isSearchContextBoundary(String char) =>
      char == '\n' ||
      char == '。' ||
      char == '！' ||
      char == '？' ||
      char == '；' ||
      char == ';' ||
      char == '.' ||
      char == '!' ||
      char == '?';

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
