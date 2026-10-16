import 'dart:async';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:flutter/foundation.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 只持运行对象的注册表；调度仍委托唯一 channel，与原单Agent共用许可。
class AgentWorkflowCoordinator extends ChangeNotifier {
  static final instance = AgentWorkflowCoordinator();
  final AgentExecutionChannel channel;
  final AgentBackgroundExecution background;
  final bool Function() foreground;
  final WorkflowServiceResolver? serviceForProfile;
  final Future<bool> Function(WorkflowModelProfile)? profileAvailable;
  final AgentWorkflowModels Function(AgentWorkflowScope)? modelsFactory;
  final _runs = <String, AgentWorkflowRunner>{};
  final _busy = <String>{};
  final _scopes = <String, AgentWorkflowScope>{};
  final _preparing = <String>{};
  final notices = <String, String>{};
  final _messageRevisions = <String, int>{};
  final _publishedRows = <String, int>{};
  int messageRevision(String account, int cid) =>
      _messageRevisions['$account:$cid'] ?? 0;
  AgentWorkflowCoordinator(
      {AgentExecutionChannel? channel,
      AgentBackgroundExecution? background,
      bool Function()? foreground,
      bool observeApplication = true,
      this.serviceForProfile,
      this.profileAvailable,
      this.modelsFactory})
      : channel = channel ?? AgentExecutionChannel.instance,
        background = background ?? PlatformAgentBackgroundExecution.instance,
        foreground =
            foreground ?? (() => AgentTaskExecutor.instance.foreground) {
    if (observeApplication) {
      // 同账号重新登录也撤销旧运行；此 hook 处于 SDK 受控短账号许可内。
      LoginDao.addLoginReadyHook(_identityChanged);
    }
  }

  Future<void> _identityChanged() async {
    final ids = _busy.toList();
    for (final id in ids) {
      final runner = _runs[id];
      if (runner != null) await runner.pause('登录身份已变化，旧协作任务已停止');
      _scopes[id]?.cancel();
    }
    for (final id in ids) {
      await _runs[id]?.settled.timeout(const Duration(seconds: 5));
    }
  }

  static String key(String account, String parentId) => '$account:$parentId';
  AgentWorkflowRunner? lookup(String account, String id) =>
      _runs[key(account, id)];
  bool busy(String account, String id) => _busy.contains(key(account, id));
  Future<void> start(
      AgentWorkflowDao dao, AgentWorkflowScope pageScope, AgentWorkflow task,
      {AgentWorkflowModels? preparedModels}) async {
    pageScope.verify();
    if (!foreground()) throw const WorkflowStale('请回前台明确继续');
    if (!channel.accountAvailable(pageScope.accountHash)) {
      throw const WorkflowStale('账号正在停止任务，请稍后明确开始');
    }
    final id = key(pageScope.accountHash, task.id);
    if (_busy.contains(id)) throw const WorkflowStale('任务正在运行');
    _busy.add(id);
    notices.remove(id);
    notifyListeners();
    final scope = preparedModels?.scope ?? pageScope.fork();
    if (scope.accountHash != pageScope.accountHash ||
        scope.loginEpoch != pageScope.loginEpoch ||
        scope.restoreRevision != pageScope.restoreRevision) {
      _busy.remove(id);
      throw const WorkflowStale();
    }
    final models = preparedModels ??
        modelsFactory?.call(scope) ??
        AgentWorkflowModels(scope);
    models.captureExecutionContext();
    _scopes[id] = scope;
    _preparing.add(id);
    AgentWorkflowRunner? runner;
    try {
      final admission = await dao.steps(task.id);
      scope.verify();
      final hasBackend = admission.any((s) => s.profile.mode == 'backend');
      // 先完成全父任务准备；任何一个失效都不能先领取或先发分析节点。
      if (hasBackend) await models.prepareWorkflow(admission);
      models.verifyOriginalScope();
      final runDao = dao.forExecution(
          guard: models.verifyOriginalScope,
          verifyProfile: models.verifyRunProfile);
      final stopDao = dao.forExecution(guard: models.verifyIdentityForControl);
      final workspace =
          await AgentWorkspaceService.create(dao.storage, cid: task.cid);
      models.verifyOriginalScope();
      final tools = await AgentWorkspaceTools.create(dao.storage,
          cid: task.cid, workspace: workspace);
      models.verifyOriginalScope();
      runner = AgentWorkflowRunner(
          dao: runDao,
          controlDao: stopDao,
          admissionSteps: admission,
          executionGuard: models.verifyOriginalScope,
          scope: scope,
          workflow: task,
          serviceForProfile: hasBackend
              ? models.serviceForRun
              : serviceForProfile ?? models.service,
          profileAvailable: hasBackend
              ? models.availableForRun
              : profileAvailable ?? models.available,
          foreground: foreground,
          background: background,
          backgroundEnabled: task.backgroundEnabled,
          priceEstimate: models.estimateCost,
          workspaceTools: tools,
          channel: channel);
      _preparing.remove(id);
      _runs[id] = runner;
      runner.addListener(notifyListeners);
      await runner.start();
      if (pageScope.identityCurrent &&
          models.originalIdentityCurrent &&
          runner.admissionNotice != null) {
        notices[id] = runner.admissionNotice!;
      }
      if (models.originalScopeCurrent &&
          runner.workflow.state == WorkflowState.complete) {
        await publishReply(runDao, scope, runner.workflow);
      }
    } catch (error) {
      if (pageScope.identityCurrent && models.originalIdentityCurrent) {
        notices[id] = error is WorkflowStale
            ? error.reason
            : error is WorkflowConfigurationMissing ||
                    error is ChatTransportException &&
                        error.failureKind ==
                            ChatFailureKind.invalidConfiguration
                ? '原模型配置不可用，请重新配置；未自动替换模型或重放请求'
                : '执行或成果发布未完成，请刷新后处理；未自动重试请求';
      }
    } finally {
      if (runner != null) runner.removeListener(notifyListeners);
      _busy.remove(id);
      _scopes.remove(id);
      _preparing.remove(id);
      notifyListeners();
    }
  }

