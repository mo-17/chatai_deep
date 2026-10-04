import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:sqflite/sqflite.dart';

/// 列表只读取当前账号的数据库；打开前仍需重新确认会话和最新用户消息。
class AgentTaskCenterEntry {
  final int cid;
  final String title;
  final String preview;
  final String status;
  final bool canResume;
  final bool hasConversation;
  final bool interrupted;
  final int updatedAt;
  final int? userCreatedAt;
  final int completedTodos;
  final int totalTodos;
  final String? pauseReason;
  final int queuePosition;

  const AgentTaskCenterEntry({
    required this.cid,
    required this.title,
    required this.preview,
    required this.status,
    required this.canResume,
    required this.hasConversation,
    required this.interrupted,
    required this.updatedAt,
    required this.userCreatedAt,
    required this.completedTodos,
    required this.totalTodos,
    required this.pauseReason,
    this.queuePosition = 0,
  });
}

class AgentTaskCenterBatch {
  final List<AgentTaskCenterEntry> entries;

  /// 原始任务行的下一页游标。损坏记录被跳过时，仍保证游标前进。
  final int? nextOffset;

  const AgentTaskCenterBatch({required this.entries, this.nextOffset});
}

class AgentTaskCenterService {
  final HiDBManager storage;
  final String? accountHash;
  final AgentTaskExecutor? executor;

  AgentTaskCenterService._(this.storage, this.accountHash, this.executor);

  static Future<AgentTaskCenterService> create(HiDBManager storage,
          {String? accountHash, AgentTaskExecutor? executor}) async =>
      AgentTaskCenterService._(storage, accountHash, executor);

