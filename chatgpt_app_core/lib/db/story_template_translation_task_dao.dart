import 'package:chatgpt_app_core/chat/application/tavern_room_import_finalizer.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';

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

  @override
  String tableName = 'tb_story_template_translation_task';

  StoryTemplateTranslationTaskDao._(this.storage);

  static Future<StoryTemplateTranslationTaskDao> create(
    HiDBManager storage,
  ) async {
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
    return StoryTemplateTranslationTaskDao._(storage);
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

  /// 原子领取可运行任务。只有排队/可重试任务，或租约已过期的运行中任务可被领取。
  Future<bool> claimTask(
    int taskId, {
    required String leaseOwner,
    required Duration leaseDuration,
    DateTime? now,
  }) async {
    _validateLease(leaseOwner, leaseDuration);
    final timestamp = _timestamp(now);
    final leaseUntil = timestamp + leaseDuration.inMilliseconds;
    final changed = await storage.db.rawUpdate(
      'update $tableName set status = ?, leaseOwner = ?, leaseUntil = ?, '
      'attempts = coalesce(attempts, 0) + 1, nextRunAt = null, updatedAt = ? '
      'where id = ? AND ((status IN (?, ?) AND '
      '(nextRunAt IS NULL OR nextRunAt <= ?)) OR '
      '(status = ? AND (leaseUntil IS NULL OR leaseUntil <= ?)))',
      [
        StoryTemplateTranslationTaskStatus.running,
        leaseOwner,
        leaseUntil,
        timestamp,
        taskId,
        StoryTemplateTranslationTaskStatus.queued,
        StoryTemplateTranslationTaskStatus.retryable,
        timestamp,
        StoryTemplateTranslationTaskStatus.running,
        timestamp,
      ],
    );
    return changed == 1;
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
      where: 'id = ? AND status IN (?, ?, ?, ?, ?)$ownerWhere',
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
  }) async {
    final taskId = task.id;
    if (taskId == null || leaseOwner.trim().isEmpty) return null;
    await StoryTemplateDao.create(storage);
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
  }) async {
    final taskId = task.id;
    if (taskId == null || leaseOwner.trim().isEmpty) return null;
    await StoryTemplateDao.create(storage);
    await StoryRoomDao.create(storage);
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
  Future<void> recoverInterruptedTasks({DateTime? now}) async {
    final timestamp = _timestamp(now);
    final rows = await storage.db.query(
      tableName,
      where: 'status = ? AND (leaseUntil IS NULL OR leaseUntil <= ?)',
      whereArgs: [StoryTemplateTranslationTaskStatus.running, timestamp],
    );
    for (final row in rows) {
      final task = StoryTemplateTranslationTaskModel.fromJson(row)
        ..status = StoryTemplateTranslationTaskStatus.retryable
        ..stage = '上次运行已中断，可重试'
        ..detail = taskCheckpointDetail(
            StoryTemplateTranslationTaskModel.fromJson(row))
        ..error = ''
        ..leaseOwner = null
        ..leaseUntil = null
        ..nextRunAt = timestamp;
      task.log = _appendLog(task.log, '应用已重启，运行中的任务已恢复为可重试状态');
      await saveTask(task);
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
