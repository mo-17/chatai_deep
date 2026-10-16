import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_finalizer.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter/foundation.dart';

final class _TemplateCompletionResult {
  final int outputTemplateId;
  final String status;
  final int updatedAt;

  const _TemplateCompletionResult({
    required this.outputTemplateId,
    required this.status,
    required this.updatedAt,
  });
}

final class _TavernRoomCompletionResult {
  final TavernRoomImportCompletion completion;
  final String status;
  final int updatedAt;

  const _TavernRoomCompletionResult({
    required this.completion,
    required this.status,
    required this.updatedAt,
  });
}

class StoryTemplateTranslationTaskDao implements ITable {
  final HiDBManager storage;

  /// 仅创建时固定；旧调用可无标签使用原 API，但不能进入新的首次绑定。
  final String? bindingAccountHash;

  @override
  String tableName = 'tb_story_template_translation_task';

  StoryTemplateTranslationTaskDao._(this.storage, this.bindingAccountHash);

  static Future<StoryTemplateTranslationTaskDao> create(HiDBManager storage,
      {String? accountHash}) async {
    if (accountHash != null && accountHash.trim().isEmpty) {
      throw ArgumentError('翻译任务数据库账号无效');
    }
    await storage.db.execute(
      'create table if not exists tb_story_template_translation_task ('
      'id integer primary key autoincrement, '
      'templateId integer, sourceTitle text, sourcePayload text, outputTitle text, '
      'outputTemplateId integer, taskKind text default \'templateCopy\', '
      'requestProfile text, chunkPayload text, outputRoomId integer, '
      'checkpointVersion integer default 0, '
      'status text, progress real, stage text, detail text, '
      'log text, error text, roleIndex integer, roleTotal integer, roleName text, '
      'fieldIndex integer, fieldTotal integer, fieldLabel text, fieldProgress real, '
      'fieldPayload text, partialPayload text, leaseOwner text, leaseUntil integer, '
      'attempts integer default 0, nextRunAt integer, createdAt integer, updatedAt integer)',
    );
    await SchemaGuard.ensureColumns(
      storage.db,
      table: 'tb_story_template_translation_task',
      columns: const {
        'fieldPayload': 'text',
        'leaseOwner': 'text',
        'leaseUntil': 'integer',
        'attempts': 'integer default 0',
        'nextRunAt': 'integer',
        'taskKind': "text default 'templateCopy'",
        'requestProfile': 'text',
        'chunkPayload': 'text',
        'outputRoomId': 'integer',
        'checkpointVersion': 'integer default 0',
      },
    );
    await storage.db.rawUpdate(
      'update tb_story_template_translation_task set taskKind = ? '
      'where taskKind is null or trim(taskKind) = ?',
      [StoryTemplateTranslationTaskKind.templateCopy, ''],
    );
    await storage.db.rawUpdate(
      'update tb_story_template_translation_task set checkpointVersion = 0 '
      'where checkpointVersion is null',
    );
    await storage.db.execute(
      'create index if not exists tb_story_template_translation_task_status_idx '
      'on tb_story_template_translation_task(status, updatedAt desc)',
    );
    await storage.db.execute(
      'create index if not exists tb_story_template_translation_task_lease_idx '
      'on tb_story_template_translation_task(status, nextRunAt, leaseUntil)',
    );
    return StoryTemplateTranslationTaskDao._(storage, accountHash);
  }

  Future<int> saveTask(StoryTemplateTranslationTaskModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final data = model.toJson()..remove('id');
    if (model.id == null) {
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      return id;
    }
    await storage.db.update(
      tableName,
      data,
      where: 'id = ?',
      whereArgs: [model.id],
    );
    return model.id!;
  }

