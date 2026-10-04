import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:sqflite/sqflite.dart';

/// 只公开工具身份；参数、结果正文和模型推理不进入任务详情数据。
class AgentTaskToolReference {
  final String toolId;
  final String name;
  const AgentTaskToolReference({required this.toolId, required this.name});
}

/// 输出绑定本轮实际记录的版本，不随文件更新自动改指向。
class AgentTaskOutputReference {
  final int fileId;
  final String name;
  final int revision;
  final int? currentRevision;
  final bool available;
  const AgentTaskOutputReference(
      {required this.fileId,
      required this.name,
      required this.revision,
      this.currentRevision,
      this.available = false});
  bool get isCurrent => available && revision == currentRevision;
}

class AgentTaskDetail {
  final int cid;
  final int userCreatedAt;
  final int generation;
  final String title;
  final String prompt;
  final String status;
  final bool enabled;
  final bool backgroundEnabled;
  final int nextRound;
  final List<AgentTodo> todos;
  final String? pauseReason;
  final bool hasConversation;
  final bool canResume;
  final bool snapshotValid;
  final bool interrupted;
  final bool latestUserMatches;
  final int queuePosition;
  final int updatedAt;
  final int pairedToolResultCount;
  final List<AgentTaskToolReference> pairedTools;
  final AgentTaskToolReference? pendingApproval;
  final List<AgentTaskToolReference> uncertainTools;
  final AgentTaskVerificationReport? verificationReport;
  final bool verificationIsCurrent;
  final List<AgentTaskOutputReference> outputs;
  final ChatFailureDiagnosis? failureDiagnosis;
  final ConversationModel? conversation;

  AgentTaskDetail(
      {required this.cid,
      required this.userCreatedAt,
      required this.generation,
      this.title = '',
      this.prompt = '',
      this.status = 'paused',
      this.enabled = false,
      this.backgroundEnabled = true,
      this.nextRound = 0,
      List<AgentTodo> todos = const [],
      this.pauseReason,
      this.hasConversation = false,
      this.canResume = false,
      this.snapshotValid = true,
      this.interrupted = false,
      this.latestUserMatches = false,
      this.queuePosition = 0,
      this.updatedAt = 0,
      this.pairedToolResultCount = 0,
      List<AgentTaskToolReference> pairedTools = const [],
      this.pendingApproval,
      List<AgentTaskToolReference> uncertainTools = const [],
      this.verificationReport,
      this.verificationIsCurrent = false,
      List<AgentTaskOutputReference> outputs = const [],
      this.failureDiagnosis,
      this.conversation})
      : todos = List.unmodifiable(todos),
        pairedTools = List.unmodifiable(pairedTools),
        uncertainTools = List.unmodifiable(uncertainTools),
        outputs = List.unmodifiable(outputs);

  /// 兼容展示调用方；有结果包含拒绝和错误，不意味着业务成功。
  int get completedToolCount => pairedToolResultCount;
}

/// 固定使用注入的账号数据库；只读，不创建表、不发送请求或执行恢复。
class AgentTaskDetailService {
  final HiDBManager storage;
  final String? accountHash;
  final AgentTaskExecutor? executor;
  AgentTaskDetailService._(this.storage, this.accountHash, this.executor);

  static Future<AgentTaskDetailService> create(HiDBManager storage,
          {String? accountHash, AgentTaskExecutor? executor}) async =>
      AgentTaskDetailService._(storage, accountHash, executor);

  Future<AgentTaskDetail?> loadDetail(int cid) =>
      storage.db.transaction((txn) => _load(txn, cid));

  /// 点击操作时重新读取身份；旧详情不能暂停/恢复后来替换的任务。
  Future<bool> validateIdentity(int cid,
      {required int userCreatedAt, required int generation}) async {
    final detail = await loadDetail(cid);
    return detail != null &&
        detail.snapshotValid &&
        detail.hasConversation &&
        detail.latestUserMatches &&
        detail.userCreatedAt == userCreatedAt &&
        detail.generation == generation;
  }

  /// 恢复需要任务身份、最新用户轮次和会话都仍匹配；此方法本身不执行。
  Future<ConversationModel?> conversationForResume(int cid,
          {required int userCreatedAt, required int generation}) =>
      storage.db.transaction((txn) async {
        final detail = await _load(txn, cid);
        if (detail == null ||
            !detail.canResume ||
            detail.userCreatedAt != userCreatedAt ||
            detail.generation != generation) {
          return null;
        }
        return detail.conversation;
      });

