import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/agent_verification_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:sqflite/sqflite.dart';

abstract class IAgentWorkflowStore {
  Future<AgentWorkflow?> read(String parentId);
  Future<List<WorkflowStep>> steps(String parentId);
}

/// 本机派生执行记录；不包含设置/凭据，不进入备份或游客迁移。
class AgentWorkflowDao implements IAgentWorkflowStore, ITable {
  static const workflows = 'tb_agent_workflow';
  static const stepTable = 'tb_agent_workflow_step';
  static const attempts = 'tb_agent_workflow_attempt';
  static const publications = 'tb_agent_workflow_publication';
  static const outputPublications = 'tb_agent_workflow_output';
  static const readOnlyTools = {'list_files', 'read_file', 'file_search'};
  final HiDBManager storage;
  final String accountHash;
  final int Function() now;
  final void Function()? _executionGuard;
  final void Function(WorkflowModelProfile)? _profileGuard;
  @override
  String tableName = workflows;
  AgentWorkflowDao._(this.storage, this.accountHash, this.now,
      [this._executionGuard, this._profileGuard]);

  /// 每个原运行单独的句柄，不修改共享 DAO 或账号全局状态。
  AgentWorkflowDao forExecution(
          {required void Function() guard,
          void Function(WorkflowModelProfile)? verifyProfile}) =>
      AgentWorkflowDao._(storage, accountHash, now, guard, verifyProfile);
  static Future<AgentWorkflowDao> create(HiDBManager storage,
      {required String accountHash, int Function()? now}) async {
    if (accountHash.trim().isEmpty) {
      throw ArgumentError('必须指定账号');
    }
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $workflows (
      parentId TEXT PRIMARY KEY, schemaVersion INTEGER NOT NULL,
      cid INTEGER NOT NULL, conversationRowId INTEGER NOT NULL,
      sourceRowId INTEGER NOT NULL, sourceId TEXT NOT NULL, sourceHash TEXT NOT NULL,
      conversationHash TEXT NOT NULL, task TEXT NOT NULL, inputs TEXT NOT NULL,
      state TEXT NOT NULL, reason TEXT, revision INTEGER NOT NULL,
      leaseId TEXT, publicationId TEXT NOT NULL UNIQUE,
      maxDispatches INTEGER NOT NULL, estimatedTokenLimit INTEGER NOT NULL,
      durationMs INTEGER NOT NULL, dispatches INTEGER NOT NULL DEFAULT 0,
      reservedTokens INTEGER NOT NULL DEFAULT 0, actualInputTokens INTEGER NOT NULL DEFAULT 0,
      actualOutputTokens INTEGER NOT NULL DEFAULT 0, usageUnknown INTEGER NOT NULL DEFAULT 0,
      estimatedCost REAL, costUnknown INTEGER NOT NULL DEFAULT 0,
      deadlineAt INTEGER, reworks INTEGER NOT NULL DEFAULT 0,
      activeStepId TEXT, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL
    )''');
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $stepTable (
      stepId TEXT PRIMARY KEY, parentId TEXT NOT NULL, ordinal INTEGER NOT NULL,
      role TEXT NOT NULL, profile TEXT NOT NULL, tools TEXT NOT NULL,
      state TEXT NOT NULL, revision INTEGER NOT NULL, result TEXT NOT NULL DEFAULT '',
      resultHash TEXT, inputHash TEXT, checkpoint TEXT, toolRounds INTEGER NOT NULL DEFAULT 0,
      cycles INTEGER NOT NULL DEFAULT 0, UNIQUE(parentId,ordinal)
    )''');
    for (final definition in [
      "acceptanceJson TEXT NOT NULL DEFAULT '{}'",
      'verificationJson TEXT',
      'backgroundEnabled INTEGER NOT NULL DEFAULT 0'
    ]) {
      try {
        await storage.db
            .execute('ALTER TABLE $workflows ADD COLUMN $definition');
      } on DatabaseException catch (error) {
        if (!error.toString().contains('duplicate column')) rethrow;
      }
    }
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $attempts (
      attemptId TEXT PRIMARY KEY, parentId TEXT NOT NULL, stepId TEXT NOT NULL,
      leaseId TEXT NOT NULL, state TEXT NOT NULL, inputHash TEXT NOT NULL,
      estimatedInput INTEGER NOT NULL, reservedOutput INTEGER NOT NULL,
      promptTokens INTEGER, completionTokens INTEGER, estimatedCost REAL,
      reason TEXT, result TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, endedAt INTEGER
    )''');
    try {
      await storage.db.execute(
          "ALTER TABLE $attempts ADD COLUMN result TEXT NOT NULL DEFAULT ''");
    } on DatabaseException catch (error) {
      if (!error.toString().contains('duplicate column')) rethrow;
    }
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $publications (
      parentId TEXT PRIMARY KEY, publicationId TEXT UNIQUE NOT NULL,
      messageRowId INTEGER NOT NULL, resultHash TEXT NOT NULL
    )''');
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS $outputPublications (
      parentId TEXT PRIMARY KEY, publicationId TEXT UNIQUE NOT NULL, fileId INTEGER NOT NULL,
      revision INTEGER NOT NULL, contentHash TEXT NOT NULL, name TEXT NOT NULL
    )''');
    await storage.db
        .execute('''CREATE TRIGGER IF NOT EXISTS agent_workflow_output_delete
      AFTER DELETE ON $workflows BEGIN DELETE FROM $outputPublications WHERE parentId=OLD.parentId; END''');
    await storage.db.execute(
        'CREATE INDEX IF NOT EXISTS agent_workflow_cid_idx ON $workflows(cid,createdAt DESC)');
    await storage.db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS agent_workflow_active_cid_idx ON $workflows(cid) WHERE state NOT IN ('complete','failed','cancelled')");
    // 由真实源表删除触发，覆盖清空/批删/恢复事务，不依赖某个页面。
    await storage.db
        .execute('''CREATE TRIGGER IF NOT EXISTS agent_workflow_children_delete
      AFTER DELETE ON $workflows BEGIN
        DELETE FROM $stepTable WHERE parentId=OLD.parentId;
        DELETE FROM $attempts WHERE parentId=OLD.parentId;
        DELETE FROM $publications WHERE parentId=OLD.parentId;
      END''');
    await storage.db
        .execute('''CREATE TRIGGER IF NOT EXISTS agent_workflow_source_delete
      AFTER DELETE ON tb_messages BEGIN
        DELETE FROM $workflows WHERE sourceRowId=OLD.id AND cid=OLD.cid;
      END''');
    await storage.db.execute(
        '''CREATE TRIGGER IF NOT EXISTS agent_workflow_conversation_delete
      AFTER DELETE ON tb_conversation_list BEGIN
        DELETE FROM $workflows WHERE conversationRowId=OLD.id AND cid=OLD.cid;
      END''');
    return AgentWorkflowDao._(storage, accountHash,
        now ?? () => DateTime.now().millisecondsSinceEpoch);
  }

  Future<T> _transaction<T>(
      AgentWorkflowScope scope, Future<T> Function(Transaction tx) action,
      {void Function()? finalGuard}) {
    if (scope.accountHash != accountHash) {
      throw const WorkflowStale('任务数据库账号不匹配');
    }
    return scope.stable(() async {
      _executionGuard?.call();
      final result = await storage.db.transaction((tx) async {
        scope.verify();
        _executionGuard?.call();
        final value = await action(tx);
        scope.verify();
        _executionGuard?.call();
        finalGuard?.call();
        return value;
      });
      // 同一原守卫也贯穿事务 Future 返回；这里不能撤回已完成的 COMMIT。
      _executionGuard?.call();
      finalGuard?.call();
      return result;
    });
  }

  static String _conversationHash(Map<String, Object?> row) =>
      workflowHash(jsonEncode({
        for (final key in const [
          'id',
          'cid',
          'assistantId',
          'toolIds',
          'modelProviderId',
          'modelId',
          'roleScene',
          'roleRelationship',
          'roleToneNote'
        ])
          key: row[key],
      }));
  @override
  Future<AgentWorkflow?> read(String parentId) async {
    final rows = await storage.db
        .query(workflows, where: 'parentId=?', whereArgs: [parentId]);
    return rows.isEmpty ? null : AgentWorkflow(rows.single);
  }

  Future<List<AgentWorkflow>> list(int? cid,
      {int limit = 50, int offset = 0}) async {
    if (limit < 1 || limit > 100 || offset < 0) {
      throw ArgumentError('分页范围无效');
    }
    return (await storage.db.query(workflows,
            where: cid == null ? null : 'cid=?',
            whereArgs: cid == null ? null : [cid],
            orderBy: 'createdAt DESC,parentId',
            limit: limit,
            offset: offset))
        .map(AgentWorkflow.new)
        .toList();
  }

  @override
  Future<List<WorkflowStep>> steps(String parentId) async =>
      (await storage.db.query(stepTable,
              where: 'parentId=?', whereArgs: [parentId], orderBy: 'ordinal'))
          .map(WorkflowStep.new)
          .toList();
  Future<List<Map<String, Object?>>> attemptHistory(String parentId) =>
      storage.db.query(attempts,
          where: 'parentId=?',
          whereArgs: [parentId],
          orderBy: 'createdAt,attemptId');

  /// 只接受尚未开始的整个父任务；不能逐步绑定后先发出一部分。
  static bool unstartedForBackendBinding(
      AgentWorkflow parent, List<WorkflowStep> steps) {
    final row = parent.toRow();
    return row['state'] == 'queued' &&
        row['leaseId'] == null &&
        row['deadlineAt'] == null &&
        row['activeStepId'] == null &&
        row['verificationJson'] == null &&
        row['reason'] == null &&
        [
          'dispatches',
          'reservedTokens',
          'actualInputTokens',
          'actualOutputTokens',
          'usageUnknown',
          'costUnknown',
          'reworks'
        ].every((key) => row[key] == 0) &&
        row['estimatedCost'] == null &&
        steps.length == 3 &&
        steps.map((s) => s.role).toSet().containsAll(WorkflowRole.values) &&
        steps.every((step) {
          final s = step.toRow();
          return s['state'] == 'queued' &&
              s['inputHash'] == null &&
              s['checkpoint'] == null &&
              s['resultHash'] == null &&
              s['result'] == '' &&
              s['toolRounds'] == 0 &&
              s['cycles'] == 0;
        });
  }

  Future<AgentWorkflow> bindLegacyBackendProfiles(
    BackendSelectionBindingScope scope, {
    required AgentWorkflow expected,
    required List<WorkflowStep> expectedSteps,
    required Map<String, BackendSelection> resolved,
  }) {
    if (scope.accountHash != accountHash) throw const WorkflowStale();
    final originalSteps = List<WorkflowStep>.unmodifiable(expectedSteps);
    final pairs = Map<String, BackendSelection>.unmodifiable(resolved);
    return scope.stable(() => storage.db.transaction((tx) async {
          scope.verify();
          final parents = await tx
              .query(workflows, where: 'parentId=?', whereArgs: [expected.id]);
          final rows = await tx.query(stepTable,
              where: 'parentId=?',
              whereArgs: [expected.id],
              orderBy: 'ordinal');
          if (parents.length != 1 ||
              !mapEquals(parents.single, expected.toRow()) ||
              rows.length != originalSteps.length ||
              !unstartedForBackendBinding(AgentWorkflow(parents.single),
                  rows.map(WorkflowStep.new).toList())) {
            throw const WorkflowStale('任务已有执行证据或原快照已变化，不能重新绑定');
          }
          for (var i = 0; i < rows.length; i++) {
            if (!mapEquals(rows[i], originalSteps[i].toRow())) {
              throw const WorkflowStale();
            }
          }
          for (final table in [attempts, publications, outputPublications]) {
            if ((await tx.query(table,
                    where: 'parentId=?', whereArgs: [expected.id], limit: 1))
                .isNotEmpty) {
              throw const WorkflowStale('任务已有请求或发布历史，不能重新绑定');
            }
          }
          await _sourceValid(tx, parents.single);
          final required = <String>{};
          for (final step in rows.map(WorkflowStep.new)) {
            final profile = step.profile;
            if (profile.mode != 'backend') continue;
            if (profile.backendSelection != null) {
              scope.verifyPair(profile.backendSelection!, profile.modelId);
            } else {
              if (profile.providerId != 'backend') {
                throw const WorkflowStale('旧后端配置不是可识别哨兵');
              }
              required.add(step.id);
              final selection = pairs[step.id];
              if (selection == null) throw const WorkflowStale('必须一次绑定全部旧后端节点');
              scope.verifyPair(selection, profile.modelId);
            }
          }
          if (required.isEmpty || !setEquals(required, pairs.keys.toSet())) {
            throw const WorkflowStale();
          }
          for (final row in rows) {
            final selection = pairs[row['stepId']];
            if (selection == null) continue;
            final changed = await tx.update(
                stepTable,
                {
                  'profile': jsonEncode(
                      WorkflowModelProfile.backend(selection).toJson()),
                  'revision': (row['revision'] as int) + 1,
                },
                where: 'stepId=? AND revision=? AND profile=?',
                whereArgs: [row['stepId'], row['revision'], row['profile']]);
            if (changed != 1) throw const WorkflowStale();
          }
          final old = parents.single;
          final timestamp = now();
          final stamp = timestamp > (old['updatedAt'] as int)
              ? timestamp
              : (old['updatedAt'] as int) + 1;
          final revision = (old['revision'] as int) + 1;
          final changed = await tx.update(
              workflows, {'updatedAt': stamp, 'revision': revision},
              where: 'parentId=? AND revision=?',
              whereArgs: [expected.id, expected.revision]);
          if (changed != 1) throw const WorkflowStale();
          final finalRows = await tx
              .query(workflows, where: 'parentId=?', whereArgs: [expected.id]);
          scope.verify();
          return AgentWorkflow(finalRows.single);
        }));
  }

  Future<AgentWorkflow> createFromSource(AgentWorkflowScope scope,
          {required int cid,
          int? userRowId,
          String? newTask,
          int? newUserCreatedAt,
          ConversationModel? conversationIfMissing,
          String? expectedConversationFingerprint,
          AgentWorkflow? confirmedOriginal,
          List<WorkflowStep>? confirmedSteps,
          bool endConfirmedOriginal = false,
          required Map<WorkflowRole, WorkflowModelProfile> profiles,
          List<int> inputFileIds = const [],
          List<WorkflowInputRef>? expectedInputs,
          Set<String> grantedTools = const {},
          TaskAcceptanceCriteria acceptance = const TaskAcceptanceCriteria(),
          bool? canReadInputs,
          bool backgroundEnabled = false,
          WorkflowBudget budget = const WorkflowBudget()}) =>
      _transaction(scope, (tx) async {
        if (confirmedOriginal != null) {
          final old = await tx.query(workflows,
              where: 'parentId=?', whereArgs: [confirmedOriginal.id]);
          final steps = await tx.query(stepTable,
              where: 'parentId=?',
              whereArgs: [confirmedOriginal.id],
              orderBy: 'ordinal');
          if (old.length != 1 ||
              jsonEncode(old.single) != jsonEncode(confirmedOriginal.toRow()) ||
              confirmedSteps == null ||
              jsonEncode(steps) !=
                  jsonEncode(confirmedSteps.map((s) => s.toRow()).toList())) {
            throw const WorkflowStale('原任务已变化，请重新确认');
          }
          await _sourceValid(tx, old.single);
          // 只有弹窗明确同意结束旧协作的入口才能释放每会话唯一活动槽。
          // 新父任务插入失败时同事务回滚；未知attempt、节点结果和预算不修改。
          if (endConfirmedOriginal &&
              !const ['complete', 'failed', 'cancelled']
                  .contains(old.single['state'])) {
            if (!const ['paused', 'needsConfiguration', 'budgetExhausted']
                .contains(old.single['state'])) {
              throw const WorkflowStale('原协作仍在运行，请先停止并重新确认');
            }
            await _update(tx, old.single, {
              'state': 'cancelled',
              'reason': '${old.single['reason'] ?? ''}；用户明确结束原协作并新建请求',
              'leaseId': null,
              'activeStepId': null,
            });
          }
        }
        budget.validate();
        validateAcceptance(acceptance,
            inputCount: inputFileIds.length,
            canReadInputs: grantedTools.contains('read_file') &&
                (canReadInputs ??
                    profiles.values.any((p) => ModelCatalog.capabilitiesFor(
                            p.modelId,
                            providerCode: p.providerId)
                        .tool)));
        if ((userRowId == null) == (newTask == null) ||
            (newTask != null &&
                (newTask.trim().isEmpty ||
                    newTask.length > 12000 ||
                    newUserCreatedAt == null ||
                    newUserCreatedAt <= 0))) {
          throw const FormatException('需要本次正文或已保存用户行，不能同时指定');
        }
        if (profiles.length != 3 ||
            !profiles.keys.toSet().containsAll(WorkflowRole.values) ||
            inputFileIds.length > 4 ||
            inputFileIds.toSet().length != inputFileIds.length ||
            !readOnlyTools.containsAll(grantedTools)) {
          throw const FormatException('协作职责或输入授权无效');
        }
        for (final p in profiles.values) {
          WorkflowModelProfile.fromJson(p.toJson());
        }
        final count = Sqflite.firstIntValue(
            await tx.rawQuery('SELECT COUNT(*) FROM $workflows'))!;
        if (count >= 1000) {
          throw const FormatException('本机任务记录最多1000项，请先删除旧任务');
        }
        var convo = await tx
            .query('tb_conversation_list', where: 'cid=?', whereArgs: [cid]);
        if (expectedConversationFingerprint != null &&
            expectedConversationFingerprint !=
                (convo.isEmpty ? 'missing' : _conversationHash(convo.single))) {
          throw const WorkflowStale('配置期间会话绑定已变化');
        }
        if (convo.isEmpty && conversationIfMissing != null) {
          if (conversationIfMissing.cid != cid ||
              conversationIfMissing.id != null) {
            throw const WorkflowStale();
          }
          final value = conversationIfMissing.toJson()..remove('id');
          value['title'] ??= newTask?.substring(0, newTask.length.clamp(0, 40));
          await tx.insert('tb_conversation_list', value);
          convo = await tx
              .query('tb_conversation_list', where: 'cid=?', whereArgs: [cid]);
        }
        if (newTask != null) {
          final last = Sqflite.firstIntValue(await tx.rawQuery(
                  'SELECT MAX(createdAt) FROM tb_messages WHERE cid=?',
                  [cid])) ??
              0;
          final createdAt =
              newUserCreatedAt! > last ? newUserCreatedAt : last + 1;
          userRowId = await tx.insert('tb_messages', {
            'cid': cid,
            'createdAt': createdAt,
            'ownerType': 'OwnerType.sender',
            'ownerName': '我',
            'content': newTask,
            'memorySourceId': generateUuidV4()
          });
        }
        final user = await tx.query('tb_messages',
            where: 'cid=? AND id=?', whereArgs: [cid, userRowId]);
        if (convo.length != 1 ||
            user.length != 1 ||
            user.single['ownerType'] != 'OwnerType.sender' ||
            user.single['memorySourceId'] is! String ||
            (user.single['memorySourceId'] as String).isEmpty ||
            user.single['content'] is! String ||
            (user.single['content'] as String).trim().isEmpty ||
            (user.single['content'] as String).length > 12000) {
          throw const WorkflowStale('需要已保存且有稳定身份的本次用户输入');
        }
        final inputs = <WorkflowInputRef>[];
        var total = 0;
        for (final id in inputFileIds) {
          final f = await tx.query('tb_agent_workspace_files',
              where: "cid=? AND id=? AND kind='input'", whereArgs: [cid, id]);
          if (f.length != 1) {
            throw const WorkflowStale('选中的输入文件不存在');
          }
          final v = await tx.query('tb_agent_workspace_revisions',
              where: 'fileId=? AND revision=?',
              whereArgs: [id, f.single['currentRevision']]);
          if (v.length != 1 || v.single['content'] is! String) {
            throw const WorkflowStale('输入版本不存在');
          }
          if (expectedInputs != null) {
            final expected =
                expectedInputs.where((input) => input.fileId == id).toList();
            if (expected.length != 1 ||
                expected.single.revision != f.single['currentRevision'] ||
                expected.single.fileHash != f.single['contentHash'] ||
                expected.single.textHash !=
                    workflowHash(v.single['content'] as String)) {
              throw const WorkflowStale('配置期间输入版本已变化，请重新选择');
            }
          }
          final text = v.single['content'] as String;
          total += text.length;
          if (total > 24000) {
            throw const FormatException('首期选中文本总量最多24000字符，请先缩小范围');
          }
          inputs.add(WorkflowInputRef(id, f.single['currentRevision'] as int,
              f.single['contentHash'] as String, workflowHash(text)));
        }
        final parent = generateUuidV4(), stamp = now();
        final row = <String, Object?>{
          'parentId': parent,
          'schemaVersion': 1,
          'acceptanceJson': jsonEncode(acceptance.toJson()),
          'verificationJson': null,
          'backgroundEnabled': backgroundEnabled ? 1 : 0,
          'cid': cid,
          'conversationRowId': convo.single['id'],
          'sourceRowId': userRowId,
          'sourceId': user.single['memorySourceId'],
          'sourceHash': workflowHash(user.single['content'] as String),
          'conversationHash': _conversationHash(convo.single),
          'task': user.single['content'],
          'inputs': jsonEncode(inputs.map((f) => f.toJson()).toList()),
          'state': 'queued',
          'reason': null,
          'revision': 1,
          'leaseId': null,
          'publicationId': generateUuidV4(),
          'maxDispatches': budget.maxDispatches,
          'estimatedTokenLimit': budget.estimatedTokens,
          'durationMs': budget.durationMs,
          'dispatches': 0,
          'reservedTokens': 0,
          'actualInputTokens': 0,
          'actualOutputTokens': 0,
          'usageUnknown': 0,
          'estimatedCost': null,
          'costUnknown': 0,
          'deadlineAt': null,
          'reworks': 0,
          'activeStepId': null,
          'createdAt': stamp,
          'updatedAt': stamp
        };
        await tx.insert(workflows, row);
        for (final role in WorkflowRole.values) {
          await tx.insert(stepTable, {
            'stepId': generateUuidV4(),
            'parentId': parent,
            'ordinal': role.index,
            'role': role.name,
            'profile': jsonEncode(profiles[role]!.toJson()),
            'tools': jsonEncode(grantedTools.toList()..sort()),
            'state': 'queued',
            'revision': 1,
            'result': '',
            'toolRounds': 0,
            'cycles': 0
          });
        }
        return AgentWorkflow(row);
      });

  Future<void> _sourceValid(DatabaseExecutor tx, Map<String, Object?> w) async {
    final c = await tx.query('tb_conversation_list',
        where: 'cid=? AND id=?', whereArgs: [w['cid'], w['conversationRowId']]);
    final u = await tx.query('tb_messages',
        where: 'cid=? AND id=? AND memorySourceId=?',
        whereArgs: [w['cid'], w['sourceRowId'], w['sourceId']]);
    if (c.length != 1 ||
        u.length != 1 ||
        u.single['ownerType'] != 'OwnerType.sender' ||
        _conversationHash(c.single) != w['conversationHash'] ||
        workflowHash(u.single['content'] as String) != w['sourceHash']) {
      throw const WorkflowStale();
    }
    for (final input in AgentWorkflow(w).inputs) {
      final f = await tx.query('tb_agent_workspace_files',
          where: "cid=? AND id=? AND kind='input'",
          whereArgs: [w['cid'], input.fileId]);
      final v = await tx.query('tb_agent_workspace_revisions',
          where: 'fileId=? AND revision=?',
          whereArgs: [input.fileId, input.revision]);
      if (f.length != 1 ||
          v.length != 1 ||
          f.single['currentRevision'] != input.revision ||
          f.single['contentHash'] != input.fileHash ||
          workflowHash(v.single['content'] as String) != input.textHash) {
        throw const WorkflowStale('输入已变化，需要重新确认');
      }
    }
  }

  Future<Map<String, Object?>> _require(
      DatabaseExecutor tx, WorkflowFence fence) async {
    final rows = await tx.query(workflows,
        where: 'parentId=? AND leaseId=? AND revision=? AND state=?',
        whereArgs: [fence.parentId, fence.leaseId, fence.revision, 'running']);
    if (rows.length != 1) {
      throw const WorkflowStale();
    }
    await _sourceValid(tx, rows.single);
    return rows.single;
  }

  Future<AgentWorkflow> _update(Transaction tx, Map<String, Object?> old,
      Map<String, Object?> changes) async {
    final next = {
      ...old,
      ...changes,
      'revision': (old['revision'] as int) + 1,
      'updatedAt': now()
    };
    final affected = await tx.update(workflows, next,
        where: 'parentId=? AND revision=?',
        whereArgs: [old['parentId'], old['revision']]);
    if (affected != 1) {
      throw const WorkflowStale();
    }
    return AgentWorkflow(next);
  }

  Future<AgentWorkflow> claim(
      AgentWorkflowScope scope, String parentId, int revision,
      {List<WorkflowStep>? expectedSteps}) {
    final snapshot = expectedSteps == null
        ? null
        : List<WorkflowStep>.unmodifiable(expectedSteps);
    final prepared = <WorkflowModelProfile>[];
    return _transaction(scope, (tx) async {
      final rows = await tx.query(workflows,
          where: 'parentId=? AND revision=?', whereArgs: [parentId, revision]);
      if (rows.length != 1 ||
          !const ['queued', 'paused', 'needsConfiguration']
              .contains(rows.single['state'])) {
        throw const WorkflowStale();
      }
      await _sourceValid(tx, rows.single);
      final unknown = await tx.query(attempts,
          where: "parentId=? AND state IN ('dispatched','unknown')",
          whereArgs: [parentId],
          limit: 1);
      if (unknown.isNotEmpty) {
        throw const WorkflowStale('上次请求结果不明，不能自动重放');
      }
      final steps = await tx.query(stepTable,
          where: 'parentId=?', whereArgs: [parentId], orderBy: 'ordinal');
      if (steps.any((s) => WorkflowStep(s).profile.backendSelection != null) &&
          (snapshot == null ||
              snapshot.length != steps.length ||
              steps.length != 3 ||
              !List.generate(steps.length,
                      (i) => mapEquals(steps[i], snapshot[i].toRow()))
                  .every((v) => v))) {
        throw const WorkflowStale('原父任务节点快照已变化');
      }
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        final profile = WorkflowStep(step).profile;
        if (profile.backendSelection != null) {
          if (_executionGuard == null ||
              _profileGuard == null ||
              snapshot == null ||
              snapshot.length != steps.length ||
              !mapEquals(step, snapshot[i].toRow())) {
            throw const WorkflowStale('原节点快照或后端准备许可已变化');
          }
          _profileGuard!(profile);
          prepared.add(profile);
        }
        final checkpoint = WorkflowStep(step).checkpoint;
        if (checkpoint?['executingToolId'] != null) {
          throw const WorkflowStale('上次工具结果未保存，禁止自动重复');
        }
      }
      return _update(tx, rows.single, {
        'state': 'running',
        'reason': null,
        'leaseId': generateUuidV4(),
        'deadlineAt': rows.single['deadlineAt'] ??
            now() + (rows.single['durationMs'] as int)
      });
    }, finalGuard: () {
      for (final p in prepared) {
        _profileGuard!(p);
      }
    });
  }

  Future<AgentWorkflow> beginStep(
          AgentWorkflowScope scope, WorkflowFence fence, String stepId,
          {required String inputHash,
          bool rework = false,
          bool repeatReview = false}) =>
      _transaction(scope, (tx) async {
        final w = await _require(tx, fence);
        final step = await tx.query(stepTable,
            where: 'parentId=? AND stepId=?',
            whereArgs: [fence.parentId, stepId]);
        if (step.length != 1 ||
            (step.single['state'] == 'complete' && !rework && !repeatReview) ||
            (rework &&
                (step.single['role'] != 'writing' ||
                    (w['reworks'] as int) >= 1)) ||
            (repeatReview &&
                (step.single['role'] != 'review' ||
                    w['reworks'] != 1 ||
                    step.single['cycles'] != 1)) ||
            (w['activeStepId'] != null && w['activeStepId'] != stepId)) {
          throw const WorkflowStale();
        }
        final previous = await tx.query(stepTable,
            where: "parentId=? AND ordinal<? AND state!='complete'",
            whereArgs: [fence.parentId, step.single['ordinal']],
            limit: 1);
        if (previous.isNotEmpty) {
          throw const WorkflowStale('前序节点尚未提交结果');
        }
        await tx.update(
            stepTable,
            {
              'state': 'running',
              'inputHash': inputHash,
              if (rework || repeatReview) 'checkpoint': null,
              if (rework || repeatReview) 'toolRounds': 0,
              'revision': (step.single['revision'] as int) + 1,
              'cycles': (step.single['cycles'] as int) +
                  ((step.single['cycles'] == 0 || rework || repeatReview)
                      ? 1
                      : 0)
            },
            where: 'stepId=?',
            whereArgs: [stepId]);
        return _update(tx, w, {
          'activeStepId': stepId,
          'reworks': (w['reworks'] as int) + (rework ? 1 : 0)
        });
      });
  Future<WorkflowReservation> reserveDispatch(
      AgentWorkflowScope scope, WorkflowFence fence, String stepId,
      {required String inputHash,
      required int estimatedInput,
      int outputTokens = WorkflowBudget.outputTokens,
      WorkflowModelProfile? expectedProfile}) {
    WorkflowModelProfile? prepared;
    return _transaction(scope, (tx) async {
      final w = await _require(tx, fence);
      if (w['activeStepId'] != stepId ||
          estimatedInput < 1 ||
          outputTokens < 1 ||
          outputTokens > WorkflowBudget.outputTokens) {
        throw const WorkflowStale();
      }
      final node = await tx.query(stepTable,
          where: 'parentId=? AND stepId=?',
          whereArgs: [fence.parentId, stepId]);
      if (node.length != 1) throw const WorkflowStale();
      final profile = WorkflowStep(node.single).profile;
      if (profile.backendSelection != null) {
        if (_executionGuard == null ||
            _profileGuard == null ||
            expectedProfile == null ||
            jsonEncode(profile.toJson()) !=
                jsonEncode(expectedProfile.toJson())) {
          throw const WorkflowStale('原节点模型或准备许可已变化');
        }
        _profileGuard!(profile);
        prepared = profile;
      }
      final pending = await tx.query(attempts,
          where: "parentId=? AND state='dispatched'",
          whereArgs: [fence.parentId],
          limit: 1);
      if (pending.isNotEmpty) {
        throw const WorkflowStale('上次请求尚未结束');
      }
      final exhausted =
          (w['dispatches'] as int) >= (w['maxDispatches'] as int) ||
              (w['reservedTokens'] as int) + estimatedInput + outputTokens >
                  (w['estimatedTokenLimit'] as int) ||
              now() >= (w['deadlineAt'] as int);
      if (exhausted) {
        await tx.rawUpdate(
            "UPDATE $stepTable SET state='paused',revision=revision+1 WHERE stepId=?",
            [stepId]);
        return WorkflowReservation(
            await _update(tx, w, {
              'state': 'budgetExhausted',
              'reason': '请求次数、累计估算Token或任务时限已到；需明确追加预算',
              'leaseId': null,
              'activeStepId': null
            }),
            null);
      }
      final id = generateUuidV4();
      await tx.insert(attempts, {
        'attemptId': id,
        'parentId': fence.parentId,
        'stepId': stepId,
        'leaseId': fence.leaseId,
        'state': 'dispatched',
        'inputHash': inputHash,
        'estimatedInput': estimatedInput,
        'reservedOutput': outputTokens,
        'createdAt': now()
      });
      final next = await _update(tx, w, {
        'dispatches': (w['dispatches'] as int) + 1,
        'reservedTokens':
            (w['reservedTokens'] as int) + estimatedInput + outputTokens
      });
      return WorkflowReservation(next, id);
    }, finalGuard: () {
      if (prepared != null) _profileGuard!(prepared!);
    });
  }

  Future<void> verifyCurrent(AgentWorkflowScope scope, WorkflowFence fence) =>
      _transaction(scope, (tx) async {
        await _require(tx, fence);
      });

  /// 调用者已经在同账号短事务中；不再嵌套事务或排第二次账号许可。
  Future<void> verifyTransaction(
      AgentWorkflowScope scope, WorkflowFence fence, Transaction tx) async {
    if (scope.accountHash != accountHash) throw const WorkflowStale();
    scope.verify();
    await _require(tx, fence);
    scope.verify();
  }

  Future<void> verifySnapshotTransaction(
      AgentWorkflowScope scope, AgentWorkflow snapshot, Transaction tx) async {
    scope.verify();
    if (scope.accountHash != accountHash) throw const WorkflowStale();
    final rows = await tx.query(workflows,
        where: 'parentId=? AND revision=?',
        whereArgs: [snapshot.id, snapshot.revision]);
    if (rows.length != 1 ||
        rows.single['sourceId'] != snapshot.toRow()['sourceId']) {
      throw const WorkflowStale();
    }
    await _sourceValid(tx, rows.single);
    scope.verify();
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: _canonical(value[k])};
    }
    return value is List ? value.map(_canonical).toList() : value;
  }

  Future<void> _checkVerification(Transaction tx, Map<String, Object?> w,
      AgentTaskVerificationReport report) async {
    final source = (await tx.query('tb_messages',
            where: 'id=? AND cid=?', whereArgs: [w['sourceRowId'], w['cid']]))
        .single;
    final binding = report.verifiedSnapshot;
    if (report.cid != w['cid'] ||
        report.userCreatedAt != source['createdAt'] ||
        binding == null ||
        binding['version'] != 1 ||
        utf8.encode(jsonEncode(report.toJson())).length > 64 * 1024) {
      throw const WorkflowStale('验收来源或版本证据无效，请重新验收');
    }
    final turns = await tx.query('tb_agent_verification_turn',
        where: 'cid=? AND userCreatedAt=?',
        whereArgs: [w['cid'], source['createdAt']]);
    if (turns.length != 1) throw const WorkflowStale('验收轮次已变化');
    final turn = jsonDecode(turns.single['snapshot'] as String) as Map;
    for (final k in ['inputIds', 'outputs', 'criteria']) {
      if (jsonEncode(_canonical(turn[k])) !=
          jsonEncode(_canonical(binding[k]))) {
        throw const WorkflowStale('验收条件或确认的输出版本已变化，请重新验收');
      }
    }
    if (jsonEncode(_canonical(binding['criteria'])) !=
        jsonEncode(_canonical(AgentWorkflow(w).acceptance))) {
      throw const WorkflowStale('验收条件不属于本任务');
    }
    final files = (binding['files'] as List).cast<Map>();
    if (files.length > 20 ||
        files.map((f) => f['id']).toSet().length != files.length) {
      throw const WorkflowStale('验收文件证据无效');
    }
    for (final f in files) {
      final rows = await tx.query(AgentWorkspaceDao.filesTable,
          where:
              "id=? AND cid=? AND kind='output' AND name=? AND currentRevision=? AND contentHash=?",
          whereArgs: [
            f['id'],
            w['cid'],
            f['name'],
            f['revision'],
            f['contentHash']
          ]);
      final versions = await tx.query(AgentWorkspaceDao.revisionsTable,
          where: 'fileId=? AND revision=?',
          whereArgs: [f['id'], f['revision']]);
      if (rows.length != 1 ||
          versions.length != 1 ||
          f['kind'] != 'output' ||
          workflowHash(versions.single['content'] as String) != f['textHash']) {
        throw const WorkflowStale('验收读取的成果已修改或删除，请重新验收');
      }
    }
    if (report.isPassed) {
      final outputs = binding['outputs'] as Map;
      final criteria =
          TaskAcceptanceCriteria.fromJson(AgentWorkflow(w).acceptance);
      if (outputs.keys.any((id) => !files.any(
              (f) => '${f['id']}' == id && f['revision'] == outputs[id])) ||
          criteria.expectedOutputNames.any((name) => !files.any((f) =>
              f['name'] == name && outputs['${f['id']}'] == f['revision']))) {
        throw const WorkflowStale('缺少本轮确认的完整成果证据');
      }
    }
  }

  static void _requireVerification(Map<String, Object?> w) {
    final task = AgentWorkflow(w);
    final c = TaskAcceptanceCriteria.fromJson(task.acceptance);
    if (w['verificationJson'] == null &&
        (c.expectedOutputNames.isNotEmpty ||
            c.format != null ||
            c.minChars != null ||
            c.maxChars != null ||
            c.requiredTerms.isNotEmpty ||
            c.requireFullRead && task.inputs.isNotEmpty)) {
      throw const WorkflowStale('缺少本任务的客观验收证据');
    }
  }

  Future<List<String>> inputTexts(
          AgentWorkflowScope scope, WorkflowFence fence) =>
      _transaction(scope, (tx) async {
        final w = await _require(tx, fence);
        return [
          for (final f in AgentWorkflow(w).inputs)
            (await tx.query('tb_agent_workspace_revisions',
                    columns: ['content'],
                    where: 'fileId=? AND revision=?',
                    whereArgs: [f.fileId, f.revision]))
                .single['content'] as String
        ];
      });

  /// 协作首期仅能经前台确认发布一个文本成果，不能开始必定无法交付的任务。
  static void validateAcceptance(TaskAcceptanceCriteria criteria,
      {required int inputCount, required bool canReadInputs}) {
    criteria.validate();
    if (criteria.expectedOutputNames.length > 1 ||
        criteria.expectedOutputNames.any((n) =>
            !RegExp(r'^[^/\\\x00-\x1f]{1,200}\.(txt|md|csv)$',
                    caseSensitive: false)
                .hasMatch(n) ||
            n.trim() != n) ||
        criteria.format != null &&
            !const ['txt', 'md', 'csv'].contains(criteria.format) ||
        (criteria.minChars ?? 0) > WorkflowBudget.outputCharacters ||
        criteria.requireFullRead && inputCount > 0 && !canReadInputs) {
      throw const FormatException(
          '本次协作只支持一个TXT/MD/CSV成果；完整读取需所选模型支持read_file。请回工作区调整验收条件或模型。');
    }
  }

  /// 结果、步骤状态、attempt结束和父进度在同一个事务中落盘。
  Future<AgentWorkflow> finishAttempt(
          AgentWorkflowScope scope, WorkflowFence fence, String attemptId,
          {required WorkflowAttemptState state,
          String result = '',
          int? promptTokens,
          int? completionTokens,
          double? estimatedCost,
          String? reason,
          bool completesStep = true}) =>
      _transaction(scope, (tx) async {
        final w = await _require(tx, fence);
        final a = await tx.query(attempts,
            where:
                "attemptId=? AND parentId=? AND leaseId=? AND state='dispatched'",
            whereArgs: [attemptId, fence.parentId, fence.leaseId]);
        if (a.length != 1 ||
            a.single['stepId'] != w['activeStepId'] ||
            state == WorkflowAttemptState.dispatched ||
            result.length > WorkflowBudget.outputCharacters ||
            (promptTokens != null && promptTokens < 0) ||
            (completionTokens != null && completionTokens < 0) ||
            (estimatedCost != null &&
                (!estimatedCost.isFinite || estimatedCost < 0))) {
          throw const WorkflowStale();
        }
        await tx.update(
            attempts,
            {
              'state': state.name,
              'promptTokens': promptTokens,
              'completionTokens': completionTokens,
              'estimatedCost': estimatedCost,
              'reason': reason,
              'result': result,
              'endedAt': now()
            },
            where: 'attemptId=?',
            whereArgs: [attemptId]);
        final ok = state == WorkflowAttemptState.succeeded;
        final stepId = a.single['stepId'];
        final previousOutput = (await tx.query(attempts,
                columns: ['result'],
                where: 'stepId=? AND attemptId!=?',
                whereArgs: [stepId, attemptId]))
            .fold<int>(
                0, (n, row) => n + (row['result'] as String? ?? '').length);
        if (previousOutput + result.length > WorkflowBudget.outputCharacters) {
          throw const FormatException('节点累计输出超过12000字符');
        }
        if (ok && completesStep) {
          await tx.rawUpdate('''UPDATE $stepTable SET state='complete',
      result=?,resultHash=?,revision=revision+1 WHERE stepId=? AND parentId=?''',
              [result, workflowHash(result), stepId, fence.parentId]);
        }
        if (!ok) {
          final node = (await tx
                  .query(stepTable, where: 'stepId=?', whereArgs: [stepId]))
              .single;
          final checkpoint = WorkflowStep(node).checkpoint;
          if (state == WorkflowAttemptState.failed && checkpoint != null) {
            final messages = List<Map<String, dynamic>>.from(
                (checkpoint['messages'] as List)
                    .map((m) => (m as Map).cast<String, dynamic>()));
            if (messages.isNotEmpty &&
                messages.last['role'] == 'assistant' &&
                messages.last['tool_calls'] == null) {
              messages.removeLast();
              checkpoint['messages'] = messages;
              await tx.update(stepTable, {'checkpoint': jsonEncode(checkpoint)},
                  where: 'stepId=?', whereArgs: [stepId]);
            }
          }
          await tx.rawUpdate("""UPDATE $stepTable SET state='paused',
              result=?,resultHash=?,revision=revision+1 WHERE stepId=?""",
              [result, workflowHash(result), stepId]);
        }
        final unknown = promptTokens == null ||
            completionTokens == null ||
            state == WorkflowAttemptState.unknown;
        final costUnknown =
            w['costUnknown'] == 1 || estimatedCost == null || unknown;
        final excessKnownTokens =
            promptTokens == null || completionTokens == null
                ? 0
                : (promptTokens +
                        completionTokens -
                        (a.single['estimatedInput'] as int) -
                        (a.single['reservedOutput'] as int))
                    .clamp(0, 0x10000000000);
        return _update(tx, w, {
          'state': ok ? 'running' : 'paused',
          'reason': ok ? null : (reason ?? '请求未完成，需明确继续'),
          if (!ok) 'leaseId': null,
          if (!ok || completesStep) 'activeStepId': null,
          'actualInputTokens':
              (w['actualInputTokens'] as int) + (promptTokens ?? 0),
          'actualOutputTokens':
              (w['actualOutputTokens'] as int) + (completionTokens ?? 0),
          'usageUnknown': w['usageUnknown'] == 1 || unknown ? 1 : 0,
          'reservedTokens': (w['reservedTokens'] as int) + excessKnownTokens,
          'costUnknown': costUnknown ? 1 : 0,
          'estimatedCost': costUnknown
              ? null
              : (w['estimatedCost'] as num? ?? 0) + estimatedCost
        });
      });

  Future<AgentWorkflow> checkpoint(AgentWorkflowScope scope,
          WorkflowFence fence, String stepId, Map<String, dynamic> checkpoint,
          {required int toolRounds}) =>
      _transaction(scope, (tx) async {
        final w = await _require(tx, fence);
        _validateCheckpointTree(checkpoint);
        final encoded = jsonEncode(checkpoint);
        if (w['activeStepId'] != stepId ||
            utf8.encode(encoded).length > 128 * 1024 ||
            checkpoint['version'] != 1 ||
            toolRounds < 0 ||
            toolRounds > WorkflowBudget.toolRoundsPerStep) {
          throw const FormatException('节点断点或工具轮数超限');
        }
        if (checkpoint.keys.toSet().difference({
              'version',
              'messages',
              'nextRound',
              'executingToolId'
            }).isNotEmpty ||
            checkpoint['messages'] is! List ||
            (checkpoint['messages'] as List).length > 20 ||
            checkpoint['nextRound'] is! int ||
            checkpoint['nextRound'] < 0 ||
            checkpoint['nextRound'] > 2 ||
            (checkpoint['executingToolId'] != null &&
                (checkpoint['executingToolId'] is! String ||
                    (checkpoint['executingToolId'] as String).length > 200))) {
          throw const FormatException('节点断点字段无效');
        }
        for (final message in checkpoint['messages'] as List) {
          if (message is! Map ||
              message.keys.toSet().difference({
                'role',
                'content',
                'reasoning_content',
                'tool_calls',
                'tool_call_id',
                'name'
              }).isNotEmpty ||
              !const ['system', 'user', 'assistant', 'tool']
                  .contains(message['role']) ||
              (message['content'] != null && message['content'] is! String) ||
              (message['reasoning_content'] != null &&
                  message['reasoning_content'] is! String) ||
              (message['tool_call_id'] != null &&
                  message['tool_call_id'] is! String) ||
              (message['name'] != null &&
                  !readOnlyTools.contains(message['name']))) {
            throw const FormatException('节点断点只允许受控消息协议');
          }
          final calls = message['tool_calls'];
          if (calls == null) continue;
          if (calls is! List || calls.length > 4) {
            throw const FormatException('工具调用数量超限');
          }
          for (final call in calls) {
            if (call is! Map ||
                call.keys
                    .toSet()
                    .difference({'id', 'type', 'function'}).isNotEmpty ||
                call['id'] is! String ||
                call['type'] != 'function' ||
                call['function'] is! Map) {
              throw const FormatException('工具协议无效');
            }
            final function = call['function'] as Map;
            if (function.keys
                    .toSet()
                    .difference({'name', 'arguments'}).isNotEmpty ||
                !readOnlyTools.contains(function['name']) ||
                function['arguments'] is! String) {
              throw const FormatException('节点断点不包含未授权工具');
            }
          }
        }
        final old =
            (await tx.query(stepTable, where: 'stepId=?', whereArgs: [stepId]))
                .single;
        if (toolRounds < (old['toolRounds'] as int)) {
          throw const WorkflowStale('工具计数不能回退');
        }
        await tx.rawUpdate(
            'UPDATE $stepTable SET checkpoint=?,toolRounds=?,revision=revision+1 WHERE stepId=?',
            [encoded, toolRounds, stepId]);
        return _update(tx, w, {});
      });
  static void _validateCheckpointTree(Object? value) {
    var nodes = 0;
    void visit(Object? item, int depth) {
      if (++nodes > 2000 ||
          depth > 8 ||
          (item is String && item.length > 24000)) {
        throw const FormatException('节点断点结构超限');
      }
      if (item is Map) {
        for (final entry in item.entries) {
          if (entry.key is! String) throw const FormatException('节点断点键无效');
          visit(entry.key, depth + 1);
          visit(entry.value, depth + 1);
        }
      } else if (item is List) {
        for (final child in item) {
          visit(child, depth + 1);
        }
      } else if (item != null &&
          item is! String &&
          item is! bool &&
          item is! num) {
        throw const FormatException('节点断点类型无效');
      } else if (item is num && !item.isFinite) {
        throw const FormatException('节点断点数值无效');
      }
    }

    visit(value, 0);
  }

  Future<AgentWorkflow> complete(
          AgentWorkflowScope scope, WorkflowFence fence) =>
      _transaction(scope, (tx) async {
        final w = await _require(tx, fence);
        final unfinished = await tx.query(stepTable,
            where: "parentId=? AND state!='complete'",
            whereArgs: [fence.parentId],
            limit: 1);
        if (unfinished.isNotEmpty || w['activeStepId'] != null) {
          throw const WorkflowStale();
        }
        _requireVerification(w);
        if (w['verificationJson'] != null) {
          final report = AgentTaskVerificationReport.fromJson(
              jsonDecode(w['verificationJson'] as String));
          if (!report.isPassed) throw const WorkflowStale('客观验收尚未通过');
          await _checkVerification(tx, w, report);
        }
        return _update(
            tx, w, {'state': 'complete', 'reason': null, 'leaseId': null});
      });
  Future<int> sourceCreatedAt(AgentWorkflowScope scope, String parentId) =>
      _transaction(scope, (tx) async {
        final rows = await tx
            .query(workflows, where: 'parentId=?', whereArgs: [parentId]);
        if (rows.length != 1) throw const WorkflowStale();
        await _sourceValid(tx, rows.single);
        final source = await tx.query('tb_messages',
            where: 'id=? AND cid=?',
            whereArgs: [rows.single['sourceRowId'], rows.single['cid']]);
        return source.single['createdAt'] as int;
      });
  Future<String> captureConversation(AgentWorkflowScope scope, int cid) =>
      _transaction(scope, (tx) async {
        final rows = await tx
            .query('tb_conversation_list', where: 'cid=?', whereArgs: [cid]);
        return rows.isEmpty ? 'missing' : _conversationHash(rows.single);
      });
  Future<AgentWorkflow> recoverInterrupted(
      AgentWorkflowScope scope, AgentWorkflow snapshot) async {
    if (!const [WorkflowState.running, WorkflowState.queued]
        .contains(snapshot.state)) {
      return snapshot;
    }
    return stop(scope, snapshot.id, snapshot.revision,
        reason: '应用中断，已保存进度；明确继续才会再次请求模型');
  }

  Future<AgentWorkflow> saveVerification(AgentWorkflowScope scope,
          WorkflowFence fence, AgentTaskVerificationReport report) =>
      _transaction(scope, (tx) async {
        final w = await _require(tx, fence);
        await _checkVerification(tx, w, report);
        final source = await tx.query('tb_messages',
            where: 'id=? AND cid=?', whereArgs: [w['sourceRowId'], w['cid']]);
        final encoded = jsonEncode(report.toJson());
        if (report.cid != w['cid'] ||
            report.userCreatedAt != source.single['createdAt'] ||
            utf8.encode(encoded).length > 64 * 1024) {
          throw const FormatException('验收记录不属于本轮或超限');
        }
        return _update(tx, w, {'verificationJson': encoded});
      });
  Future<AgentWorkflow> stop(
          AgentWorkflowScope scope, String parentId, int revision,
          {WorkflowState state = WorkflowState.paused,
          String reason = '已停止，可明确继续'}) =>
      _transaction(scope, (tx) async {
        if (!const [
          WorkflowState.paused,
          WorkflowState.cancelled,
          WorkflowState.waitingConfirmation,
          WorkflowState.needsConfiguration,
          WorkflowState.failed
        ].contains(state)) {
          throw ArgumentError('停止状态无效');
        }
        final rows = await tx.query(workflows,
            where: 'parentId=? AND revision=?',
            whereArgs: [parentId, revision]);
        if (rows.length != 1 ||
            const ['complete', 'cancelled'].contains(rows.single['state'])) {
          throw const WorkflowStale();
        }
        // 已预留的网络执行不可确定是否被服务端接收，恢复时不自动重放。
        final interruptedAttempts = await tx.rawUpdate(
            "UPDATE $attempts SET state='unknown',reason=?,endedAt=? WHERE parentId=? AND state='dispatched'",
            [reason, now(), parentId]);
        await tx.rawUpdate(
            "UPDATE $stepTable SET state='paused',revision=revision+1 WHERE parentId=? AND state='running'",
            [parentId]);
        return _update(tx, rows.single, {
          'state': state.name,
          'reason': reason,
          'leaseId': null,
          'activeStepId': null,
          if (interruptedAttempts > 0) ...{
            'usageUnknown': 1,
            'costUnknown': 1,
            'estimatedCost': null
          }
        });
      });
  Future<AgentWorkflow> addBudget(
          AgentWorkflowScope scope, String parentId, int revision,
          {required int dispatches,
          required int estimatedTokens,
          required int milliseconds}) =>
      _transaction(scope, (tx) async {
        final rows = await tx.query(workflows,
            where: 'parentId=? AND revision=?',
            whereArgs: [parentId, revision]);
        if (rows.length != 1 ||
            !const ['budgetExhausted', 'paused']
                .contains(rows.single['state']) ||
            dispatches < 0 ||
            estimatedTokens < 0 ||
            milliseconds < 0 ||
            dispatches + estimatedTokens + milliseconds == 0) {
          throw const WorkflowStale();
        }
        final w = rows.single;
        WorkflowBudget(
                maxDispatches: (w['maxDispatches'] as int) + dispatches,
                estimatedTokens:
                    (w['estimatedTokenLimit'] as int) + estimatedTokens,
                durationMs: (w['durationMs'] as int) + milliseconds)
            .validate();
        await _sourceValid(tx, w);
        return _update(tx, w, {
          'state': 'paused',
          'reason': '已追加预算，请明确继续',
          'maxDispatches': (w['maxDispatches'] as int) + dispatches,
          'estimatedTokenLimit':
              (w['estimatedTokenLimit'] as int) + estimatedTokens,
          'durationMs': (w['durationMs'] as int) + milliseconds,
          'deadlineAt': w['deadlineAt'] == null
              ? null
              : milliseconds == 0
                  ? w['deadlineAt']
                  : ((w['deadlineAt'] as int) > now()
                          ? w['deadlineAt'] as int
                          : now()) +
                      milliseconds
        });
      });

  /// 最终文字发布只插入一次。输出工作区的副作用必须另走用户确认流程。
  /// 用户确认后单次发布一个文本成果；行、版本、验收来源与账本同事务。
  Future<int> publishOutputOnce(
      AgentWorkflowScope scope, AgentWorkflow snapshot,
      {required String name,
      int? expectedFileId,
      int? expectedRevision}) async {
    if (!RegExp(r'^[^/\\\x00-\x1f]{1,200}\.(txt|md|csv)$', caseSensitive: false)
            .hasMatch(name) ||
        name.trim() != name) {
      throw const FormatException('成果名只支持TXT/MD/CSV普通文件名');
    }
    scope.verify();
    final workspace =
        await AgentWorkspaceDao.create(storage, cid: snapshot.cid);
    await AgentVerificationDao.create(storage);
    scope.verify();
    return _transaction(scope, (tx) async {
      final rows = await tx.query(workflows,
          where: 'parentId=? AND revision=?',
          whereArgs: [snapshot.id, snapshot.revision]);
      if (rows.length != 1 ||
          !const ['complete', 'waitingConfirmation']
              .contains(rows.single['state'])) {
        throw const WorkflowStale();
      }
      final w = rows.single;
      await _sourceValid(tx, w);
      final prior = await tx.query(outputPublications,
          where: 'parentId=?', whereArgs: [snapshot.id]);
      if (prior.isNotEmpty) {
        final row = prior.single;
        final file = await tx.query(AgentWorkspaceDao.filesTable,
            where: 'id=? AND cid=? AND currentRevision=? AND contentHash=?',
            whereArgs: [
              row['fileId'],
              w['cid'],
              row['revision'],
              row['contentHash']
            ]);
        if (row['name'] != name || file.length != 1) {
          throw const WorkflowStale('已发布成果已变化，不自动再创建或覆盖');
        }
        return row['fileId'] as int;
      }
      final writer = (await tx.query(stepTable,
              where: "parentId=? AND role='writing' AND state='complete'",
              whereArgs: [snapshot.id]))
          .single;
      final targets = await tx.query(AgentWorkspaceDao.filesTable,
          where: "cid=? AND kind='output' AND name=?",
          whereArgs: [w['cid'], name]);
      if (targets.isEmpty
          ? expectedFileId != null
          : targets.single['id'] != expectedFileId ||
              targets.single['currentRevision'] != expectedRevision) {
        throw const WorkflowStale('成果目标已改变，请重新确认');
      }
      final content = writer['result'] as String;
      final file = await workspace.saveOutput(
          transaction: tx,
          fileId: expectedFileId,
          name: name,
          content: content,
          contentHash: workflowHash(content),
          sizeBytes: utf8.encode(content).length,
          note: '用户确认的协作成果',
          canCommit: () => scope.isCurrent);
      await tx.insert(outputPublications, {
        'parentId': snapshot.id,
        'publicationId': w['publicationId'],
        'fileId': file.id,
        'revision': file.revision,
        'contentHash': file.contentHash,
        'name': file.name
      });
      final source = (await tx.query('tb_messages',
              where: 'id=? AND cid=?', whereArgs: [w['sourceRowId'], w['cid']]))
          .single;
      final turn = await tx.query('tb_agent_verification_turn',
          where: 'cid=? AND userCreatedAt=?',
          whereArgs: [w['cid'], source['createdAt']]);
      final snapshotValue = turn.isEmpty
          ? <String, dynamic>{
              'inputIds': AgentWorkflow(w).inputs.map((f) => f.fileId).toList(),
              'criteria': AgentWorkflow(w).acceptance,
              'outputs': <String, dynamic>{}
            }
          : (jsonDecode(turn.single['snapshot'] as String) as Map)
              .cast<String, dynamic>();
      (snapshotValue['outputs'] as Map)[file.id.toString()] = file.revision;
      await tx.insert(
          'tb_agent_verification_turn',
          {
            'cid': w['cid'],
            'userCreatedAt': source['createdAt'],
            'snapshot': jsonEncode(snapshotValue)
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      return file.id;
    });
  }

  Future<AgentWorkflow> acceptVerification(AgentWorkflowScope scope,
          AgentWorkflow snapshot, AgentTaskVerificationReport report) =>
      _transaction(scope, (tx) async {
        final rows = await tx.query(workflows,
            where: 'parentId=? AND revision=?',
            whereArgs: [snapshot.id, snapshot.revision]);
        if (rows.length != 1 ||
            !const ['complete', 'waitingConfirmation']
                .contains(rows.single['state'])) {
          throw const WorkflowStale();
        }
        final w = rows.single;
        await _sourceValid(tx, w);
        final user = (await tx.query('tb_messages',
                where: 'id=? AND cid=?',
                whereArgs: [w['sourceRowId'], w['cid']]))
            .single;
        await _checkVerification(tx, w, report);
        if (report.cid != w['cid'] ||
            report.userCreatedAt != user['createdAt'] ||
            utf8.encode(jsonEncode(report.toJson())).length > 64 * 1024) {
          throw const WorkflowStale();
        }
        final unfinished = await tx.query(stepTable,
            where: "parentId=? AND state!='complete'",
            whereArgs: [snapshot.id]);
        if (unfinished.isNotEmpty) throw const WorkflowStale();
        return _update(tx, w, {
          'verificationJson': jsonEncode(report.toJson()),
          'state': report.isPassed ? 'complete' : 'waitingConfirmation',
          'reason': report.isPassed ? null : '客观文件检查未通过，请处理后重新验收'
        });
      });
  Future<int> publishReplyOnce(
          AgentWorkflowScope scope, String parentId, int revision,
          {required int createdAt}) =>
      _transaction(scope, (tx) async {
        final rows = await tx
            .query(workflows, where: 'parentId=?', whereArgs: [parentId]);
        if (rows.length != 1) {
          throw const WorkflowStale();
        }
        final w = rows.single;
        await _sourceValid(tx, w);
        final published = await tx
            .query(publications, where: 'parentId=?', whereArgs: [parentId]);
        if (published.isNotEmpty) {
          return published.single['messageRowId'] as int;
        }
        if (w['revision'] != revision || w['state'] != 'complete') {
          throw const WorkflowStale();
        }
        _requireVerification(w);
        if (w['verificationJson'] != null) {
          final report = AgentTaskVerificationReport.fromJson(
              jsonDecode(w['verificationJson'] as String));
          if (!report.isPassed) throw const WorkflowStale('客观验收尚未通过');
          await _checkVerification(tx, w, report);
        }
        final writer = (await tx.query(stepTable,
                where: 'parentId=? AND role=?',
                whereArgs: [parentId, 'writing']))
            .single;
        final content = writer['result'] as String;
        final blocks = MessageBlock.encodeList([
          MainTextBlock(
              id: generateUuidV4(),
              messageId: 'msg_$createdAt',
              createdAt: createdAt,
              status: MessageBlockStatus.success,
              content: content)
        ]);
        final id = await tx.insert('tb_messages', {
          'cid': w['cid'],
          'createdAt': createdAt,
          'ownerType': 'OwnerType.receiver',
          'ownerName': '协作任务',
          'content': content,
          'blocks': blocks,
          'memorySourceId': generateUuidV4()
        });
        await tx.insert(publications, {
          'parentId': parentId,
          'publicationId': w['publicationId'],
          'messageRowId': id,
          'resultHash': workflowHash(content)
        });
        await tx.update(
            'tb_conversation_list',
            {
              'lastMessage': content,
              'updateAt': createdAt,
              'messageCount': Sqflite.firstIntValue(await tx.rawQuery(
                  'SELECT COUNT(*) FROM tb_messages WHERE cid=?', [w['cid']]))
            },
            where: 'id=? AND cid=?',
            whereArgs: [w['conversationRowId'], w['cid']]);
        return id;
      });
}
