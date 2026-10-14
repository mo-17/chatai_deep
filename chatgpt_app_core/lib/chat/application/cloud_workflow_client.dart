import 'dart:async';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_api.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:flutter/foundation.dart';

class _CloudSubmission {
  final String digest, bindingId;
  final Future<CloudLocalReceipt> future;
  const _CloudSubmission(this.digest, this.bindingId, this.future);
}

/// UI实际使用的观察/提交协调器。没有本机runner，也没有create重试定时器。
class CloudWorkflowClient extends ChangeNotifier {
  final CloudWorkflowApi api;
  final CloudWorkflowDao dao;
  CloudCapability? capability;
  List<CloudProfileChoice> profiles = const [];
  List<CloudLocalReceipt> receipts = const [];
  List<Map<String, dynamic>> tasks = const [];
  String? nextCursor;
  CloudTaskDetail? detail;
  List<CloudWritingResult> results = const [];
  String? notice;
  bool stopNeedsNewIntent = false;
  bool _disposed = false, _visible = true;
  int _generation = 0;
  Timer? _poll;
  Future<void>? _refresh;
  Future<void>? _nextPage;
  final _submissions = <String, _CloudSubmission>{};
  final _stops = <String, Future<void>>{};
  CloudWorkflowClient({required this.api, required CloudWorkflowDao dao})
      : dao = dao.withSession(api.verify);
  bool get canCreate =>
      capability?.available == true &&
      api.policy.realSubmissionEnabled &&
      profiles.isNotEmpty;
  void _check() {
    api.verify();
    if (_disposed) {
      throw StateError('云任务页面已关闭');
    }
  }

  void _changed() {
    _check();
    notifyListeners();
  }

  Future<void> initialize() async {
    _check();
    final cap = await api.capability();
    _check();
    capability = cap;
    receipts = await dao.receipts(api.scope, api.origin, cap.ownerId);
    _check();
    final page = await api.list();
    _check();
    _verifyOwners(page.items, cap.ownerId);
    tasks = page.items;
    nextCursor = page.nextCursor;
    // 目录不可用时保持不可提交，既有任务读取/stop不被挡住。
    try {
      profiles = await api.profiles();
      _check();
    } on CloudHttpFailure {
      profiles = const [];
    }
    _changed();
  }

  static void _verifyOwners(List<Map<String, dynamic>> rows, int owner) {
    if (rows.any((r) => r['owner_id'] != owner)) {
      throw const FormatException('云任务owner不匹配');
    }
  }

  /// 用户明确点击才翻页，不自动遍历全部任务/快照。
  Future<void> loadNextPage() {
    _check();
    return _nextPage ??= _loadNextPage().whenComplete(() => _nextPage = null);
  }

  Future<void> _loadNextPage() async {
    final cursor = nextCursor, owner = capability?.ownerId;
    if (cursor == null || owner == null) return;
    final page = await api.list(cursor: cursor);
    _check();
    if (cursor != nextCursor || owner != capability?.ownerId) return;
    _verifyOwners(page.items, owner);
    final merged = {for (final row in tasks) row['id']: row};
    for (final row in page.items) {
      final old = merged[row['id']];
      if (old == null || row['revision'] >= old['revision']) {
        merged[row['id']] = row;
      }
    }
    tasks = List.unmodifiable(merged.values);
    nextCursor = page.nextCursor;
    _changed();
  }

  Future<CloudLocalReceipt> submit(
      CloudSourceSnapshot source, CloudConfirmedPayload payload) {
    _check();
    api.policy.verify(capability?.available == true);
    final old = _submissions[payload.key];
    if (old != null) {
      if (old.digest != payload.digest || old.bindingId != source.bindingId) {
        throw StateError('同一提交身份的内容或来源已变化');
      }
      return old.future;
    }
    final future = _submit(source, payload);
    _submissions[payload.key] =
        _CloudSubmission(payload.digest, source.bindingId, future);
    // 完成后保留该意图的future；新页面仍由持久receipt阻止再次POST。
    return future;
  }

  Future<CloudLocalReceipt> _submit(
      CloudSourceSnapshot source, CloudConfirmedPayload payload) async {
    final owner = capability!.ownerId;
    final registration = await dao.recordSubmission(api.scope,
        origin: api.origin, ownerId: owner, snapshot: source, payload: payload);
    _check();
    var receipt = registration.receipt;
    if (registration.shouldSend) {
      try {
        await api.create(capability!, payload);
        _check();
      } on CloudHttpFailure catch (e) {
        _check();
        notice = e.status == 409 ? '云状态已变化，此次提交未自动重试' : '提交未获确认，请按原提交身份查询';
      } catch (_) {
        _check();
        notice = '提交结果未知；重开或刷新只查询，不重新发送';
      }
    }
    try {
      receipt = await resolve(receipt);
      _check();
    } on CloudHttpFailure catch (e) {
      if (e.status != 404) {
        rethrow;
      }
      _check();
      notice = '暂未查到提交，仍保持未知；不会重新发送';
    }
    receipts = await dao.receipts(api.scope, api.origin, owner);
    _check();
    _changed();
    return receipt;
  }

  Future<CloudLocalReceipt> resolve(CloudLocalReceipt receipt) async {
    _check();
    if (receipt.origin != api.origin ||
        receipt.ownerId != capability?.ownerId) {
      throw StateError('回执不属于当前云会话');
    }
    final server = await api.byKey(receipt.key);
    _check();
    final bound = await dao.bindReceipt(api.scope, receipt, server);
    _check();
    // 原key查询成功后同步本会话缓存，不能等重新打开才解除未知状态。
    final current = await dao.receipts(api.scope, api.origin, receipt.ownerId);
    _check();
    receipts = current;
    _changed();
    return bound;
  }

