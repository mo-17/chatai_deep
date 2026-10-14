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
  final _runs = <String, AgentWorkflowRunner>{};
  final _busy = <String>{};
  final _scopes = <String, AgentWorkflowScope>{};
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
      this.profileAvailable})
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
  Future<void> start(AgentWorkflowDao dao, AgentWorkflowScope pageScope,
      AgentWorkflow task) async {
    pageScope.verify();
    if (!foreground()) throw const WorkflowStale('请回前台明确继续');
    final id = key(pageScope.accountHash, task.id);
    if (_busy.contains(id)) throw const WorkflowStale('任务正在运行');
    _busy.add(id);
    notices.remove(id);
    notifyListeners();
    final scope = pageScope.fork();
    _scopes[id] = scope;
    AgentWorkflowRunner? runner;
    try {
      final workspace =
          await AgentWorkspaceService.create(dao.storage, cid: task.cid);
      scope.verify();
      final tools = await AgentWorkspaceTools.create(dao.storage,
          cid: task.cid, workspace: workspace);
      scope.verify();
      final models = AgentWorkflowModels(scope);
      runner = AgentWorkflowRunner(
          dao: dao,
          scope: scope,
          workflow: task,
          serviceForProfile: serviceForProfile ?? models.service,
          profileAvailable: profileAvailable ?? models.available,
          foreground: foreground,
          background: background,
          backgroundEnabled: task.backgroundEnabled,
          priceEstimate: models.estimateCost,
          workspaceTools: tools,
          channel: channel);
      _runs[id] = runner;
      runner.addListener(notifyListeners);
      await runner.start();
      if (pageScope.identityCurrent && runner.admissionNotice != null) {
        notices[id] = runner.admissionNotice!;
      }
      if (scope.isCurrent && runner.workflow.state == WorkflowState.complete) {
        await publishReply(dao, scope, runner.workflow);
      }
    } catch (error) {
      if (pageScope.identityCurrent) {
        notices[id] =
            error is WorkflowStale ? error.reason : '执行或成果发布未完成，请刷新后处理；未自动重试请求';
      }
    } finally {
      if (runner != null) runner.removeListener(notifyListeners);
      _busy.remove(id);
      _scopes.remove(id);
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
      await channel.pauseAccount(scope.accountHash, '用户停止了全部本机任务');
    } finally {
      channel.releaseAccount(scope.accountHash);
    }
    scope.verify();
  }
}
