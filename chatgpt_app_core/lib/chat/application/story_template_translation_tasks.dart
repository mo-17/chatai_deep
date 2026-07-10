import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_template_background_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter/foundation.dart';

typedef StoryTemplateTranslationCall = Future<String> Function(String prompt);

/// 页面可复用的任务协调器。任务行先写入数据库，再启动网络翻译；完成、失败、取消
/// 都留在数据库中以便重启后查看。
class StoryTemplateTranslationCoordinator extends ChangeNotifier {
  static final StoryTemplateTranslationCoordinator instance =
      StoryTemplateTranslationCoordinator();

  StoryTemplateTranslationTaskDao? _taskDao;
  StoryTemplateDao? _templateDao;
  String? _accountHash;
  List<StoryTemplateTranslationTaskModel> _tasks = const [];
  final Set<int> _cancelledIds = <int>{};
  final Set<int> _runningIds = <int>{};
  final String _workerId =
      'foreground-${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  static const _leaseDuration = Duration(minutes: 5);

  List<StoryTemplateTranslationTaskModel> get tasks =>
      List.unmodifiable(_tasks);

  Future<void> initialize(
    HiDBManager storage, {
    required String accountHash,
  }) async {
    if (_taskDao != null && _accountHash == accountHash) return;
    _accountHash = accountHash;
    _taskDao = await StoryTemplateTranslationTaskDao.create(storage);
    _templateDao = await StoryTemplateDao.create(storage);
    await _taskDao!.recoverInterruptedTasks();
    await _reload();
  }

  Future<void> start(
    StoryTemplateModel template, {
    required StoryTemplateTranslationCall complete,
  }) async {
    final taskDao = _requireTaskDao();
    final payload = StoryRoomTemplatePayload.fromTemplate(template);
    if (payload.results.isEmpty) {
      throw const FormatException('酒馆模板至少需要一个角色');
    }
    final sourceTitle = template.sourceTitle.trim().isEmpty
        ? template.title
        : template.sourceTitle;
    final task = StoryTemplateTranslationTaskModel(
      templateId: template.id,
      sourceTitle: sourceTitle,
      sourcePayload: jsonEncode(payload.toJson()),
      outputTitle: '${template.title}（简中）',
      roleTotal: payload.results.length,
    );
    task.log = _appendLog(task.log, '已创建中文副本任务');
    await taskDao.saveTask(task);
    _tasks = [task, ..._tasks];
    notifyListeners();
    final accountHash = _accountHash;
    if (accountHash != null) {
      unawaited(StoryTemplateBackgroundScheduler.schedule(accountHash));
    }
    unawaited(_run(task, complete));
  }