  Future<void> open(String taskId) async {
    _check();
    final gen = ++_generation;
    _poll?.cancel();
    detail = null;
    results = const [];
    final next = await api.detail(taskId);
    _check();
    if (gen != _generation) {
      return;
    }
    if (next.ownerId != capability?.ownerId) {
      throw const FormatException('任务owner不匹配');
    }
    detail = next;
    final stop =
        await dao.readStop(api.scope, api.origin, capability!.ownerId, taskId);
    _check();
    if (gen != _generation) {
      return;
    }
    stopNeedsNewIntent = stop?['status'] == 'conflict';
    if (next.state == 'complete') {
      final value = await api.results(taskId);
      _check();
      if (gen != _generation) {
        return;
      }
      results = value;
    }
    _changed();
    _schedule();
  }

  Future<void> refresh() {
    _check();
    return _refresh ??= _refreshOnce().whenComplete(() => _refresh = null);
  }

  Future<void> _refreshOnce() async {
    final old = detail;
    if (old == null) {
      return;
    }
    final gen = _generation;
    final next = await api.detail(old.taskId);
    _check();
    if (gen != _generation || next.revision < (detail?.revision ?? 0)) {
      return;
    }
    if (next.ownerId != capability?.ownerId) {
      throw const FormatException('任务owner不匹配');
    }
    detail = next;
    if (next.state == 'complete') {
      final value = await api.results(next.taskId);
      _check();
      if (gen != _generation) {
        return;
      }
      results = value;
    }
    _changed();
    _schedule();
  }

  void visible(bool value) {
    _check();
    _visible = value;
    _poll?.cancel();
    // resumed/重新可见只GET，不触发submit或stop。
    if (value && detail != null) {
      unawaited(_observeRefresh());
    }
  }

  bool get _sessionCurrent {
    try {
      _check();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _observeRefresh() async {
    final gen = _generation;
    try {
      // async try同时接住refresh的同步guard与HTTP异步错误。
      await refresh();
    } catch (_) {
      if (!_sessionCurrent) {
        _poll?.cancel();
        return;
      }
      if (gen != _generation) return;
      notice = '状态刷新失败，可手动重试查询';
      notifyListeners();
      _schedule();
    }
  }

  void _schedule() {
    _poll?.cancel();
    if (_sessionCurrent && _visible && detail != null && !detail!.terminal) {
      _poll = Timer(
          const Duration(seconds: 20), () => unawaited(_observeRefresh()));
    }
  }

  Future<void> stop({bool newIntent = false}) {
    _check();
    final task = detail;
    if (task == null) {
      throw StateError('请先打开任务');
    }
    return _stops[task.taskId] ??=
        _stop(task, newIntent, _generation).whenComplete(() {
      _stops.remove(task.taskId);
    });
  }

  bool _observing(CloudTaskDetail task, int generation) =>
      generation == _generation && detail?.taskId == task.taskId;

  Future<void> _stop(
      CloudTaskDetail task, bool newIntent, int generation) async {
    final intent = await dao.stopIntent(
        api.scope, api.origin, capability!.ownerId, task.taskId, task.revision,
        newIntent: newIntent);
    _check();
    if (_observing(task, generation)) {
      notice = '停止请求已发出，等待服务器确认';
      _changed();
    }
    try {
      await api.stop(task.taskId, intent['operationId'] as String,
          intent['expectedRevision'] as int);
      _check();
      await dao.markStop(api.scope, api.origin, capability!.ownerId,
          task.taskId, intent['operationId'] as String, 'acknowledged');
      _check();
      if (_observing(task, generation)) stopNeedsNewIntent = false;
    } on CloudHttpFailure catch (e) {
      _check();
      await dao.markStop(
          api.scope,
          api.origin,
          capability!.ownerId,
          task.taskId,
          intent['operationId'] as String,
          e.status == 409 ? 'conflict' : 'unknown');
      _check();
      if (_observing(task, generation)) {
        stopNeedsNewIntent = e.status == 409;
        notice = e.status == 409
            ? '任务状态已变化，请刷新后再次明确停止'
            : '停止结果未知；仅查询状态，明确重试会复用原停止身份';
      }
    } catch (_) {
      _check();
      await dao.markStop(api.scope, api.origin, capability!.ownerId,
          task.taskId, intent['operationId'] as String, 'unknown');
      _check();
      if (_observing(task, generation)) {
        notice = '停止结果未知；仅查询状态，明确重试会复用原停止身份';
      }
    }
    // A的持久回执仍结算；其迟到回调不刷新或污染B详情。
    if (!_observing(task, generation)) return;
    await refresh();
    _check();
  }

  CloudLocalReceipt? get localReceipt {
    final task = detail;
    if (task == null) {
      return null;
    }
    for (final r in receipts) {
      if (r.taskId == task.taskId &&
          r.publicationId == task.parent['publication_id']) {
        return r;
      }
    }
    return null;
  }

  CloudWritingResult? get finalResult {
    final task = detail;
    if (task?.state != 'complete') {
      return null;
    }
    for (final r in results) {
      if (r.resultId == task!.parent['final_result_id']) {
        r.verifyFinal(task);
        return r;
      }
    }
    return null;
  }

  Future<CloudPublicationReceipt> saveToConversation() async {
    _check();
    final receipt = localReceipt, result = finalResult, task = detail;
    if (receipt == null || result == null || task == null) {
      throw StateError('该成果没有可信本地来源');
    }
    final saved = await dao.publish(api.scope, receipt, task, result);
    _check();
    notice = saved.deleted ? '成果曾保存后已删除，不会恢复' : '成果已追加到原对话';
    _changed();
    return saved;
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    ++_generation;
    _poll?.cancel();
    api.close();
    super.dispose();
  }
}