  /// 一个会话仅有一份当前任务快照；旧普通会话和纯模式开关不构成任务。
  Future<AgentTaskCenterBatch> listTasks(
      {int offset = 0, int limit = 30}) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', '必须大于等于 0');
    }
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', '必须为 1 到 100');
    }
    return storage.db.transaction((txn) async {
      final tables = await _tables(txn);
      if (!tables.contains(_taskTable)) {
        return const AgentTaskCenterBatch(entries: []);
      }
      final rows = await txn.query(
        _taskTable,
        columns: ['cid', 'snapshot', 'updatedAt'],
        orderBy: 'updatedAt desc, cid desc',
        offset: offset,
        limit: limit,
      );
      final entries = <AgentTaskCenterEntry>[];
      for (final row in rows) {
        final cid = _integer(row['cid']);
        final snapshot = _snapshot(row['snapshot']);
        if (cid == null || snapshot == null || !_hasTask(snapshot)) continue;
        final conversation = await _conversation(txn, tables, cid);
        final latestUserAt = await _latestUserAt(txn, tables, cid);
        entries.add(_entry(row, snapshot, cid, conversation, latestUserAt));
      }
      return AgentTaskCenterBatch(
        entries: List.unmodifiable(entries),
        nextOffset: rows.length == limit ? offset + rows.length : null,
      );
    });
  }

  /// 返回原会话的模型覆盖、助手与偏好，不创建替代会话或重放模型请求。
  Future<ConversationModel?> conversationForTask(
    int cid, {
    bool requireResumable = false,
  }) async {
    return storage.db.transaction((txn) async {
      final tables = await _tables(txn);
      if (!tables.contains(_taskTable)) return null;
      final rows = await txn.query(_taskTable,
          where: 'cid = ?', whereArgs: [cid], limit: 1);
      if (rows.isEmpty) return null;
      final row = rows.single;
      final snapshot = _snapshot(row['snapshot']);
      if (snapshot == null || !_hasTask(snapshot)) return null;
      final conversation = await _conversation(txn, tables, cid);
      if (conversation == null) return null;
      if (requireResumable) {
        final latestUserAt = await _latestUserAt(txn, tables, cid);
        if (!_entry(row, snapshot, cid, conversation, latestUserAt).canResume) {
          return null;
        }
      }
      return conversation;
    });
  }

  static const _taskTable = 'tb_agent_task_session';
  static const _conversationTable = 'tb_conversation_list';
  static const _messageTable = 'tb_messages';

  Future<Set<String>> _tables(DatabaseExecutor db) async {
    final rows = await db
        .rawQuery("select name from sqlite_master where type = 'table' and "
            "name in ('$_taskTable', '$_conversationTable', '$_messageTable')");
    return rows.map((row) => row['name'] as String).toSet();
  }

  Future<ConversationModel?> _conversation(
    DatabaseExecutor db,
    Set<String> tables,
    int cid,
  ) async {
    if (!tables.contains(_conversationTable)) return null;
    final rows = await db.query(_conversationTable,
        where: 'cid = ?', whereArgs: [cid], limit: 1);
    if (rows.isEmpty) return null;
    final data = Map<String, dynamic>.from(rows.single);
    // 老表可没有可选字段，空头像或空置顶时间不应阻止打开原对话。
    data['cid'] = cid;
    data['id'] = _integer(data['id']);
    data['icon'] = _text(data['icon']) ?? '🤖';
    data['title'] = _text(data['title']);
    data['lastMessage'] = _text(data['lastMessage']);
    data['updateAt'] = _integer(data['updateAt']);
    data['stickTime'] = _integer(data['stickTime']) ?? 0;
    data['messageCount'] = _integer(data['messageCount']);
    try {
      return ConversationModel.fromJson(data);
    } on TypeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<int?> _latestUserAt(
    DatabaseExecutor db,
    Set<String> tables,
    int cid,
  ) async {
    if (!tables.contains(_messageTable)) return null;
    final rows = await db.query(
      _messageTable,
      columns: ['createdAt'],
      where: 'cid = ? and ownerType = ?',
      whereArgs: [cid, 'OwnerType.sender'],
      orderBy: 'createdAt desc, id desc',
      limit: 1,
    );
    return rows.isEmpty ? null : _integer(rows.single['createdAt']);
  }

  AgentTaskCenterEntry _entry(
    Map<String, Object?> row,
    Map<String, dynamic> snapshot,
    int cid,
    ConversationModel? conversation,
    int? latestUserAt,
  ) {
    final prompt = _text(snapshot['prompt'])!.trim();
    final userAt = _integer(snapshot['userCreatedAt']);
    final rawStatus = _text(snapshot['status']) ?? 'idle';
    final interrupted = rawStatus == 'running';
    final knownStatus =
        const ['idle', 'running', 'paused', 'complete'].contains(rawStatus);
    final status = interrupted || !knownStatus ? 'paused' : rawStatus;
    final rawTodos = snapshot['todos'];
    final todos = rawTodos is List
        ? rawTodos.whereType<Map>().where((todo) =>
            _text(todo['content'])?.trim().isNotEmpty == true &&
            const ['pending', 'in_progress', 'completed']
                .contains(todo['status']))
        : const <Map>[];
    final totalTodos = todos.length;
    final completedTodos =
        todos.where((todo) => todo['status'] == 'completed').length;
    var canResume = snapshot['enabled'] == true &&
        const ['running', 'paused'].contains(rawStatus) &&
        conversation != null &&
        userAt != null &&
        latestUserAt == userAt;
    var reason = _text(snapshot['pauseReason']);
    if (!knownStatus || !_usableResumeSnapshot(snapshot)) {
      canResume = false;
      reason = '任务快照格式无效，无法继续';
    } else if (conversation == null) {
      reason = '原对话已不存在或无法读取';
    } else if (snapshot['enabled'] != true) {
      reason = '此对话已关闭任务模式';
    } else if (latestUserAt != userAt) {
      reason = '任务消息已被删除或已有新的用户输入';
    } else if (interrupted && (reason == null || reason.trim().isEmpty)) {
      reason = '应用中断，可继续';
    }
    final live = accountHash == null
        ? null
        : executor?.lookup(AgentTaskKey(accountHash!, cid));
    final busy = live?.busy == true;
    final queuePosition =
        busy && live!.queued ? executor!.queuePosition(live.key) : 0;
    final title = _usableTitle(conversation?.title);
    return AgentTaskCenterEntry(
      cid: cid,
      title: _shortText(title ?? prompt, 80),
      preview: _shortText(prompt, 200),
      status: busy ? (live!.queued ? 'queued' : 'running') : status,
      canResume: !busy && canResume,
      hasConversation: conversation != null,
      interrupted: !busy && interrupted,
      updatedAt: _integer(row['updatedAt']) ?? conversation?.updateAt ?? 0,
      userCreatedAt: userAt,
      completedTodos: completedTodos,
      totalTodos: totalTodos,
      pauseReason: busy
          ? (live!.queued
              ? '等待执行（队列第 $queuePosition 位）'
              : live.progress?.label ?? '正在执行')
          : reason == null
              ? null
              : _shortText(reason, 300),
      queuePosition: queuePosition,
    );
  }

  static bool _hasTask(Map<String, dynamic> value) =>
      _text(value['prompt'])?.trim().isNotEmpty == true &&
      (_integer(value['userCreatedAt']) ?? 0) > 0;

  static bool _usableResumeSnapshot(Map<String, dynamic> value) {
    for (final key in ['version', 'nextRound', 'generation']) {
      if (value[key] != null && value[key] is! int) return false;
    }
    for (final key in ['enabled', 'needsContinuation', 'backgroundEnabled']) {
      if (value[key] != null && value[key] is! bool) return false;
    }
    for (final key in ['pauseReason', 'executingToolId']) {
      if (value[key] != null && value[key] is! String) return false;
    }
    final version = _integer(value['version']);
    if (version != null && version != 1) return false;
    if ((_integer(value['nextRound']) ?? 0) < 0 ||
        (_integer(value['generation']) ?? 0) < 0) {
      return false;
    }
    final todos = value['todos'];
    if (todos != null &&
        (todos is! List ||
            todos.length > 20 ||
            todos.any((todo) =>
                todo is! Map ||
                todo['content'] is! String ||
                (todo['content'] as String).trim().isEmpty ||
                !const ['pending', 'in_progress', 'completed']
                    .contains(todo['status'])))) {
      return false;
    }
    final messages = value['messages'];
    return messages == null ||
        (messages is List && messages.every(_usableMessage));
  }

  static bool _usableMessage(Object? value) {
    if (value is! Map ||
        !const ['system', 'user', 'assistant', 'tool']
            .contains(value['role'])) {
      return false;
    }
    for (final key in ['content', 'reasoning_content', 'tool_call_id']) {
      if (value[key] != null && value[key] is! String) return false;
    }
    final calls = value['tool_calls'];
    if (calls == null) return true;
    if (calls is! List) return false;
    return calls.every((call) {
      if (call is! Map || call['id'] is! String) return false;
      final function = call['function'];
      return function is Map &&
          function['name'] is String &&
          function['arguments'] is String;
    });
  }

  static Map<String, dynamic>? _snapshot(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } on FormatException {
      return null;
    }
  }

  static String? _text(Object? raw) => raw is String ? raw : null;

  static String? _usableTitle(String? raw) {
    final title = raw?.trim();
    return title == null || title.isEmpty || title.toLowerCase() == 'null'
        ? null
        : title;
  }

  static int? _integer(Object? raw) => raw is int ? raw : null;

  static String _shortText(String value, int maxChars) {
    final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.length <= maxChars) return text;
    var end = maxChars - 1;
    final previous = text.codeUnitAt(end - 1);
    if (previous >= 0xd800 && previous <= 0xdbff) end--;
    return '${text.substring(0, end)}…';
  }
}