  Future<void> retry(
    StoryTemplateTranslationTaskModel task, {
    required StoryTemplateTranslationCall complete,
  }) async {
    if (!task.canRetry || task.id == null) return;
    _cancelledIds.remove(task.id);
    task.status = StoryTemplateTranslationTaskStatus.queued;
    task
      ..leaseOwner = null
      ..leaseUntil = null
      ..nextRunAt = 0;
    task.stage = '等待重试';
    task.detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task);
    task.error = '';
    task.log = _appendLog(task.log, '用户请求重试');
    await _requireTaskDao().saveTask(task);
    _sortTasks();
    notifyListeners();
    final accountHash = _accountHash;
    if (accountHash != null) {
      unawaited(StoryTemplateBackgroundScheduler.schedule(accountHash));
    }
    unawaited(_run(task, complete));
  }

  Future<void> cancel(StoryTemplateTranslationTaskModel task) async {
    final id = task.id;
    if (id == null || task.isTerminal) return;
    _cancelledIds.add(id);
    await _requireTaskDao().cancelTask(id);
    task
      ..status = StoryTemplateTranslationTaskStatus.cancelled
      ..stage = '已取消'
      ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
      ..log = _appendLog(task.log, '用户取消任务')
      ..leaseOwner = null
      ..leaseUntil = null;
    _sortTasks();
    notifyListeners();
  }

  /// App 重启或账号重新登录后，按检查点串行恢复「排队中 / 意外中断」任务。
  ///
  /// 明确失败和用户取消的任务仍留给用户手动决定，避免在网络或配置持续异常时
  /// 自动重复消耗 token。串行执行也避免多个大模板同时占满上游并触发限流。
  Future<int> resumeRecoverable({
    required StoryTemplateTranslationCall complete,
  }) async {
    final recoverable = _tasks
        .where((task) =>
            task.status == StoryTemplateTranslationTaskStatus.queued ||
            task.status == StoryTemplateTranslationTaskStatus.retryable)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var resumed = 0;
    for (final task in recoverable) {
      final id = task.id;
      if (id == null || _runningIds.contains(id)) continue;
      _cancelledIds.remove(id);
      task.status = StoryTemplateTranslationTaskStatus.queued;
      task.stage = '自动恢复翻译';
      task.detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task);
      task.error = '';
      task.log = _appendLog(task.log, '应用启动后从检查点自动恢复');
      await _requireTaskDao().saveTask(task);
      notifyListeners();
      resumed += 1;
      await _run(task, complete);
    }
    return resumed;
  }

  Future<void> dismiss(StoryTemplateTranslationTaskModel task) async {
    final id = task.id;
    if (id == null || !task.isTerminal) return;
    await _requireTaskDao().deleteTask(id);
    _tasks = _tasks.where((item) => item.id != id).toList(growable: false);
    notifyListeners();
  }

  Future<void> _run(
    StoryTemplateTranslationTaskModel task,
    StoryTemplateTranslationCall complete,
  ) async {
    final id = task.id;
    if (id == null || !_runningIds.add(id)) return;
    final leaseOwner = '$_workerId:$id';
    try {
      final claimed = await _requireTaskDao().claimTask(
        id,
        leaseOwner: leaseOwner,
        leaseDuration: _leaseDuration,
      );
      if (!claimed) return;
      final claimedTask = await _requireTaskDao().getTask(id);
      if (claimedTask == null) return;
      final index = _tasks.indexWhere((item) => item.id == id);
      if (index >= 0) _tasks[index] = claimedTask;
      await StoryTemplateTranslationTaskRunner(
        taskDao: _requireTaskDao(),
        templateDao: _requireTemplateDao(),
        task: claimedTask,
        leaseOwner: leaseOwner,
        leaseDuration: _leaseDuration,
        complete: complete,
        isCancelled: () =>
            claimedTask.status ==
                StoryTemplateTranslationTaskStatus.cancelled ||
            _cancelledIds.contains(id),
        onChanged: () {
          _sortTasks();
          notifyListeners();
        },
      ).run();
    } finally {
      _runningIds.remove(id);
      _sortTasks();
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    _tasks = await _requireTaskDao().getTasks();
    _sortTasks();
    notifyListeners();
  }

  void _sortTasks() {
    _tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  static String _appendLog(String log, String line) {
    final lines = [
      ...log.split('\n').where((item) => item.trim().isNotEmpty),
      line,
    ];
    return lines.join('\n');
  }

  StoryTemplateTranslationTaskDao _requireTaskDao() {
    final value = _taskDao;
    if (value == null) throw StateError('翻译任务尚未初始化');
    return value;
  }

  StoryTemplateDao _requireTemplateDao() {
    final value = _templateDao;
    if (value == null) throw StateError('酒馆模板尚未初始化');
    return value;
  }
}

/// 单个任务的可恢复运行器。已完成角色会写入 `partialPayload`，中断时只会重做
/// 当前角色；字段进度则在每个翻译回调中持久化为检查点。
class StoryTemplateTranslationTaskRunner {
  final StoryTemplateTranslationTaskDao taskDao;
  final StoryTemplateDao templateDao;
  final StoryTemplateTranslationTaskModel task;
  final String leaseOwner;
  final Duration leaseDuration;
  final StoryTemplateTranslationCall complete;
  final bool Function() isCancelled;
  final VoidCallback? onChanged;
  Future<void> _writes = Future<void>.value();

  StoryTemplateTranslationTaskRunner({
    required this.taskDao,
    required this.templateDao,
    required this.task,
    required this.leaseOwner,
    this.leaseDuration = const Duration(minutes: 5),
    required this.complete,
    required this.isCancelled,
    this.onChanged,
  });

  Future<void> run() async {
    try {
      _throwIfCancelled();
      final source = _sourcePayload();
      final translated = _resumeResults(source);
      task
        ..status = StoryTemplateTranslationTaskStatus.running
        ..roleTotal = source.results.length
        ..roleIndex = translated.length
        ..stage = '初始化翻译引擎'
        ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
        ..progress = _progressFor(source.results.length, translated.length, 0);
      _checkpoint('开始执行翻译任务');

      for (var index = translated.length;
          index < source.results.length;
          index++) {
        _throwIfCancelled();
        final sourceRole = source.results[index];
        task
          ..roleIndex = index
          ..roleName = sourceRole.assistant.name
          ..fieldIndex = 0
          ..fieldTotal = 0
          ..fieldLabel = ''
          ..fieldProgress = 0
          ..stage = '准备翻译角色'
          ..detail = '角色 ${index + 1}/${source.results.length}'
          ..progress = _progressFor(source.results.length, index, 0);
        _checkpoint();

        final prepared = await TavernRoomImportPreparer.prepare(
          [sourceRole],
          translateToSimplifiedChinese: true,
          complete: _completeWithCancellation,
          initialTranslatedFields: {
            0: _resumeFieldCheckpoint(scope: 'role', roleIndex: index),
          },
          onFieldCheckpoint: (_, field, value) => _saveFieldCheckpoint(
            scope: 'role',
            roleIndex: index,
            field: field,
            value: value,
          ),
          onProgress: (value) {
            task
              ..roleIndex = index
              ..roleTotal = source.results.length
              ..roleName = value.name
              ..fieldIndex = value.fieldCurrent
              ..fieldTotal = value.fieldTotal
              ..fieldLabel = value.fieldLabel
              ..fieldProgress = value.fieldProgress.clamp(0, 1).toDouble()
              ..stage = value.stage
              ..detail = _roleDetail(value)
              ..progress = _progressFor(
                source.results.length,
                index,
                _fieldRatio(value),
              );
            _checkpoint();
          },
        );
        _throwIfCancelled();
        translated.add(prepared.single);
        task
          ..roleIndex = index + 1
          ..roleName = prepared.single.assistant.name
          ..fieldIndex = 0
          ..fieldTotal = 0
          ..fieldLabel = ''
          ..fieldProgress = 0
          ..stage = '角色已翻译'
          ..detail = '角色 ${index + 1}/${source.results.length}'
          ..progress = _progressFor(source.results.length, index + 1, 0)
          ..fieldPayload = ''
          ..partialPayload = jsonEncode(
            StoryRoomTemplatePayload(
              results: translated,
              promptConfigJson: source.promptConfigJson,
              quickRepliesJson: source.quickRepliesJson,
            ).toJson(),
          );
        _checkpoint();
        await _flush();
      }

      var opening = source.initialOpening;
      if (opening.trim().isNotEmpty) {
        task
          ..roleIndex = source.results.length
          ..roleName = '模板开场'
          ..stage = '准备翻译模板开场'
          ..detail = '${opening.length} 字'
          ..progress = 0.84;
        _checkpoint();
        final translatedOpening = await AssistantRoleCardTranslationService
            .translateToSimplifiedChinese(
          AssistantModel(name: '模板开场', openingMessage: opening),
          complete: _completeWithCancellation,
          initialTranslatedFields: _resumeFieldCheckpoint(
            scope: 'opening',
            roleIndex: source.results.length,
          ),
          onFieldCheckpoint: (field, value) => _saveFieldCheckpoint(
            scope: 'opening',
            roleIndex: source.results.length,
            field: field,
            value: value,
          ),
          onProgress: (value) {
            task
              ..fieldIndex = value.current
              ..fieldTotal = value.total
              ..fieldLabel = value.fieldLabel
              ..fieldProgress = value.fieldProgress.clamp(0, 1).toDouble()
              ..stage = value.stage
              ..detail = _translationDetail(value)
              ..progress = 0.84 + (0.1 * _fieldRatioFromTranslation(value));
            _checkpoint();
          },
        );
        _throwIfCancelled();
        final value = translatedOpening.openingMessage.trim();
        if (value.isNotEmpty) opening = value;
        task.fieldPayload = '';
        _checkpoint();
        await _flush();
      }

      task
        ..stage = '保存中文副本模板'
        ..detail = ''
        ..progress = 0.96;
      _checkpoint();
      await _flush();
      _throwIfCancelled();

      final existingTitles =
          (await templateDao.getTemplates()).map((item) => item.title);
      final title = StoryTemplateTransfer.uniqueTitle(
        task.outputTitle,
        existingTitles,
      );
      final copy = StoryRoomTemplatePayload(
        results: translated,
        initialOpening: opening,
        promptConfigJson: source.promptConfigJson,
        quickRepliesJson: source.quickRepliesJson,
      ).toTemplate(
        title: title,
        sourceTitle: task.sourceTitle,
        translated: true,
      );
      task
        ..outputTitle = title
        ..status = StoryTemplateTranslationTaskStatus.completed
        ..stage = '已生成中文副本'
        ..detail = ''
        ..progress = 1
        ..error = '';
      task.log = _appendLog(task.log, '中文副本已保存：$title');
      final outputId = await taskDao.completeWithTemplate(
        task,
        outputTemplate: copy,
        leaseOwner: leaseOwner,
      );
      if (outputId == null) throw const _StoryTemplateTranslationLeaseLost();
      task.outputTemplateId = outputId;
      onChanged?.call();
    } on RoleCardTranslationCancelled {
      try {
        await _flush();
      } on _StoryTemplateTranslationLeaseLost {
        // UI/另一个 worker 可能已经清除了租约，等待队列结束即可。
      }
      await taskDao.cancelTask(task.id!, leaseOwner: leaseOwner);
      task
        ..status = StoryTemplateTranslationTaskStatus.cancelled
        ..stage = '已取消'
        ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
        ..leaseOwner = null
        ..leaseUntil = null;
      onChanged?.call();
    } on _StoryTemplateTranslationLeaseLost {
      // 另一个前台/系统 worker 已接管，当前运行器立即静默停止。
      return;
    } catch (error, stackTrace) {
      task
        ..status = StoryTemplateTranslationTaskStatus.failed
        ..stage = '生成中文副本失败'
        ..error = error is FormatException ? error.message : error.toString();
      task.log = _appendLog(
        task.log,
        '失败：${task.error}\n${stackTrace.toString().trim()}',
      );
      _queueSave(releaseLease: true);
      await _flush();
    }
  }

  StoryRoomTemplatePayload _sourcePayload() {
    final decoded = jsonDecode(task.sourcePayload);
    if (decoded is! Map) {
      throw const FormatException('翻译任务缺少有效模板快照');
    }
    final payload = StoryRoomTemplatePayload.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    if (payload.results.isEmpty) {
      throw const FormatException('翻译任务至少需要一个角色');
    }
    return payload;
  }

  List<AssistantRoleCardImportResult> _resumeResults(
    StoryRoomTemplatePayload source,
  ) {
    if (task.partialPayload.trim().isEmpty) {
      return <AssistantRoleCardImportResult>[];
    }
    try {
      final decoded = jsonDecode(task.partialPayload);
      if (decoded is! Map) return <AssistantRoleCardImportResult>[];
      final results = StoryRoomTemplatePayload.fromJson(
        Map<String, dynamic>.from(decoded),
      ).results;
      if (results.length > source.results.length ||
          results.length != task.roleIndex) {
        return <AssistantRoleCardImportResult>[];
      }
      return List<AssistantRoleCardImportResult>.from(results);
    } catch (_) {
      return <AssistantRoleCardImportResult>[];
    }
  }

  Map<String, String> _resumeFieldCheckpoint({
    required String scope,
    required int roleIndex,
  }) {
    final raw = task.fieldPayload.trim();
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['scope'] != scope ||
          decoded['roleIndex'] != roleIndex ||
          decoded['fields'] is! Map) {
        return const {};
      }
      return {
        for (final entry in (decoded['fields'] as Map).entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _saveFieldCheckpoint({
    required String scope,
    required int roleIndex,
    required String field,
    required String value,
  }) async {
    final fields = Map<String, String>.from(_resumeFieldCheckpoint(
      scope: scope,
      roleIndex: roleIndex,
    ));
    fields[field] = value;
    task.fieldPayload = jsonEncode({
      'scope': scope,
      'roleIndex': roleIndex,
      'fields': fields,
    });
    _checkpoint(
        '已保存字段检查点：${task.fieldLabel.isEmpty ? field : task.fieldLabel}');
    await _flush();
  }

  Future<String> _completeWithCancellation(String prompt) async {
    _throwIfCancelled();
    final response = await complete(prompt);
    _throwIfCancelled();
    return response;
  }

  void _throwIfCancelled() {
    if (isCancelled()) throw const RoleCardTranslationCancelled();
  }

  void _checkpoint([String? log]) {
    if (log != null && log.trim().isNotEmpty) {
      task.log = _appendLog(task.log, log.trim());
    } else if (task.stage.trim().isNotEmpty) {
      task.log = _appendLog(
        task.log,
        [
          _time(),
          task.stage,
          if (task.detail.trim().isNotEmpty) task.detail.trim(),
          '进度 ${(task.progress.clamp(0, 1) * 100).round()}%',
        ].join(' · '),
      );
    }
    _queueSave();
    onChanged?.call();
  }

  void _queueSave({bool releaseLease = false}) {
    // task 会在翻译流程中持续变化；每次排队必须冻结当时快照，
    // 否则早期检查点可能在执行时误读到后来的 completed 状态。
    final snapshot = StoryTemplateTranslationTaskModel.fromJson(task.toJson());
    _writes = _writes.then((_) async {
      final saved = await taskDao.saveClaimedTask(
        snapshot,
        leaseOwner: leaseOwner,
        leaseDuration: leaseDuration,
        releaseLease: releaseLease,
      );
      if (!saved) throw const _StoryTemplateTranslationLeaseLost();
      if (!releaseLease && task.leaseOwner == leaseOwner) {
        task
          ..leaseUntil = snapshot.leaseUntil
          ..updatedAt = snapshot.updatedAt;
      }
    });
  }

  Future<void> _flush() => _writes;

  static double _progressFor(int total, int completed, double fieldProgress) {
    if (total <= 0) return 0;
    final ratio = (completed + fieldProgress.clamp(0, 1)) / total;
    return (0.04 + (0.78 * ratio)).clamp(0.04, 0.82).toDouble();
  }

  static double _fieldRatio(TavernRoomImportProgress value) {
    if (value.fieldTotal <= 0) return 0;
    return ((value.fieldCurrent - 1).clamp(0, value.fieldTotal) +
            value.fieldProgress.clamp(0, 1).toDouble()) /
        value.fieldTotal;
  }

  static double _fieldRatioFromTranslation(RoleCardTranslationProgress value) {
    if (value.total <= 0) return 0;
    return ((value.current - 1).clamp(0, value.total) +
            value.fieldProgress.clamp(0, 1).toDouble()) /
        value.total;
  }

  static String _roleDetail(TavernRoomImportProgress value) {
    final parts = <String>[
      if (value.total > 1) '角色 ${value.current}/${value.total}',
      if (value.fieldLabel.isNotEmpty) value.fieldLabel,
      if (value.fieldTotal > 1) '${value.fieldCurrent}/${value.fieldTotal}',
      if (value.detail.trim().isNotEmpty) value.detail.trim(),
    ];
    return parts.join(' · ');
  }

  static String _translationDetail(RoleCardTranslationProgress value) {
    final parts = <String>[
      if (value.fieldLabel.isNotEmpty) value.fieldLabel,
      if (value.total > 1) '${value.current}/${value.total}',
      if (value.detail.trim().isNotEmpty) value.detail.trim(),
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

  static String _time() {
    final now = DateTime.now();
    return [
      now.hour.toString().padLeft(2, '0'),
      now.minute.toString().padLeft(2, '0'),
      now.second.toString().padLeft(2, '0'),
    ].join(':');
  }
}

class _StoryTemplateTranslationLeaseLost implements Exception {
  const _StoryTemplateTranslationLeaseLost();
}
