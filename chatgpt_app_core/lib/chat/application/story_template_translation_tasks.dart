import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_template_background_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_finalizer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter/foundation.dart';

typedef TranslationExecutorResolver = TranslationStreamExecutor Function(
  TranslationRequestProfile profile,
);
typedef StoryTemplateTranslationCall = Future<String> Function(String prompt);
typedef LegacyTranslationRequestProfileResolver = TranslationRequestProfile?
    Function();
typedef _TranslationRunKey = ({
  int bindingEpoch,
  String accountHash,
  int taskId,
});

enum _ClaimStopReason { userCancelled, lifecycleCancelled }

final class _TranslationBindingContext {
  final int epoch;
  final String accountHash;
  final HiDBManager storage;
  final StoryTemplateTranslationTaskDao taskDao;
  final StoryTemplateDao templateDao;

  const _TranslationBindingContext({
    required this.epoch,
    required this.accountHash,
    required this.storage,
    required this.taskDao,
    required this.templateDao,
  });
}

/// 页面可复用的任务协调器。任务行先写入数据库，再启动网络翻译；完成、失败、取消
/// 都留在数据库中以便重启后查看。
class StoryTemplateTranslationCoordinator extends ChangeNotifier {
  static final StoryTemplateTranslationCoordinator instance =
      StoryTemplateTranslationCoordinator();

  _TranslationBindingContext? _binding;
  int _lifecycleEpoch = 0;
  List<StoryTemplateTranslationTaskModel> _tasks = const [];
  final Expando<int> _taskBindingEpoch =
      Expando<int>('story-template-translation-binding-epoch');
  final Set<_TranslationRunKey> _cancelledRuns = {};
  final Set<_TranslationRunKey> _runningRuns = {};
  final Set<_TranslationRunKey> _lifecycleCancelledRuns = {};
  final Map<_TranslationRunKey, TranslationCancellationController>
      _cancellations = {};
  final Map<_TranslationRunKey, Future<void>> _runSettlements = {};
  final String _workerId =
      'foreground-${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  static const _leaseDuration = Duration(minutes: 5);

  List<StoryTemplateTranslationTaskModel> get tasks =>
      List.unmodifiable(_tasks);