  Future<void> publishReply(AgentWorkflowDao dao, AgentWorkflowScope scope,
      AgentWorkflow task) async {
    final rowId = await dao.publishReplyOnce(scope, task.id, task.revision,
        createdAt: DateTime.now().microsecondsSinceEpoch ~/ 1000);
    scope.verify();
    final parent = key(scope.accountHash, task.id);
    if (_publishedRows[parent] == rowId) return;
    _publishedRows[parent] = rowId;
    _messageRevisions.update('${scope.accountHash}:${task.cid}', (v) => v + 1,
        ifAbsent: () => 1);
    notifyListeners();
  }

  Future<void> stop(
      AgentWorkflowDao dao, AgentWorkflowScope scope, AgentWorkflow task,
      {bool cancel = false}) async {
    scope.verify();
    final before = await dao.read(task.id);
    scope.verify();
    if (before == null ||
        before.toRow()['sourceId'] != task.toRow()['sourceId']) {
      throw const WorkflowStale();
    }
    if (before.state == WorkflowState.complete ||
        before.state == WorkflowState.cancelled) {
      return;
    }
    final runner = lookup(scope.accountHash, task.id);
    if (runner != null && busy(scope.accountHash, task.id)) {
      await runner.pause('用户停止了协作任务');
    }
    scope.verify();
    final current = await dao.read(task.id);
    scope.verify();
    if (current == null) throw const WorkflowStale();
    if (current.state == WorkflowState.complete ||
        current.state == WorkflowState.cancelled) {
      return;
    }
    await dao.stop(scope, current.id, current.revision,
        state: cancel ? WorkflowState.cancelled : WorkflowState.paused,
        reason: cancel ? '用户取消了任务' : '已停止，不再发请求；可明确继续');
  }

  Future<AgentWorkflow> recover(AgentWorkflowDao dao, AgentWorkflowScope scope,
      AgentWorkflow task) async {
    scope.verify();
    if (busy(scope.accountHash, task.id)) {
      return lookup(scope.accountHash, task.id)?.workflow ?? task;
    }
    return dao.recoverInterrupted(scope, task);
  }

  Future<void> stopAll(AgentWorkflowScope scope) async {
    scope.verify();
    channel.holdAccount(scope.accountHash);
    try {
      // _runs 可保留旧代次；准备状态只按当前 _scopes / _preparing 判断。
      // 已注册运行保留原 channel.pause 路径，不能提前 cancel 使它漏存暂停。
      for (final entry in _scopes.entries.toList()) {
        final preparing = entry.value;
        if (_preparing.contains(entry.key) &&
            preparing.accountHash == scope.accountHash &&
            preparing.loginEpoch == scope.loginEpoch &&
            preparing.restoreRevision == scope.restoreRevision &&
            preparing.isCurrent) {
          preparing.cancel();
        }
      }
      await channel.pauseAccount(scope.accountHash, '用户停止了全部本机任务');
    } finally {
      channel.releaseAccount(scope.accountHash);
    }
    scope.verify();
  }
}