  Future<void> saveConfirmedDirectCopy(
      StoryTemplateTranslationTaskModel original,
      StoryTemplateTranslationTaskModel copy,
      {required String accountHash,
      required void Function() verify}) async {
    if (bindingAccountHash == null ||
        bindingAccountHash != accountHash ||
        original.id == null ||
        copy.id != null) {
      throw StateError('原任务账号未得到确认');
    }
    await storage.db.transaction((txn) async {
      verify();
      final rows = await txn.query(tableName,
          where: 'id=?', whereArgs: [original.id], limit: 1);
      verify();
      if (rows.isEmpty ||
          rows.single['updatedAt'] != original.updatedAt ||
          rows.single['status'] != original.status ||
          rows.single['requestProfile'] != original.requestProfile ||
          rows.single['sourcePayload'] != original.sourcePayload) {
        throw StateError('原任务已变化，请重新核对');
      }
      copy.updatedAt = DateTime.now().millisecondsSinceEpoch;
      final data = copy.toJson()..remove('id');
      final id = await txn.insert(tableName, data);
      verify();
      copy.id = id;
    });
  }

  Future<Map<String, Object?>?> backendBindingSnapshot(int id) async {
    final rows = await storage.db
        .query(tableName, where: 'id=?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Map.unmodifiable(rows.single);
  }

  static bool unstartedForBackendBinding(Map<String, Object?> row) {
    final log = row['log'] as String? ?? '';
    return row['status'] == StoryTemplateTranslationTaskStatus.queued &&
        row['attempts'] == 0 &&
        row['leaseOwner'] == null &&
        row['leaseUntil'] == null &&
        row['nextRunAt'] == null &&
        row['outputTemplateId'] == null &&
        row['outputRoomId'] == null &&
        (row['checkpointVersion'] == 0 || row['checkpointVersion'] == 1) &&
        ['progress', 'roleIndex', 'fieldIndex', 'fieldProgress']
            .every((key) => row[key] == 0) &&
        ['partialPayload', 'fieldPayload', 'chunkPayload', 'error']
            .every((key) => row[key] == null || row[key] == '') &&
        (log.isEmpty || log == '已创建中文副本任务' || log == '已创建酒馆房间翻译任务');
  }

  Future<StoryTemplateTranslationTaskModel> bindLegacyBackendProfile(
      BackendSelectionBindingScope scope,
      {required Map<String, Object?> expected,
      required BackendSelection selection,
      DateTime? now}) {
    verifyBackendBindingScope(scope);
    return _bindLegacyBackendProfile(scope,
        expected: Map.unmodifiable(expected), selection: selection, now: now);
  }

  void verifyBackendBindingScope(BackendSelectionBindingScope scope) {
    scope.verify();
    if (bindingAccountHash == null || bindingAccountHash != scope.accountHash) {
      throw const WorkflowStale('翻译任务数据库账号不匹配，不能绑定');
    }
  }

  Future<StoryTemplateTranslationTaskModel> _bindLegacyBackendProfile(
          BackendSelectionBindingScope scope,
          {required Map<String, Object?> expected,
          required BackendSelection selection,
          DateTime? now}) =>
      scope.stable(() => storage.db.transaction((tx) async {
            verifyBackendBindingScope(scope);
            final rows = await tx.query(tableName,
                where: 'id=?', whereArgs: [expected['id']], limit: 1);
            if (rows.length != 1 ||
                !mapEquals(rows.single, expected) ||
                !unstartedForBackendBinding(rows.single)) {
              throw const WorkflowStale('翻译任务已有执行证据或原快照已变化，不能重新绑定');
            }
            final row = rows.single;
            final decoded = jsonDecode(row['requestProfile'] as String);
            if (decoded is! Map<String, dynamic>) {
              throw const FormatException('旧翻译快照无效');
            }
            final original = TranslationRequestProfile.fromJson(decoded);
            if (original.mode != TranslationExecutionMode.backend ||
                original.version != 1 ||
                original.backendSelection != null) {
              throw const WorkflowStale('不是待绑定的旧后端快照');
            }
            scope.verifyPair(selection, original.modelId);
            final profile = TranslationRequestProfile(
                mode: original.mode,
                modelId: original.modelId,
                reasoningPolicy: original.reasoningPolicy,
                reasoningControlSuppressed: original.reasoningControlSuppressed,
                backendSelection: selection);
            final oldUpdatedAt = row['updatedAt'] as int;
            final timestamp = _timestamp(now);
            final changed = await tx.update(
                tableName,
                {
                  'requestProfile': jsonEncode(profile.toJson()),
                  'updatedAt':
                      timestamp > oldUpdatedAt ? timestamp : oldUpdatedAt + 1
                },
                where:
                    'id=? AND status=? AND updatedAt=? AND requestProfile=? AND attempts=0',
                whereArgs: [
                  row['id'],
                  row['status'],
                  oldUpdatedAt,
                  row['requestProfile']
                ]);
            if (changed != 1) throw const WorkflowStale();
            final finalRows = await tx.query(tableName,
                where: 'id=?', whereArgs: [row['id']], limit: 1);
            scope.verify();
            return StoryTemplateTranslationTaskModel.fromJson(finalRows.single);
          }));

  /// 在任务尚未被领取且持久化版本仍与调用方快照一致时保存。
  ///
  /// 前台与后台 isolate 都可能持有同一任务的旧对象；因此 claim 前的修改必须同时
  /// 比较状态和 updatedAt，并拒绝覆盖仍有效的租约。显式 retry 可忽略 nextRunAt，
  /// 自动恢复则通过 [requireDue] 只更新已经到期的任务。
  Future<bool> saveTaskIfUnclaimed(
    StoryTemplateTranslationTaskModel model, {
    required String expectedStatus,
    required int expectedUpdatedAt,
    bool requireDue = false,
    DateTime? now,
    void Function()? verify,
  }) async {
    final taskId = model.id;
    if (taskId == null) return false;
    final timestamp = _timestamp(now);
    final updatedAt =
        timestamp > expectedUpdatedAt ? timestamp : expectedUpdatedAt + 1;
    final data = model.toJson()
      ..remove('id')
      ..['updatedAt'] = updatedAt;
    Future<int> update(DatabaseExecutor db) => db.update(
          tableName,
          data,
          where: 'id = ? AND status = ? AND updatedAt = ? AND '
              '(leaseOwner IS NULL OR trim(leaseOwner) = ? OR '
              'leaseUntil IS NULL OR leaseUntil <= ?)'
              '${requireDue ? ' AND (nextRunAt IS NULL OR nextRunAt <= ?)' : ''}',
          whereArgs: [
            taskId,
            expectedStatus,
            expectedUpdatedAt,
            '',
            timestamp,
            if (requireDue) timestamp,
          ],
        );
    final changed = verify == null
        ? await update(storage.db)
        : await storage.db.transaction((tx) async {
            verify();
            final changed = await update(tx);
            verify();
            return changed;
          });
    verify?.call();
    if (changed != 1) return false;
    model.updatedAt = updatedAt;
    return true;
  }

  /// 原子领取可运行任务。只有排队/可重试任务，或租约已过期的运行中任务可被领取。
  Future<bool> claimTask(
    int taskId, {
    required String leaseOwner,
    required Duration leaseDuration,
    DateTime? now,
    int? expectedUpdatedAt,
    void Function()? verifyDirectConfirmation,
  }) async {
    _validateLease(leaseOwner, leaseDuration);
    final timestamp = _timestamp(now);
    final leaseUntil = timestamp + leaseDuration.inMilliseconds;
    verifyDirectConfirmation?.call();
    return storage.db.transaction((tx) async {
      verifyDirectConfirmation?.call();
      final rows = await tx.query(tableName,
          where: 'id=?', whereArgs: [taskId], limit: 1);
      verifyDirectConfirmation?.call();
      if (rows.isEmpty) return false;
      final row = rows.single;
      if (expectedUpdatedAt != null && row['updatedAt'] != expectedUpdatedAt) {
        return false;
      }
      final awaiting = row['status'] ==
          StoryTemplateTranslationTaskStatus.awaitingConfirmation;
      if (awaiting && verifyDirectConfirmation == null) return false;
      final raw = row['requestProfile'];
      bool modern = false;
      try {
        final decoded =
            raw is String && raw.isNotEmpty ? jsonDecode(raw) : null;
        if (decoded is Map &&
            (decoded.containsKey('backendSelection') ||
                decoded.containsKey('version') && decoded['version'] != 1)) {
          modern = true;
          final profile = TranslationRequestProfile.fromJson(
              decoded.cast<String, dynamic>());
          if (profile.mode != TranslationExecutionMode.backend ||
              profile.version != 2) {
            return false;
          }
        }
      } catch (_) {
        if (modern ||
            raw is String &&
                RegExp(r'"(?:version|backendSelection)"\s*:').hasMatch(raw)) {
          return false;
        }
      }
      if (modern && expectedUpdatedAt == null) return false;
      final oldUpdatedAt = row['updatedAt'] as int? ?? 0;
      final stamp = expectedUpdatedAt != null && timestamp <= oldUpdatedAt
          ? oldUpdatedAt + 1
          : timestamp;
      final changed = await tx.rawUpdate(
        'update $tableName set status = ?, leaseOwner = ?, leaseUntil = ?, '
        'attempts = coalesce(attempts, 0) + 1, nextRunAt = null, updatedAt = ? '
        'where id = ? AND ((status IN (?, ?, ?) AND '
        '(nextRunAt IS NULL OR nextRunAt <= ?)) OR '
        '(status = ? AND (leaseUntil IS NULL OR leaseUntil <= ?))) '
        'AND updatedAt IS ? AND requestProfile IS ?',
        [
          StoryTemplateTranslationTaskStatus.running,
          leaseOwner,
          leaseUntil,
          stamp,
          taskId,
          StoryTemplateTranslationTaskStatus.queued,
          StoryTemplateTranslationTaskStatus.retryable,
          verifyDirectConfirmation == null
              ? StoryTemplateTranslationTaskStatus.queued
              : StoryTemplateTranslationTaskStatus.awaitingConfirmation,
          timestamp,
          StoryTemplateTranslationTaskStatus.running,
          timestamp,
          row['updatedAt'],
          row['requestProfile'],
        ],
      );
      verifyDirectConfirmation?.call();
      return changed == 1;
    });
  }

  /// 续租；任务已被其他运行器接管或租约已到期时返回 false。
  Future<bool> renewLease(
    int taskId, {
    required String leaseOwner,
    required Duration leaseDuration,
    DateTime? now,
  }) async {
    _validateLease(leaseOwner, leaseDuration);
    final timestamp = _timestamp(now);
    final changed = await storage.db.update(
      tableName,
      {
        'leaseUntil': timestamp + leaseDuration.inMilliseconds,
        'updatedAt': timestamp,
      },
      where: 'id = ? AND status = ? AND leaseOwner = ? AND '
          'leaseUntil IS NOT NULL AND leaseUntil > ?',
      whereArgs: [
        taskId,
        StoryTemplateTranslationTaskStatus.running,
        leaseOwner,
        timestamp,
      ],
    );
    return changed == 1;
  }

  /// 持有租约时保存检查点并续租；租约已丢失时不写入任何业务字段。
  Future<bool> saveClaimedTask(
    StoryTemplateTranslationTaskModel model, {
    required String leaseOwner,
    required Duration leaseDuration,
    bool releaseLease = false,
    DateTime? now,
  }) async {
    final taskId = model.id;
    if (taskId == null) return false;
    _validateLease(leaseOwner, leaseDuration);
    final timestamp = _timestamp(now);
    final leaseUntil = timestamp + leaseDuration.inMilliseconds;
    final data = model.toJson()..remove('id');
    data
      ..['leaseOwner'] = releaseLease ? null : leaseOwner
      ..['leaseUntil'] = releaseLease ? null : leaseUntil
      ..['nextRunAt'] = releaseLease ? null : model.nextRunAt
      ..['updatedAt'] = timestamp;
    final changed = await storage.db.update(
      tableName,
      data,
      where: 'id = ? AND status = ? AND leaseOwner = ? AND '
          'leaseUntil IS NOT NULL AND leaseUntil > ?',
      whereArgs: [
        taskId,
        StoryTemplateTranslationTaskStatus.running,
        leaseOwner,
        timestamp,
      ],
    );
    if (changed != 1) return false;
    model
      ..leaseOwner = releaseLease ? null : leaseOwner
      ..leaseUntil = releaseLease ? null : leaseUntil
      ..nextRunAt = releaseLease ? null : model.nextRunAt
      ..updatedAt = timestamp;
    return true;
  }

  /// 将持有中的任务放回可重试队列，并可指定下一次可领取时间。
  Future<bool> releaseLease(
    int taskId, {
    required String leaseOwner,
    DateTime? nextRunAt,
    DateTime? now,
  }) async {
    final timestamp = _timestamp(now);
    final changed = await storage.db.update(
      tableName,
      {
        'status': StoryTemplateTranslationTaskStatus.retryable,
        'leaseOwner': null,
        'leaseUntil': null,
        'nextRunAt': _timestamp(nextRunAt ?? now),
        'updatedAt': timestamp,
      },
      where: 'id = ? AND status = ? AND leaseOwner = ? AND '
          'leaseUntil IS NOT NULL AND leaseUntil > ?',
      whereArgs: [
        taskId,
        StoryTemplateTranslationTaskStatus.running,
        leaseOwner,
        timestamp,
      ],
    );
    return changed == 1;
  }

  /// 取消尚未完成的任务；传入 [leaseOwner] 时会同时校验当前租约归属。
  Future<bool> cancelTask(
    int taskId, {
    String? leaseOwner,
    DateTime? now,
  }) async {
    final timestamp = _timestamp(now);
    final ownerWhere = leaseOwner == null
        ? ''
        : ' AND leaseOwner = ? AND leaseUntil IS NOT NULL AND leaseUntil > ?';
    final whereArgs = <Object?>[
      taskId,
      StoryTemplateTranslationTaskStatus.queued,
      StoryTemplateTranslationTaskStatus.awaitingConfirmation,
      StoryTemplateTranslationTaskStatus.retryable,
      StoryTemplateTranslationTaskStatus.running,
      StoryTemplateTranslationTaskStatus.failed,
      StoryTemplateTranslationTaskStatus.needsConfiguration,
      if (leaseOwner != null) ...[leaseOwner, timestamp],
    ];
    final changed = await storage.db.update(
      tableName,
      {
        'status': StoryTemplateTranslationTaskStatus.cancelled,
        'leaseOwner': null,
        'leaseUntil': null,
        'nextRunAt': null,
        'updatedAt': timestamp,
      },
      where: 'id = ? AND status IN (?, ?, ?, ?, ?, ?)$ownerWhere',
      whereArgs: whereArgs,
    );
    return changed == 1;
  }

  /// 原子完成任务：已有输出模板时直接复用；否则先插入模板，再在同一事务完成任务。
  ///
  /// 返回输出模板 id。任务已经完成时也会返回已关联的 id，便于调用方安全重试。
  Future<int?> completeWithTemplate(
    StoryTemplateTranslationTaskModel task, {
    required StoryTemplateModel outputTemplate,
    required String leaseOwner,
    DateTime? now,
    VoidCallback? verifyCompletion,
  }) async {
    final taskId = task.id;
    if (taskId == null || leaseOwner.trim().isEmpty) return null;
    await StoryTemplateDao.create(storage);
    verifyCompletion?.call();
    final timestamp = _timestamp(now);
    final completionStatus =
        task.status == StoryTemplateTranslationTaskStatus.completedWithWarnings
            ? StoryTemplateTranslationTaskStatus.completedWithWarnings
            : StoryTemplateTranslationTaskStatus.completed;
    final result = await storage.db.transaction((txn) async {
      final rows = await txn.query(
        tableName,
        where: 'id = ?',
        whereArgs: [taskId],
      );
      if (rows.isEmpty) return null;
      final current = StoryTemplateTranslationTaskModel.fromJson(rows.first);
      if (current.taskKind != StoryTemplateTranslationTaskKind.templateCopy) {
        return null;
      }
      if ((current.status == StoryTemplateTranslationTaskStatus.completed ||
              current.status ==
                  StoryTemplateTranslationTaskStatus.completedWithWarnings) &&
          current.outputTemplateId != null) {
        verifyCompletion?.call();
        return _TemplateCompletionResult(
          outputTemplateId: current.outputTemplateId!,
          status: current.status,
          updatedAt: current.updatedAt,
        );
      }

      final retained = await txn.update(
        tableName,
        {'updatedAt': timestamp},
        where: 'id = ? AND status = ? AND leaseOwner = ? AND '
            'leaseUntil IS NOT NULL AND leaseUntil > ?',
        whereArgs: [
          taskId,
          StoryTemplateTranslationTaskStatus.running,
          leaseOwner,
          timestamp,
        ],
      );
      if (retained == 0) return null;

      var outputTemplateId = current.outputTemplateId;
      if (outputTemplateId == null) {
        final templateData = Map<String, dynamic>.from(outputTemplate.toJson())
          ..remove('id')
          ..['updatedAt'] = timestamp;
        outputTemplateId = await txn.insert('tb_story_template', templateData);
      }

      final taskData = Map<String, dynamic>.from(task.toJson())
        ..remove('id')
        ..['outputTemplateId'] = outputTemplateId
        ..['status'] = completionStatus
        ..['leaseOwner'] = null
        ..['leaseUntil'] = null
        ..['nextRunAt'] = null
        ..['updatedAt'] = timestamp;
      final completed = await txn.update(
        tableName,
        taskData,
        where: 'id = ? AND taskKind = ? AND status = ? AND leaseOwner = ?',
        whereArgs: [
          taskId,
          StoryTemplateTranslationTaskKind.templateCopy,
          StoryTemplateTranslationTaskStatus.running,
          leaseOwner,
        ],
      );
      if (completed != 1) throw StateError('完成翻译任务时租约状态异常');
      verifyCompletion?.call();
      return _TemplateCompletionResult(
        outputTemplateId: outputTemplateId,
        status: completionStatus,
        updatedAt: timestamp,
      );
    });
    if (result == null) return null;

    outputTemplate
      ..id = result.outputTemplateId
      ..updatedAt = result.updatedAt;
    task
      ..outputTemplateId = result.outputTemplateId
      ..status = result.status
      ..leaseOwner = null
      ..leaseUntil = null
      ..nextRunAt = null
      ..updatedAt = result.updatedAt;
    return result.outputTemplateId;
  }

  /// 原子完成 Tavern 房间导入任务；模板、房间图和任务输出 ID 同事务提交。
  ///
  /// 任务已经完成时不再要求租约，直接复用数据库记录的两个输出 ID。
  Future<TavernRoomImportCompletion?> completeWithTavernRoom(
    StoryTemplateTranslationTaskModel task, {
    required TavernRoomImportBundle bundle,
    required String leaseOwner,
    DateTime? now,
    VoidCallback? verifyCompletion,
  }) async {
    final taskId = task.id;
    if (taskId == null || leaseOwner.trim().isEmpty) return null;
    await StoryTemplateDao.create(storage);
    await StoryRoomDao.create(storage);
    verifyCompletion?.call();
    final timestamp = _timestamp(now);
    final completionStatus = bundle.hasRetainedOriginal
        ? StoryTemplateTranslationTaskStatus.completedWithWarnings
        : StoryTemplateTranslationTaskStatus.completed;
    final result = await storage.db.transaction((txn) async {
      final rows = await txn.query(
        tableName,
        where: 'id = ?',
        whereArgs: [taskId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final current = StoryTemplateTranslationTaskModel.fromJson(rows.first);
      if (current.taskKind !=
          StoryTemplateTranslationTaskKind.tavernRoomImport) {
        return null;
      }

      final isCompleted =
          current.status == StoryTemplateTranslationTaskStatus.completed ||
              current.status ==
                  StoryTemplateTranslationTaskStatus.completedWithWarnings;
      if (isCompleted) {
        final outputTemplateId = current.outputTemplateId;
        final outputRoomId = current.outputRoomId;
        if (outputTemplateId == null || outputRoomId == null) return null;
        verifyCompletion?.call();
        return _TavernRoomCompletionResult(
          completion: TavernRoomImportCompletion(
            outputTemplateId: outputTemplateId,
            outputRoomId: outputRoomId,
          ),
          status: current.status,
          updatedAt: current.updatedAt,
        );
      }
      if (current.outputRoomId != null) {
        throw StateError('运行中的 Tavern 翻译任务包含未完成的房间输出');
      }

      final retained = await txn.update(
        tableName,
        {'updatedAt': timestamp},
        where: 'id = ? AND taskKind = ? AND status = ? AND '
            'leaseOwner = ? AND leaseUntil IS NOT NULL AND leaseUntil > ?',
        whereArgs: [
          taskId,
          StoryTemplateTranslationTaskKind.tavernRoomImport,
          StoryTemplateTranslationTaskStatus.running,
          leaseOwner,
          timestamp,
        ],
      );
      if (retained != 1) return null;

      var outputTemplateId = current.outputTemplateId;
      if (outputTemplateId != null) {
        final existing = await txn.query(
          'tb_story_template',
          columns: const ['id'],
          where: 'id = ?',
          whereArgs: [outputTemplateId],
          limit: 1,
        );
        if (existing.isEmpty) outputTemplateId = null;
      }
      if (outputTemplateId == null) {
        final templateData =
            Map<String, dynamic>.from(bundle.outputTemplate.toJson())
              ..remove('id')
              ..['updatedAt'] = timestamp;
        outputTemplateId = await txn.insert(
          'tb_story_template',
          templateData,
        );
      }

      final outputRoomId = await StoryRoomDao.insertTavernImport(
        txn,
        room: bundle.room,
        participants: bundle.participants,
        messages: bundle.messages,
        now: timestamp,
      );
      final completed = await txn.update(
        tableName,
        {
          'outputTemplateId': outputTemplateId,
          'outputRoomId': outputRoomId,
          'outputTitle': task.outputTitle,
          'status': completionStatus,
          'progress': 1.0,
          'stage': task.stage,
          'detail': task.detail,
          'log': task.log,
          'error': '',
          'leaseOwner': null,
          'leaseUntil': null,
          'nextRunAt': null,
          'updatedAt': timestamp,
        },
        where: 'id = ? AND taskKind = ? AND status = ? AND '
            'leaseOwner = ? AND leaseUntil IS NOT NULL AND leaseUntil > ?',
        whereArgs: [
          taskId,
          StoryTemplateTranslationTaskKind.tavernRoomImport,
          StoryTemplateTranslationTaskStatus.running,
          leaseOwner,
          timestamp,
        ],
      );
      if (completed != 1) {
        throw StateError('完成 Tavern 翻译任务时租约状态异常');
      }
      verifyCompletion?.call();
      return _TavernRoomCompletionResult(
        completion: TavernRoomImportCompletion(
          outputTemplateId: outputTemplateId,
          outputRoomId: outputRoomId,
        ),
        status: completionStatus,
        updatedAt: timestamp,
      );
    });
    if (result == null) return null;

    final completion = result.completion;
    bundle.outputTemplate.id = completion.outputTemplateId;
    bundle.room.id = completion.outputRoomId;
    task
      ..taskKind = StoryTemplateTranslationTaskKind.tavernRoomImport
      ..outputTemplateId = completion.outputTemplateId
      ..outputRoomId = completion.outputRoomId
      ..status = result.status
      ..progress = 1
      ..error = ''
      ..leaseOwner = null
      ..leaseUntil = null
      ..nextRunAt = null
      ..updatedAt = result.updatedAt;
    return completion;
  }

  Future<List<StoryTemplateTranslationTaskModel>> getTasks() async {
    final rows = await storage.db.query(
      tableName,
      orderBy: 'updatedAt desc, id desc',
    );
    return rows.map(StoryTemplateTranslationTaskModel.fromJson).toList();
  }

  Future<StoryTemplateTranslationTaskModel?> getTask(int id) async {
    final rows = await storage.db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return StoryTemplateTranslationTaskModel.fromJson(rows.first);
  }

  /// 只恢复租约已过期的运行态，仍在有效租约内的任务继续由原运行器处理。
  Future<void> recoverInterruptedTasks({
    DateTime? now,
    @visibleForTesting Future<void> Function()? afterCandidatesLoaded,
  }) async {
    final timestamp = _timestamp(now);
    final rows = await storage.db.query(
      tableName,
      where: 'status = ? AND (leaseUntil IS NULL OR leaseUntil <= ?)',
      whereArgs: [StoryTemplateTranslationTaskStatus.running, timestamp],
    );
    await afterCandidatesLoaded?.call();
    for (final row in rows) {
      final current = StoryTemplateTranslationTaskModel.fromJson(row);
      final task = StoryTemplateTranslationTaskModel.fromJson(row)
        ..status = StoryTemplateTranslationTaskStatus.retryable
        ..stage = '上次运行已中断，可重试'
        ..detail = taskCheckpointDetail(current)
        ..error = ''
        ..leaseOwner = null
        ..leaseUntil = null
        ..nextRunAt = timestamp;
      task.log = _appendLog(task.log, '应用已重启，运行中的任务已恢复为可重试状态');
      await saveTaskIfUnclaimed(
        task,
        expectedStatus: current.status,
        expectedUpdatedAt: current.updatedAt,
        now: now,
      );
    }
  }

  Future<void> deleteTask(int id) async {
    await storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  static String taskCheckpointDetail(StoryTemplateTranslationTaskModel task) {
    final parts = <String>[
      if (task.roleTotal > 0) '角色 ${task.roleIndex}/${task.roleTotal}',
      if (task.roleName.trim().isNotEmpty) task.roleName.trim(),
      if (task.fieldLabel.trim().isNotEmpty) task.fieldLabel.trim(),
      if (task.fieldTotal > 1) '${task.fieldIndex}/${task.fieldTotal}',
    ];
    return parts.join(' · ');
  }

  static String _appendLog(String log, String line) {
    final lines = [
      ...log.split('\n').where((item) => item.trim().isNotEmpty),
      line,
    ];
    const maxLines = 500;
    if (lines.length <= maxLines) return lines.join('\n');
    return [
      '日志较长，已隐藏前 ${lines.length - maxLines} 行',
      ...lines.skip(lines.length - maxLines),
    ].join('\n');
  }

  static int _timestamp(DateTime? value) =>
      (value ?? DateTime.now()).millisecondsSinceEpoch;

  static void _validateLease(String leaseOwner, Duration leaseDuration) {
    if (leaseOwner.trim().isEmpty) {
      throw ArgumentError.value(leaseOwner, 'leaseOwner', '不能为空');
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration', '必须大于零');
    }
  }
}