  Future<AgentTaskDetail?> _load(Transaction txn, int cid) async {
    final tables = (await txn
            .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
        .map((row) => row['name'])
        .toSet();
    if (!tables.contains('tb_agent_task_session')) return null;
    final rows = await txn.query('tb_agent_task_session',
        where: 'cid=?', whereArgs: [cid], limit: 1);
    if (rows.isEmpty) return null;
    var snapshot = _jsonMap(rows.single['snapshot']);
    final key = accountHash == null ? null : AgentTaskKey(accountHash!, cid);
    final live = key == null || executor?.accountCurrent(key) != true
        ? null
        : executor?.lookup(key);
    final busy = live?.busy == true && live?.isRetired != true;
    if (busy) {
      // 同步深拷贝，避免后续工具 checkpoint 改变本次只读快照。
      snapshot = _jsonMap(jsonEncode(live!.prepared.session.toJson()));
    }
    if (snapshot == null) return null;
    final userAt = _positiveInt(snapshot['userCreatedAt']);
    final prompt = snapshot['prompt'];
    // 旧普通对话与只有模式开关的快照不构成任务。
    if (userAt == null || prompt is! String || prompt.trim().isEmpty) {
      return null;
    }
    final valid = _usableSnapshot(snapshot);
    final generation = _nonNegativeInt(snapshot['generation']) ?? 0;
    final rawStatus =
        snapshot['status'] is String ? snapshot['status'] as String : 'idle';
    final status = busy
        ? live!.queued
            ? 'queued'
            : 'running'
        : rawStatus == 'running'
            ? 'paused'
            : const ['paused', 'complete', 'idle'].contains(rawStatus)
                ? rawStatus
                : 'paused';
    ConversationModel? conversation;
    if (tables.contains('tb_conversation_list')) {
      final parents = await txn.query('tb_conversation_list',
          where: 'cid=?', whereArgs: [cid], limit: 1);
      if (parents.isNotEmpty) {
        try {
          final data = Map<String, dynamic>.from(parents.single);
          data['cid'] = cid;
          data['id'] = _nonNegativeInt(data['id']);
          data['icon'] = data['icon'] is String ? data['icon'] : '🤖';
          for (final key in ['title', 'lastMessage']) {
            if (data[key] is! String) data[key] = null;
          }
          data['updateAt'] = _nonNegativeInt(data['updateAt']);
          data['stickTime'] = _nonNegativeInt(data['stickTime']) ?? 0;
          data['messageCount'] = _nonNegativeInt(data['messageCount']);
          conversation = ConversationModel.fromJson(data);
        } catch (_) {}
      }
    }
    int? latestUserAt;
    if (tables.contains('tb_messages')) {
      final users = await txn.rawQuery(
          'SELECT MAX(createdAt) AS latest FROM tb_messages '
          'WHERE cid=? AND ownerType=?',
          [cid, 'OwnerType.sender']);
      if (users.isNotEmpty) latestUserAt = _positiveInt(users.single['latest']);
    }
    final enabled = snapshot['enabled'] == true;
    final canResume = !busy &&
        valid &&
        enabled &&
        conversation != null &&
        latestUserAt == userAt &&
        const ['paused', 'running'].contains(rawStatus);
    String? reason = snapshot['pauseReason'] is String
        ? snapshot['pauseReason'] as String
        : null;
    if (!valid) {
      reason = '任务快照格式无效，无法继续';
    } else if (conversation == null) {
      reason = '原对话已不存在或无法读取';
    } else if (latestUserAt != userAt) {
      reason = '任务消息已被删除或已有新的用户输入';
    } else if (!enabled) {
      reason = '此对话已关闭任务模式';
    } else if (!busy && rawStatus == 'running') {
      reason ??= '应用中断，可从已保存的进度继续';
    }
    final tools = _toolMetadata(snapshot['messages'],
        executingId: snapshot['executingToolId'] is String
            ? snapshot['executingToolId'] as String
            : null,
        awaitingApproval: busy && live!.awaitingApproval);
    final outputs = <AgentTaskOutputReference>[];
    if (tables.contains('tb_agent_verification_turn')) {
      final turns = await txn.query('tb_agent_verification_turn',
          columns: ['snapshot'],
          where: 'cid=? AND userCreatedAt=?',
          whereArgs: [cid, userAt],
          limit: 1);
      final recorded =
          turns.isEmpty ? null : _jsonMap(turns.single['snapshot'])?['outputs'];
      if (recorded is Map) {
        for (final entry in recorded.entries) {
          final fileId = int.tryParse(entry.key.toString());
          final revision = _positiveInt(entry.value);
          if (fileId == null || fileId <= 0 || revision == null) continue;
          outputs.add(await _output(txn, tables, cid, fileId, revision,
              requireOutput: true));
        }
      }
    }
    AgentTaskVerificationReport? report;
    if (tables.contains('tb_agent_verification_report')) {
      final reports = await txn.query('tb_agent_verification_report',
          columns: ['report'],
          where: 'cid=? AND userCreatedAt=?',
          whereArgs: [cid, userAt],
          limit: 1);
      final data = reports.isEmpty ? null : _jsonMap(reports.single['report']);
      if (data != null &&
          data['cid'] == cid &&
          data['userCreatedAt'] == userAt) {
        try {
          report = AgentTaskVerificationReport.fromJson(data);
        } catch (_) {}
      }
    }
    var reportCurrent = report != null && latestUserAt == userAt;
    if (reportCurrent) {
      final versionedFiles = {
        for (final check in report.checks)
          if ((check.fileId ?? 0) > 0 && (check.revision ?? 0) > 0)
            check.fileId!
      };
      for (final check in report.checks) {
        if (check.fileId == null) continue;
        // 预期输出项可不重复存版本，但同文件必须有另一项真实版本证据。
        // 旧/损坏报告只有文件 id 时，不可假定它验收了当前正文。
        if (check.fileId! <= 0 ||
            (check.revision == null &&
                !versionedFiles.contains(check.fileId))) {
          reportCurrent = false;
          continue;
        }
        if (check.revision != null) {
          if (check.revision! <= 0) {
            reportCurrent = false;
            continue;
          }
          final source =
              await _output(txn, tables, cid, check.fileId!, check.revision!);
          if (!source.isCurrent) reportCurrent = false;
        }
      }
      if (outputs.any((output) => !output.isCurrent)) reportCurrent = false;
    }
    return AgentTaskDetail(
        cid: cid,
        userCreatedAt: userAt,
        generation: generation,
        title: conversation?.title?.trim().isNotEmpty == true
            ? conversation!.title!
            : 'Agent 任务',
        prompt: prompt,
        status: status,
        enabled: enabled,
        backgroundEnabled: snapshot['backgroundEnabled'] != false,
        nextRound: _nonNegativeInt(snapshot['nextRound']) ?? 0,
        todos: [
          for (final raw in (snapshot['todos'] is List
              ? snapshot['todos'] as List
              : const []))
            if (raw is Map &&
                raw['content'] is String &&
                const ['pending', 'in_progress', 'completed']
                    .contains(raw['status']))
              AgentTodo(raw['content'] as String, raw['status'] as String)
        ],
        pauseReason: reason,
        hasConversation: conversation != null,
        canResume: canResume,
        snapshotValid: valid,
        interrupted: !busy && rawStatus == 'running',
        latestUserMatches: latestUserAt == userAt,
        queuePosition: busy && live!.queued ? executor!.queuePosition(key!) : 0,
        updatedAt: _nonNegativeInt(rows.single['updatedAt']) ?? 0,
        pairedToolResultCount: tools.resultCount,
        pairedTools: tools.paired,
        pendingApproval: tools.pendingApproval,
        uncertainTools: tools.uncertain,
        verificationReport: report,
        verificationIsCurrent: reportCurrent,
        outputs: outputs,
        failureDiagnosis:
            ChatFailureDiagnosis.fromJson(snapshot['failureDiagnosis']),
        conversation: conversation);
  }

  static Future<AgentTaskOutputReference> _output(
      Transaction txn, Set<Object?> tables, int cid, int fileId, int revision,
      {bool requireOutput = false}) async {
    Map<String, Object?>? file;
    if (tables.contains('tb_agent_workspace_files')) {
      final rows = await txn.query('tb_agent_workspace_files',
          columns: ['name', 'kind', 'currentRevision'],
          where: 'id=? AND cid=?',
          whereArgs: [fileId, cid],
          limit: 1);
      if (rows.isNotEmpty) file = rows.single;
    }
    var available = false;
    if (file != null &&
        (!requireOutput || file['kind'] == 'output') &&
        tables.contains('tb_agent_workspace_revisions')) {
      available = (await txn.query('tb_agent_workspace_revisions',
              columns: ['revision'],
              where: 'fileId=? AND revision=?',
              whereArgs: [fileId, revision],
              limit: 1))
          .isNotEmpty;
    }
    return AgentTaskOutputReference(
        fileId: fileId,
        name: file?['name'] is String ? file!['name'] as String : '文件 $fileId',
        revision: revision,
        currentRevision: _positiveInt(file?['currentRevision']),
        available: available);
  }

  static Map<String, dynamic>? _jsonMap(Object? raw) {
    try {
      final value = raw is String ? jsonDecode(raw) : raw;
      return value is Map && value.keys.every((key) => key is String)
          ? Map<String, dynamic>.from(value)
          : null;
    } catch (_) {
      return null;
    }
  }

  static int? _positiveInt(Object? value) =>
      value is int && value > 0 ? value : null;
  static int? _nonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;

  static bool _usableSnapshot(Map<String, dynamic> data) {
    if (data['version'] != null && data['version'] != 1) return false;
    for (final key in ['enabled', 'needsContinuation', 'backgroundEnabled']) {
      if (data[key] != null && data[key] is! bool) return false;
    }
    for (final key in ['generation', 'nextRound']) {
      if (data[key] != null && _nonNegativeInt(data[key]) == null) return false;
    }
    if (!const ['idle', 'paused', 'running', 'complete']
        .contains(data['status'] ?? 'idle')) {
      return false;
    }
    for (final key in ['pauseReason', 'executingToolId']) {
      if (data[key] != null && data[key] is! String) return false;
    }
    if (data['todos'] != null && data['todos'] is! List) return false;
    if ((data['todos'] as List? ?? const []).length > 20) return false;
    for (final todo in (data['todos'] as List? ?? const [])) {
      if (todo is! Map ||
          todo['content'] is! String ||
          (todo['content'] as String).trim().isEmpty ||
          !const ['pending', 'in_progress', 'completed']
              .contains(todo['status'])) {
        return false;
      }
    }
    if (data['messages'] != null && data['messages'] is! List) return false;
    for (final message in (data['messages'] as List? ?? const [])) {
      if (message is! Map ||
          !const ['system', 'assistant', 'tool', 'user']
              .contains(message['role'])) {
        return false;
      }
      for (final key in ['content', 'reasoning_content', 'tool_call_id']) {
        if (message[key] != null && message[key] is! String) return false;
      }
      if (message['tool_calls'] != null) {
        if (message['tool_calls'] is! List) return false;
        for (final call in message['tool_calls'] as List) {
          if (call is! Map ||
              call['id'] is! String ||
              call['function'] is! Map ||
              call['function']['name'] is! String ||
              call['function']['arguments'] is! String) {
            return false;
          }
          if (_jsonMap(call['function']['arguments']) == null) return false;
        }
      }
    }
    return true;
  }
}

class _TaskToolMetadata {
  final int resultCount;
  final AgentTaskToolReference? pendingApproval;
  final List<AgentTaskToolReference> uncertain;
  final List<AgentTaskToolReference> paired;
  const _TaskToolMetadata(
      this.resultCount, this.pendingApproval, this.uncertain, this.paired);
}

_TaskToolMetadata _toolMetadata(Object? raw,
    {required String? executingId, required bool awaitingApproval}) {
  final declarations = <String, AgentTaskToolReference>{};
  final results = <String>{};
  final unknownResults = <String>{};
  // 与 ToolLoopRunner 的安全中断占位结果一致，只用于识别结果不明。
  const unknownResult = '此工具在中断前可能已执行，结果未保存。请用户核对；禁止自动重复此操作。';
  for (final message in (raw is List ? raw : const [])) {
    if (message is! Map) continue;
    if (message['role'] == 'assistant' && message['tool_calls'] is List) {
      for (final call in message['tool_calls'] as List) {
        if (call is! Map || call['function'] is! Map) continue;
        final id = call['id'], name = call['function']['name'];
        if (id is String &&
            id.isNotEmpty &&
            id.length <= 256 &&
            name is String &&
            RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,179}$').hasMatch(name)) {
          declarations[id] = AgentTaskToolReference(toolId: id, name: name);
        }
      }
    } else if (message['role'] == 'tool' &&
        message['tool_call_id'] is String &&
        message['content'] is String) {
      final id = message['tool_call_id'] as String;
      if (message['content'] == unknownResult) {
        unknownResults.add(id);
      } else {
        results.add(id);
      }
    }
  }
  final pending = awaitingApproval ? declarations[executingId] : null;
  final unknown = <String>{...unknownResults};
  if (!awaitingApproval &&
      executingId != null &&
      !results.contains(executingId)) {
    unknown.add(executingId);
  }
  final paired = [
    for (final id in results)
      if (declarations.containsKey(id) && !unknown.contains(id))
        declarations[id]!
  ];
  return _TaskToolMetadata(
      paired.length,
      pending,
      [
        for (final id in unknown)
          if (declarations[id] != null) declarations[id]!
      ],
      paired);
}