  Future<void> initialize(
    HiDBManager storage, {
    required String accountHash,
  }) async {
    final current = _binding;
    if (current != null &&
        _isContextCurrent(current) &&
        current.accountHash == accountHash &&
        identical(current.storage, storage)) {
      return;
    }
    final transitionEpoch = ++_lifecycleEpoch;
    final previous = current;
    _tasks = const [];
    notifyListeners();
    final settlements = _requestLifecycleCancellation(previous);
    await Future.wait(settlements);
    if (!_isEpochCurrent(transitionEpoch)) return;
    _cleanupRunState(previous);

    try {
      final taskDao = await StoryTemplateTranslationTaskDao.create(storage);
      if (!_isEpochCurrent(transitionEpoch)) return;
      final templateDao = await StoryTemplateDao.create(storage);
      if (!_isEpochCurrent(transitionEpoch)) return;
      await taskDao.recoverInterruptedTasks();
      if (!_isEpochCurrent(transitionEpoch)) return;
      final loadedTasks = await taskDao.getTasks();
      if (!_isEpochCurrent(transitionEpoch)) return;

      final context = _TranslationBindingContext(
        epoch: transitionEpoch,
        accountHash: accountHash,
        storage: storage,
        taskDao: taskDao,
        templateDao: templateDao,
      );
      _binding = context;
      _tasks = loadedTasks;
      for (final task in _tasks) {
        _trackTask(context, task);
      }
      _sortTasks();
      notifyListeners();
    } catch (_) {
      if (_isEpochCurrent(transitionEpoch)) {
        _binding = null;
        _tasks = const [];
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> start(
    StoryTemplateModel template, {
    required TranslationRequestProfile requestProfile,
    required TranslationExecutorResolver resolveExecutor,
  }) async {
    final context = _requireContext();
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
      taskKind: StoryTemplateTranslationTaskKind.templateCopy,
      requestProfile: jsonEncode(requestProfile.toJson()),
      checkpointVersion: TranslationChunkCheckpoint.currentVersion,
    );
    task.log = _appendLog(task.log, '已创建中文副本任务');
    await context.taskDao.saveTask(task);
    if (!_isContextCurrent(context)) return;
    _trackTask(context, task);
    _tasks = [task, ..._tasks];
    notifyListeners();
    unawaited(
      StoryTemplateBackgroundScheduler.schedule(context.accountHash),
    );
    unawaited(_run(context, task, resolveExecutor));
  }

  Future<void> startTavernRoomImport(
    List<AssistantRoleCardImportResult> results, {
    required String sourceTitle,
    String initialOpening = '',
    required TranslationRequestProfile requestProfile,
    required TranslationExecutorResolver resolveExecutor,
  }) async {
    if (results.isEmpty) {
      throw const FormatException('酒馆房间导入至少需要一个角色');
    }
    final context = _requireContext();
    final payload = StoryRoomTemplatePayload(
      results: results,
      initialOpening: initialOpening.trim(),
    );
    final cleanTitle = sourceTitle.trim().isEmpty ? '酒馆房间' : sourceTitle.trim();
    final task = StoryTemplateTranslationTaskModel(
      sourceTitle: cleanTitle,
      sourcePayload: jsonEncode(payload.toJson()),
      outputTitle: '$cleanTitle（简中）',
      roleTotal: results.length,
      taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
      requestProfile: jsonEncode(requestProfile.toJson()),
      checkpointVersion: TranslationChunkCheckpoint.currentVersion,
      stage: '等待翻译并导入酒馆房间',
    );
    task.log = _appendLog(task.log, '已创建酒馆房间翻译任务');
    await context.taskDao.saveTask(task);
    if (!_isContextCurrent(context)) return;
    _trackTask(context, task);
    _tasks = [task, ..._tasks];
    notifyListeners();
    unawaited(
      StoryTemplateBackgroundScheduler.schedule(context.accountHash),
    );
    unawaited(_run(context, task, resolveExecutor));
  }

  Future<void> retry(
    StoryTemplateTranslationTaskModel task, {
    TranslationRequestProfile? replacementProfile,
    required TranslationExecutorResolver resolveExecutor,
  }) async {
    final context = _contextForTask(task);
    if (context == null || !task.canRetry || task.id == null) return;
    final expectedStatus = task.status;
    final expectedUpdatedAt = task.updatedAt;
    final updated = _cloneTask(task);
    updated.status = StoryTemplateTranslationTaskStatus.queued;
    updated
      ..leaseOwner = null
      ..leaseUntil = null
      ..nextRunAt = 0;
    if (replacementProfile != null) {
      updated.requestProfile = jsonEncode(replacementProfile.toJson());
    }
    updated.stage = '等待重试';
    updated.detail =
        StoryTemplateTranslationTaskDao.taskCheckpointDetail(updated);
    updated.error = '';
    updated.log = _appendLog(updated.log, '用户请求重试');
    final saved = await context.taskDao.saveTaskIfUnclaimed(
      updated,
      expectedStatus: expectedStatus,
      expectedUpdatedAt: expectedUpdatedAt,
    );
    if (!_isContextCurrent(context)) return;
    if (!saved) {
      await _reloadAuthoritativeTask(context, task);
      return;
    }
    if (!_replaceOwnedTask(context, task, updated)) return;
    final key = _runKey(context, updated.id!);
    _cancelledRuns.remove(key);
    unawaited(
      StoryTemplateBackgroundScheduler.schedule(context.accountHash),
    );
    unawaited(_run(context, updated, resolveExecutor));
  }

  Future<void> cancel(StoryTemplateTranslationTaskModel task) async {
    final context = _contextForTask(task);
    final id = task.id;
    if (context == null ||
        id == null ||
        task.status == StoryTemplateTranslationTaskStatus.completed ||
        task.status ==
            StoryTemplateTranslationTaskStatus.completedWithWarnings ||
        task.status == StoryTemplateTranslationTaskStatus.cancelled) {
      return;
    }
    final key = _runKey(context, id);
    _cancelledRuns.add(key);
    _cancellations[key]?.cancel();
    final cancelled = await context.taskDao.cancelTask(id);
    if (!_isContextCurrent(context)) return;
    if (!cancelled) {
      _cancelledRuns.remove(key);
      await _reloadAuthoritativeTask(context, task);
      return;
    }
    if (!_isTaskOwnedByContext(context, task)) return;
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

  /// 将当前仍未完成的分块标记为保留原文。任务随后进入队列，并由前台或后台
  /// 按原模型快照继续完成字段合并和最终落库。
  Future<void> completeKeepingOriginalChunks(
    StoryTemplateTranslationTaskModel task,
  ) async {
    final context = _contextForTask(task);
    final id = task.id;
    if (context == null ||
        id == null ||
        !task.canRetry ||
        task.chunkPayload.trim().isEmpty) {
      return;
    }
    final expectedStatus = task.status;
    final expectedUpdatedAt = task.updatedAt;
    final decoded = jsonDecode(task.chunkPayload);
    if (decoded is! Map || decoded['checkpoints'] is! Map) {
      throw const FormatException('任务分块检查点无效');
    }
    final checkpoints = <String, dynamic>{};
    var retainedOriginal = false;
    for (final entry in (decoded['checkpoints'] as Map).entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final checkpoint = TranslationChunkCheckpoint.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      final chunks = <TranslationChunkState>[];
      for (final state in checkpoint.chunks) {
        if (state.status == TranslationChunkStatus.retainedOriginal) {
          retainedOriginal = true;
        }
        if (state.status != TranslationChunkStatus.pending) {
          chunks.add(state);
          continue;
        }
        retainedOriginal = true;
        chunks.add(TranslationChunkState(
          chunk: state.chunk,
          status: TranslationChunkStatus.retainedOriginal,
          translatedText: '',
          attempts: state.attempts,
          lastErrorKind: state.lastErrorKind,
        ));
      }
      checkpoints[entry.key as String] = TranslationChunkCheckpoint(
        field: checkpoint.field,
        sourceHash: checkpoint.sourceHash,
        chunks: chunks,
      ).toJson();
    }
    final updated = _cloneTask(task);
    updated
      ..chunkPayload = jsonEncode({
        'version': TranslationChunkCheckpoint.currentVersion,
        'checkpoints': checkpoints,
      })
      ..checkpointVersion = TranslationChunkCheckpoint.currentVersion
      ..partialPayload = retainedOriginal
          ? _withRetainedOriginalFlag(updated.partialPayload)
          : updated.partialPayload
      ..status = StoryTemplateTranslationTaskStatus.queued
      ..stage = '保留失败分块原文，等待完成'
      ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(updated)
      ..error = ''
      ..leaseOwner = null
      ..leaseUntil = null
      ..nextRunAt = 0;
    updated.log = _appendLog(updated.log, '用户选择保留未完成分块原文');
    final saved = await context.taskDao.saveTaskIfUnclaimed(
      updated,
      expectedStatus: expectedStatus,
      expectedUpdatedAt: expectedUpdatedAt,
    );
    if (!_isContextCurrent(context)) return;
    if (!saved) {
      await _reloadAuthoritativeTask(context, task);
      return;
    }
    if (!_replaceOwnedTask(context, task, updated)) return;
    _cancelledRuns.remove(_runKey(context, id));
    unawaited(
      StoryTemplateBackgroundScheduler.schedule(context.accountHash),
    );
  }

  /// App 重启或账号重新登录后，按检查点串行恢复「排队中 / 意外中断」任务。
  ///
  /// 明确失败和用户取消的任务仍留给用户手动决定，避免在网络或配置持续异常时
  /// 自动重复消耗 token。串行执行也避免多个大模板同时占满上游并触发限流。
  Future<int> resumeRecoverable({
    TranslationExecutorResolver? resolveExecutor,
    StoryTemplateTranslationCall? complete,
    TranslationRequestProfile? legacyRequestProfile,
    LegacyTranslationRequestProfileResolver? resolveLegacyRequestProfile,
  }) async {
    if (resolveExecutor == null && complete == null) {
      throw ArgumentError('resolveExecutor 不能为空');
    }
    final context = _requireContext();
    final now = DateTime.now().millisecondsSinceEpoch;
    final recoverable = _tasks
        .where((task) =>
            task.status == StoryTemplateTranslationTaskStatus.queued ||
            (task.status == StoryTemplateTranslationTaskStatus.retryable &&
                (task.nextRunAt == null || task.nextRunAt! <= now)))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var resumed = 0;
    var legacyFallback = legacyRequestProfile;
    var legacyFallbackResolved = legacyRequestProfile != null;
    for (final task in recoverable) {
      if (!_isContextCurrent(context)) break;
      final id = task.id;
      if (id == null || _runningRuns.contains(_runKey(context, id))) {
        continue;
      }
      final expectedStatus = task.status;
      final expectedUpdatedAt = task.updatedAt;
      final updated = _cloneTask(task);
      if (resolveExecutor != null && task.requestProfile.trim().isEmpty) {
        if (!legacyFallbackResolved) {
          legacyFallbackResolved = true;
          try {
            legacyFallback = resolveLegacyRequestProfile?.call();
          } catch (_) {
            legacyFallback = null;
          }
        }
        if (!_isContextCurrent(context)) break;
        if (legacyFallback == null) {
          updated
            ..status = StoryTemplateTranslationTaskStatus.needsConfiguration
            ..stage = '需要选择翻译模型'
            ..detail =
                StoryTemplateTranslationTaskDao.taskCheckpointDetail(updated)
            ..error = 'legacy_profile_missing';
          updated.log = _appendLog(updated.log, '旧任务缺少模型快照，已暂停等待配置');
          final saved = await context.taskDao.saveTaskIfUnclaimed(
            updated,
            expectedStatus: expectedStatus,
            expectedUpdatedAt: expectedUpdatedAt,
            requireDue: true,
          );
          if (!_isContextCurrent(context)) break;
          if (!saved) {
            await _reloadAuthoritativeTask(context, task);
            if (!_isContextCurrent(context)) break;
            continue;
          }
          _replaceOwnedTask(context, task, updated);
          continue;
        }
        updated
          ..requestProfile = jsonEncode(legacyFallback.toJson())
          ..checkpointVersion = TranslationChunkCheckpoint.currentVersion;
      }
      updated.stage = '自动恢复翻译';
      updated.detail =
          StoryTemplateTranslationTaskDao.taskCheckpointDetail(updated);
      updated.error = '';
      updated.log = _appendLog(updated.log, '应用启动后从检查点自动恢复');
      final saved = await context.taskDao.saveTaskIfUnclaimed(
        updated,
        expectedStatus: expectedStatus,
        expectedUpdatedAt: expectedUpdatedAt,
        requireDue: true,
      );
      if (!_isContextCurrent(context)) break;
      if (!saved) {
        await _reloadAuthoritativeTask(context, task);
        if (!_isContextCurrent(context)) break;
        continue;
      }
      if (!_replaceOwnedTask(context, task, updated)) continue;
      _cancelledRuns.remove(_runKey(context, id));
      resumed += 1;
      await _run(
        context,
        updated,
        resolveExecutor,
        legacyComplete: complete,
      );
      if (!_isContextCurrent(context)) break;
    }
    return resumed;
  }

  Future<void> dismiss(StoryTemplateTranslationTaskModel task) async {
    final context = _contextForTask(task);
    final id = task.id;
    if (context == null || id == null || !task.isTerminal) return;
    await context.taskDao.deleteTask(id);
    if (!_isContextCurrent(context)) return;
    _tasks = _tasks
        .where((item) => !identical(item, task) && item.id != id)
        .toList(growable: false);
    notifyListeners();
  }

  /// 账号切换或登出时立即中止当前账号的 transport，等待运行器释放
  /// 租约后解绑 DAO 和 storage。生命周期停止只把任务放回可恢复队列，
  /// 不等同于用户显式取消。
  Future<void> detachForLifecycle() async {
    final transitionEpoch = ++_lifecycleEpoch;
    final previous = _binding;
    _tasks = const [];
    notifyListeners();
    final settlements = _requestLifecycleCancellation(previous);
    await Future.wait(settlements);
    if (!_isEpochCurrent(transitionEpoch)) return;
    _cleanupRunState(previous);
    _binding = null;
    _tasks = const [];
    notifyListeners();
  }

  /// 保留旧入口，调用方依然会完成整个生命周期解绑。
  Future<void> cancelActiveRunsForLifecycle() => detachForLifecycle();

  List<Future<void>> _requestLifecycleCancellation(
    _TranslationBindingContext? context,
  ) {
    if (context == null) return const [];
    final keys = _runningRuns
        .where((key) => key.bindingEpoch == context.epoch)
        .toList(growable: false);
    if (keys.isEmpty) return const [];
    _lifecycleCancelledRuns.addAll(keys);
    for (final key in keys) {
      _cancellations[key]?.cancel();
    }
    return keys
        .map((key) => _runSettlements[key])
        .whereType<Future<void>>()
        .toList(growable: false);
  }

  void _cleanupRunState(_TranslationBindingContext? context) {
    if (context == null) return;
    bool belongsToContext(_TranslationRunKey key) =>
        key.bindingEpoch == context.epoch;
    _cancelledRuns.removeWhere(belongsToContext);
    _lifecycleCancelledRuns.removeWhere(belongsToContext);
    _cancellations.removeWhere((key, _) => belongsToContext(key));
    _runSettlements.removeWhere((key, _) => belongsToContext(key));
  }

  Future<void> _run(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskModel task,
    TranslationExecutorResolver? resolveExecutor, {
    StoryTemplateTranslationCall? legacyComplete,
  }) async {
    final id = task.id;
    if (id == null ||
        !_isContextCurrent(context) ||
        !_isTaskOwnedByContext(context, task)) {
      return;
    }
    final taskDao = context.taskDao;
    final templateDao = context.templateDao;
    final key = _runKey(context, id);
    if (!_runningRuns.add(key)) return;
    final settlement = Completer<void>();
    _runSettlements[key] = settlement.future;
    final leaseOwner = '$_workerId:${context.epoch}:$id';
    try {
      final claimed = await taskDao.claimTask(
        id,
        leaseOwner: leaseOwner,
        leaseDuration: _leaseDuration,
      );
      if (!claimed) {
        await _reloadAuthoritativeTask(context, task);
        return;
      }
      final claimedTask = await taskDao.getTask(id);
      if (claimedTask == null) return;
      _trackTask(context, claimedTask);
      if (_isContextCurrent(context)) {
        final index = _tasks.indexWhere(
          (item) => item.id == id && _taskBindingEpoch[item] == context.epoch,
        );
        if (index >= 0) _tasks[index] = claimedTask;
      }
      var stopReason = _claimStopReason(context, key);
      if (stopReason != null) {
        await _settleStoppedClaim(
          taskDao,
          claimedTask,
          leaseOwner,
          stopReason,
        );
        return;
      }
      TranslationStreamExecutor? executor;
      if (resolveExecutor != null) {
        try {
          final decoded = jsonDecode(claimedTask.requestProfile);
          if (decoded is! Map) throw const FormatException('模型快照格式无效');
          final profile = TranslationRequestProfile.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          executor = resolveExecutor(profile);
        } on TranslationModelUnavailableException catch (error) {
          stopReason = _claimStopReason(context, key);
          if (stopReason != null) {
            await _settleStoppedClaim(
              taskDao,
              claimedTask,
              leaseOwner,
              stopReason,
            );
            return;
          }
          await _markNeedsConfiguration(
            context,
            taskDao,
            claimedTask,
            leaseOwner,
            error.message,
          );
          return;
        } on FormatException {
          stopReason = _claimStopReason(context, key);
          if (stopReason != null) {
            await _settleStoppedClaim(
              taskDao,
              claimedTask,
              leaseOwner,
              stopReason,
            );
            return;
          }
          await _markNeedsConfiguration(
            context,
            taskDao,
            claimedTask,
            leaseOwner,
            '翻译模型快照无效',
          );
          return;
        } catch (error) {
          stopReason = _claimStopReason(context, key);
          if (stopReason != null) {
            await _settleStoppedClaim(
              taskDao,
              claimedTask,
              leaseOwner,
              stopReason,
            );
            return;
          }
          await _markExecutorSetupFailed(
            context,
            taskDao,
            claimedTask,
            leaseOwner,
            key,
            error,
          );
          return;
        }
      }
      stopReason = _claimStopReason(context, key);
      if (stopReason != null) {
        await _settleStoppedClaim(
          taskDao,
          claimedTask,
          leaseOwner,
          stopReason,
        );
        return;
      }
      final cancellation = TranslationCancellationController();
      _cancellations[key] = cancellation;
      if (_lifecycleCancelledRuns.contains(key)) cancellation.cancel();
      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: claimedTask,
        leaseOwner: leaseOwner,
        leaseDuration: _leaseDuration,
        executor: executor,
        complete: legacyComplete,
        cancellation: cancellation,
        isCancelled: () =>
            claimedTask.status ==
                StoryTemplateTranslationTaskStatus.cancelled ||
            _cancelledRuns.contains(key),
        isLifecycleCancelled: () => _lifecycleCancelledRuns.contains(key),
        onChanged: () {
          if (!_isContextCurrent(context)) return;
          _sortTasks();
          notifyListeners();
        },
      ).run();
    } finally {
      _cancellations.remove(key);
      _runningRuns.remove(key);
      _lifecycleCancelledRuns.remove(key);
      _runSettlements.remove(key);
      if (!settlement.isCompleted) settlement.complete();
      if (_isContextCurrent(context)) {
        _sortTasks();
        notifyListeners();
      }
    }
  }

  _ClaimStopReason? _claimStopReason(
    _TranslationBindingContext context,
    _TranslationRunKey key,
  ) {
    if (_cancelledRuns.contains(key)) {
      return _ClaimStopReason.userCancelled;
    }
    if (_lifecycleCancelledRuns.contains(key) || !_isContextCurrent(context)) {
      return _ClaimStopReason.lifecycleCancelled;
    }
    return null;
  }

  Future<void> _settleStoppedClaim(
    StoryTemplateTranslationTaskDao taskDao,
    StoryTemplateTranslationTaskModel task,
    String leaseOwner,
    _ClaimStopReason reason,
  ) async {
    final id = task.id;
    if (id == null) return;
    if (reason == _ClaimStopReason.userCancelled) {
      await taskDao.cancelTask(id, leaseOwner: leaseOwner);
      task
        ..status = StoryTemplateTranslationTaskStatus.cancelled
        ..stage = '已取消'
        ..leaseOwner = null
        ..leaseUntil = null;
      return;
    }

    task
      ..stage = '账号已切换，等待恢复'
      ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
      ..error = '';
    task.log = _appendLog(task.log, '账号生命周期结束，任务已停止并等待恢复');
    final saved = await taskDao.saveClaimedTask(
      task,
      leaseOwner: leaseOwner,
      leaseDuration: _leaseDuration,
    );
    if (!saved) return;
    final released = await taskDao.releaseLease(
      id,
      leaseOwner: leaseOwner,
    );
    if (!released) return;
    task
      ..status = StoryTemplateTranslationTaskStatus.retryable
      ..leaseOwner = null
      ..leaseUntil = null;
  }

  Future<void> _markNeedsConfiguration(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskDao taskDao,
    StoryTemplateTranslationTaskModel task,
    String leaseOwner,
    String message,
  ) async {
    task
      ..status = StoryTemplateTranslationTaskStatus.needsConfiguration
      ..stage = '翻译模型不可用'
      ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
      ..error = 'model_unavailable';
    task.log = _appendLog(task.log, message);
    await taskDao.saveClaimedTask(
      task,
      leaseOwner: leaseOwner,
      leaseDuration: _leaseDuration,
      releaseLease: true,
    );
    if (_isContextCurrent(context)) notifyListeners();
  }

  Future<void> _markExecutorSetupFailed(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskDao taskDao,
    StoryTemplateTranslationTaskModel task,
    String leaseOwner,
    _TranslationRunKey key,
    Object error,
  ) async {
    final id = task.id;
    if (id == null) return;
    task
      ..stage = '翻译执行器初始化失败，可重试'
      ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
      ..error = 'translation_executor_failed';
    task.log = _appendLog(task.log, '翻译执行器初始化失败（${error.runtimeType}）');
    final saved = await taskDao.saveClaimedTask(
      task,
      leaseOwner: leaseOwner,
      leaseDuration: _leaseDuration,
    );
    if (!saved) return;
    final stopReason = _claimStopReason(context, key);
    if (stopReason != null) {
      await _settleStoppedClaim(
        taskDao,
        task,
        leaseOwner,
        stopReason,
      );
      return;
    }
    final released = await taskDao.releaseLease(
      id,
      leaseOwner: leaseOwner,
    );
    if (!released || _claimStopReason(context, key) != null) return;
    task
      ..status = StoryTemplateTranslationTaskStatus.retryable
      ..leaseOwner = null
      ..leaseUntil = null;
    if (_isContextCurrent(context)) notifyListeners();
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

  static String _withRetainedOriginalFlag(String partialPayload) {
    final raw = partialPayload.trim();
    if (raw.isEmpty) {
      return jsonEncode({'_translationHasRetainedOriginal': true});
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('任务部分检查点无效');
    }
    return jsonEncode({
      ...Map<String, dynamic>.from(decoded),
      '_translationHasRetainedOriginal': true,
    });
  }

  bool _isEpochCurrent(int epoch) => _lifecycleEpoch == epoch;

  bool _isContextCurrent(_TranslationBindingContext context) =>
      _isEpochCurrent(context.epoch) && identical(_binding, context);

  _TranslationBindingContext _requireContext() {
    final context = _binding;
    if (context == null || !_isContextCurrent(context)) {
      throw StateError('翻译任务尚未初始化');
    }
    return context;
  }

  _TranslationBindingContext? _contextForTask(
    StoryTemplateTranslationTaskModel task,
  ) {
    final context = _binding;
    if (context == null || !_isTaskOwnedByContext(context, task)) return null;
    return context;
  }

  bool _isTaskOwnedByContext(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskModel task,
  ) {
    if (!_isContextCurrent(context) ||
        _taskBindingEpoch[task] != context.epoch) {
      return false;
    }
    final id = task.id;
    if (id == null) return false;
    return _tasks.any(
      (candidate) =>
          identical(candidate, task) &&
          candidate.id == id &&
          _taskBindingEpoch[candidate] == context.epoch,
    );
  }

  static StoryTemplateTranslationTaskModel _cloneTask(
    StoryTemplateTranslationTaskModel task,
  ) =>
      StoryTemplateTranslationTaskModel.fromJson(task.toJson());

  bool _replaceOwnedTask(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskModel current,
    StoryTemplateTranslationTaskModel replacement,
  ) {
    if (!_isTaskOwnedByContext(context, current)) return false;
    final index = _tasks.indexWhere(
      (candidate) => identical(candidate, current),
    );
    if (index < 0) return false;
    _trackTask(context, replacement);
    _tasks = List<StoryTemplateTranslationTaskModel>.from(_tasks)
      ..[index] = replacement;
    _sortTasks();
    notifyListeners();
    return true;
  }

  Future<void> _reloadAuthoritativeTask(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskModel current,
  ) async {
    final id = current.id;
    if (id == null) return;
    final authoritative = await context.taskDao.getTask(id);
    if (!_isTaskOwnedByContext(context, current)) return;
    final index = _tasks.indexWhere(
      (candidate) => identical(candidate, current),
    );
    if (index < 0) return;
    final tasks = List<StoryTemplateTranslationTaskModel>.from(_tasks);
    if (authoritative == null) {
      tasks.removeAt(index);
    } else {
      _trackTask(context, authoritative);
      tasks[index] = authoritative;
    }
    _tasks = tasks;
    _sortTasks();
    notifyListeners();
  }

  void _trackTask(
    _TranslationBindingContext context,
    StoryTemplateTranslationTaskModel task,
  ) {
    _taskBindingEpoch[task] = context.epoch;
  }

  static _TranslationRunKey _runKey(
    _TranslationBindingContext context,
    int taskId,
  ) =>
      (
        bindingEpoch: context.epoch,
        accountHash: context.accountHash,
        taskId: taskId,
      );
}

/// 单个任务的可恢复运行器。已完成角色会写入 `partialPayload`，中断时只会重做
/// 当前角色；字段进度则在每个翻译回调中持久化为检查点。
class StoryTemplateTranslationTaskRunner {
  final StoryTemplateTranslationTaskDao taskDao;
  final StoryTemplateDao templateDao;
  final StoryTemplateTranslationTaskModel task;
  final String leaseOwner;
  final Duration leaseDuration;
  final TranslationStreamExecutor? executor;
  final StoryTemplateTranslationCall? complete;
  final TranslationCancellationController cancellation;
  final bool useChunkCheckpoints;
  final bool Function() isCancelled;
  final bool Function() isLifecycleCancelled;
  final VoidCallback? onChanged;
  Future<void> _writes = Future<void>.value();
  Timer? _heartbeat;
  bool _leaseLost = false;
  bool _retainedOriginalObserved = false;
  bool _openingCompleted = false;

  StoryTemplateTranslationTaskRunner({
    required this.taskDao,
    required this.templateDao,
    required this.task,
    required this.leaseOwner,
    this.leaseDuration = const Duration(minutes: 5),
    this.executor,
    this.complete,
    TranslationCancellationController? cancellation,
    bool? useChunkCheckpoints,
    required this.isCancelled,
    bool Function()? isLifecycleCancelled,
    this.onChanged,
  })  : assert(executor != null || complete != null),
        cancellation = cancellation ?? TranslationCancellationController(),
        useChunkCheckpoints = useChunkCheckpoints ?? executor != null,
        isLifecycleCancelled = isLifecycleCancelled ?? (() => false);

  Future<void> run() async {
    _startHeartbeat();
    try {
      _throwIfCancelled();
      final source = _sourcePayload();
      final translated = _resumeResults(source);
      _retainedOriginalObserved = _resumeRetainedOriginalFlag();
      _openingCompleted = _resumeOpeningCompletedFlag();
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
          initialChunkCheckpoints: !useChunkCheckpoints
              ? const {}
              : _resumeRoleChunkCheckpoints(index),
          onChunkCheckpoint: !useChunkCheckpoints
              ? null
              : (_, checkpoint) => _saveChunkCheckpoint(
                    scope: 'role',
                    roleIndex: index,
                    field: checkpoint.field,
                    checkpoint: checkpoint,
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
          ..chunkPayload = ''
          ..partialPayload = _encodePartialPayload(
            source: source,
            translated: translated,
            opening: source.initialOpening,
          );
        _checkpoint();
        await _flush();
      }

      var opening = _resumeOpening(source);
      if (!_openingCompleted && opening.trim().isNotEmpty) {
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
          initialChunkCheckpoints: !useChunkCheckpoints
              ? const {}
              : _resumeOpeningChunkCheckpoints(),
          onChunkCheckpoint: !useChunkCheckpoints
              ? null
              : (field, checkpoint) => _saveChunkCheckpoint(
                    scope: 'opening',
                    roleIndex: source.results.length,
                    field: field,
                    checkpoint: checkpoint,
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
        _openingCompleted = true;
        task
          ..fieldPayload = ''
          ..chunkPayload = ''
          ..partialPayload = _encodePartialPayload(
            source: source,
            translated: translated,
            opening: opening,
          );
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
      final outputPayload = StoryRoomTemplatePayload(
        results: translated,
        initialOpening: opening,
        promptConfigJson: source.promptConfigJson,
        quickRepliesJson: source.quickRepliesJson,
        regexScriptsJson: source.regexScriptsJson,
        tavernPresetJson: source.tavernPresetJson,
        temperature: source.temperature,
        topP: source.topP,
        maxOutputTokens: source.maxOutputTokens,
      );
      final hasRetainedOriginal = _hasRetainedOriginal();
      if (task.taskKind == StoryTemplateTranslationTaskKind.tavernRoomImport) {
        task
          ..outputTitle = title
          ..stage = hasRetainedOriginal ? '已导入房间，部分内容保留原文' : '已导入酒馆房间'
          ..detail = ''
          ..progress = 1
          ..error = '';
        task.log = _appendLog(task.log, '酒馆房间已保存：$title');
        final bundle = TavernRoomImportFinalizer.build(
          payload: outputPayload,
          title: title,
          sourceTitle: task.sourceTitle,
          translated: true,
          hasRetainedOriginal: hasRetainedOriginal,
        );
        final completion = await taskDao.completeWithTavernRoom(
          task,
          bundle: bundle,
          leaseOwner: leaseOwner,
        );
        if (completion == null) {
          throw const _StoryTemplateTranslationLeaseLost();
        }
        task
          ..outputTemplateId = completion.outputTemplateId
          ..outputRoomId = completion.outputRoomId;
      } else {
        final copy = outputPayload.toTemplate(
          title: title,
          sourceTitle: task.sourceTitle,
          translated: true,
        );
        task
          ..outputTitle = title
          ..status = hasRetainedOriginal
              ? StoryTemplateTranslationTaskStatus.completedWithWarnings
              : StoryTemplateTranslationTaskStatus.completed
          ..stage = hasRetainedOriginal ? '已生成中文副本，部分内容保留原文' : '已生成中文副本'
          ..detail = ''
          ..progress = 1
          ..error = '';
        task.log = _appendLog(task.log, '中文副本已保存：$title');
        final outputId = await taskDao.completeWithTemplate(
          task,
          outputTemplate: copy,
          leaseOwner: leaseOwner,
        );
        if (outputId == null) {
          throw const _StoryTemplateTranslationLeaseLost();
        }
        task.outputTemplateId = outputId;
      }
      onChanged?.call();
    } on TranslationWorkDeferred catch (deferred) {
      if (!await _tryFlush()) return;
      task
        ..stage = '等待上游限流恢复'
        ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
        ..error = deferred.failure.safeCode
        ..nextRunAt = deferred.nextRunAt.millisecondsSinceEpoch;
      task.log = _appendLog(task.log, '请求暂缓，稍后自动重试');
      _queueSave();
      if (!await _tryFlush()) return;
      final released = await taskDao.releaseLease(
        task.id!,
        leaseOwner: leaseOwner,
        nextRunAt: deferred.nextRunAt,
      );
      if (!released) return;
      task
        ..status = StoryTemplateTranslationTaskStatus.retryable
        ..leaseOwner = null
        ..leaseUntil = null;
      onChanged?.call();
    } on TranslationWorkPaused catch (paused) {
      if (!await _tryFlush()) return;
      task
        ..status = StoryTemplateTranslationTaskStatus.failed
        ..stage = '已暂停，可重试'
        ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
        ..error = paused.failure.safeCode;
      task.log = _appendLog(task.log, '翻译已暂停，可更换模型后重试');
      _queueSave(releaseLease: true);
      if (!await _tryFlush()) return;
    } on RoleCardTranslationCancelled {
      if (_leaseLost) return;
      if (isLifecycleCancelled() && !isCancelled()) {
        task
          ..stage = '账号已切换，等待恢复'
          ..detail = StoryTemplateTranslationTaskDao.taskCheckpointDetail(task)
          ..error = '';
        task.log = _appendLog(task.log, '账号生命周期结束，任务已停止并等待恢复');
        _queueSave();
        if (!await _tryFlush()) return;
        final released = await taskDao.releaseLease(
          task.id!,
          leaseOwner: leaseOwner,
        );
        if (!released) return;
        task
          ..status = StoryTemplateTranslationTaskStatus.retryable
          ..leaseOwner = null
          ..leaseUntil = null;
        onChanged?.call();
        return;
      }
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
    } catch (error) {
      task
        ..status = StoryTemplateTranslationTaskStatus.failed
        ..stage = '生成中文副本失败'
        ..error =
            error is FormatException ? error.message : 'translation_failed';
      task.log = _appendLog(
        task.log,
        '失败：${task.error}（${error.runtimeType}）',
      );
      _queueSave(releaseLease: true);
      await _tryFlush();
    } finally {
      _heartbeat?.cancel();
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
    // raw memoryBook 的字段检查点必须由正文 sourceHash 证明可信，直到角色提交。
    if (!useChunkCheckpoints || field != 'memoryBook') {
      task.chunkPayload = '';
    }
    _checkpoint(
        '已保存字段检查点：${task.fieldLabel.isEmpty ? field : task.fieldLabel}');
    await _flush();
  }

  Map<String, TranslationChunkCheckpoint> _resumeRoleChunkCheckpoints(
    int roleIndex,
  ) {
    final checkpoints = _decodeChunkCheckpoints();
    final prefix = 'role:$roleIndex:';
    return {
      for (final entry in checkpoints.entries)
        if (entry.key.startsWith(prefix))
          '0:${entry.key.substring(prefix.length)}': entry.value,
    };
  }

  Map<String, TranslationChunkCheckpoint> _resumeOpeningChunkCheckpoints() {
    final checkpoints = _decodeChunkCheckpoints();
    const prefix = 'opening:';
    return {
      for (final entry in checkpoints.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
  }

  Map<String, TranslationChunkCheckpoint> _decodeChunkCheckpoints() {
    final raw = task.chunkPayload.trim();
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['checkpoints'] is! Map) return {};
      return {
        for (final entry in (decoded['checkpoints'] as Map).entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: TranslationChunkCheckpoint.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveChunkCheckpoint({
    required String scope,
    required int roleIndex,
    required String field,
    required TranslationChunkCheckpoint checkpoint,
  }) async {
    final checkpoints = _decodeChunkCheckpoints();
    final key =
        scope == 'opening' ? 'opening:$field' : 'role:$roleIndex:$field';
    checkpoints[key] = checkpoint;
    if (checkpoint.chunks.any(
      (state) => state.status == TranslationChunkStatus.retainedOriginal,
    )) {
      _retainedOriginalObserved = true;
    }
    task
      ..checkpointVersion = TranslationChunkCheckpoint.currentVersion
      ..chunkPayload = jsonEncode({
        'version': TranslationChunkCheckpoint.currentVersion,
        'checkpoints': {
          for (final entry in checkpoints.entries)
            entry.key: entry.value.toJson(),
        },
      });
    _checkpoint('已保存分块检查点：$field');
    await _flush();
  }

  bool _hasRetainedOriginal() =>
      _retainedOriginalObserved || _resumeRetainedOriginalFlag();

  bool _resumeRetainedOriginalFlag() {
    final raw = task.partialPayload.trim();
    if (raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          decoded['_translationHasRetainedOriginal'] == true;
    } catch (_) {
      return false;
    }
  }

  bool _resumeOpeningCompletedFlag() {
    final raw = task.partialPayload.trim();
    if (raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['_translationOpeningCompleted'] == true;
    } catch (_) {
      return false;
    }
  }

  String _resumeOpening(StoryRoomTemplatePayload source) {
    if (!_openingCompleted || task.partialPayload.trim().isEmpty) {
      return source.initialOpening;
    }
    try {
      final decoded = jsonDecode(task.partialPayload);
      if (decoded is! Map) return source.initialOpening;
      return StoryRoomTemplatePayload.fromJson(
        Map<String, dynamic>.from(decoded),
      ).initialOpening;
    } catch (_) {
      return source.initialOpening;
    }
  }

  String _encodePartialPayload({
    required StoryRoomTemplatePayload source,
    required List<AssistantRoleCardImportResult> translated,
    required String opening,
  }) =>
      jsonEncode({
        ...StoryRoomTemplatePayload(
          results: translated,
          initialOpening: opening,
          promptConfigJson: source.promptConfigJson,
          quickRepliesJson: source.quickRepliesJson,
          regexScriptsJson: source.regexScriptsJson,
          tavernPresetJson: source.tavernPresetJson,
          temperature: source.temperature,
          topP: source.topP,
          maxOutputTokens: source.maxOutputTokens,
        ).toJson(),
        '_translationHasRetainedOriginal': _retainedOriginalObserved,
        '_translationOpeningCompleted': _openingCompleted,
      });

  Future<String> _completeWithCancellation(String prompt) async {
    _throwIfCancelled();
    final activeExecutor = executor;
    if (activeExecutor == null) {
      final legacyComplete = complete!;
      final response = await legacyComplete(prompt);
      _throwIfCancelled();
      return response;
    }
    final response = await activeExecutor.complete(
      prompt,
      cancellation: cancellation,
      onPhase: (phase) {
        task.stage = switch (phase) {
          TranslationStreamPhase.waiting => '等待 AI 返回',
          TranslationStreamPhase.thinking => 'AI 正在处理',
          TranslationStreamPhase.receiving => '正在接收翻译',
        };
        _checkpoint();
      },
      onProfileChanged: (profile) async {
        _throwIfCancelled();
        task.requestProfile = jsonEncode(profile.toJson());
        _checkpoint('模型不支持显式关闭 Thinking，已保存兼容设置');
        await _flush();
      },
    );
    _throwIfCancelled();
    return response;
  }

  void _throwIfCancelled() {
    if (_leaseLost) throw const _StoryTemplateTranslationLeaseLost();
    if (isCancelled() || cancellation.isCancelled) {
      throw const RoleCardTranslationCancelled();
    }
  }

  void _startHeartbeat() {
    final interval = Duration(
      milliseconds:
          (leaseDuration.inMilliseconds / 3).floor().clamp(1, 1 << 31).toInt(),
    );
    _heartbeat = Timer.periodic(interval, (_) async {
      if (_leaseLost || cancellation.isCancelled) return;
      try {
        final renewed = await taskDao.renewLease(
          task.id!,
          leaseOwner: leaseOwner,
          leaseDuration: leaseDuration,
        );
        if (renewed) return;
      } catch (_) {
        // A transient database error must stop the request before stale output
        // can be committed under an unverified lease.
      }
      _leaseLost = true;
      cancellation.cancel();
    });
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

  Future<bool> _tryFlush() async {
    try {
      await _flush();
      return true;
    } on _StoryTemplateTranslationLeaseLost {
      return false;
    }
  }

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
