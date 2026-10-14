import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_tool_loop.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:flutter/foundation.dart';

typedef WorkflowServiceResolver = Future<ChatService> Function(
    WorkflowModelProfile profile);

class WorkflowConfigurationMissing implements Exception {
  const WorkflowConfigurationMissing();
}

class _BudgetStopped implements Exception {}

class _ReviewRejected implements Exception {}

/// 三个节点使用独立上下文和请求；该协调器借用唯一通道，不创建另一个executor。
/// 首期基础入口为纯文本、零自动重试；工具断点/权限接口供后续页面接线复用。
class AgentWorkflowRunner extends ChangeNotifier {
  final AgentWorkflowDao dao;
  final AgentWorkflowScope scope;
  final WorkflowServiceResolver serviceForProfile;
  final Future<bool> Function(WorkflowModelProfile) profileAvailable;
  final bool Function() foreground;
  final AgentBackgroundExecution background;
  final AgentExecutionChannel channel;
  final bool backgroundEnabled;
  final AgentWorkspaceTools? workspaceTools;
  final double? Function(WorkflowModelProfile, int, int)? priceEstimate;
  AgentWorkflow workflow;
  List<WorkflowStep> nodes = const [];
  final Completer<void> _abort = Completer<void>();
  Future<void> _writes = Future<void>.value();
  Future<void>? _started;
  final _channelOwner = AgentExecutionOwner();
  String? _runId, _attemptId, _claimedLease;
  Timer? _deadline;
  bool _stopped = false;
  bool _configurationMissing = false;
  String stage = '准备协作';
  String? backgroundNotice;
  String? admissionNotice;
  AgentWorkflowRunner(
      {required this.dao,
      required this.scope,
      required this.workflow,
      required this.serviceForProfile,
      required this.profileAvailable,
      required this.foreground,
      required this.background,
      this.backgroundEnabled = true,
      this.workspaceTools,
      this.priceEstimate,
      AgentExecutionChannel? channel})
      : channel = channel ?? AgentExecutionChannel.instance;

  bool get hasBackgroundLease => _runId != null && background.isActive(_runId!);
  bool get canDispatch =>
      !_stopped &&
      scope.isCurrent &&
      channel.accountAvailable(scope.accountHash) &&
      workflow.state == WorkflowState.running &&
      (foreground() || hasBackgroundLease);
  WorkflowFence get _fence => WorkflowFence.of(workflow);
  void _guard() {
    scope.verify();
    if (!canDispatch) throw const WorkflowStale('已停止或后台许可失效');
  }

  Future<T> _write<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _refresh() async {
    if (!scope.identityCurrent) return;
    final loaded = await dao.steps(workflow.id);
    if (!scope.identityCurrent) return;
    nodes = List.unmodifiable(loaded);
    notifyListeners();
    // 完成计数来自已保存节点；职责阶段为固定白名单，不把任务/模型正文写通知。
    if (hasBackgroundLease && scope.identityCurrent) {
      await background.update(
          runId: _runId!,
          completed:
              nodes.where((n) => n.state == WorkflowState.complete).length,
          total: WorkflowRole.values.length,
          status:
              workflow.state == WorkflowState.running ? stage : _nativeState);
    }
  }

  String get _nativeState => switch (workflow.state) {
        WorkflowState.complete => '协作节点已完成',
        WorkflowState.budgetExhausted => '预算已用尽',
        WorkflowState.needsConfiguration => '需要模型配置',
        WorkflowState.cancelled => '任务已取消',
        _ => '任务已暂停',
      };

  Future<void> start() => _started ??= channel
          .run<void>(
              accountHash: scope.accountHash,
              cid: workflow.cid,
              owner: _channelOwner,
              storageKey: dao.storage.db,
              registryStop: (reason) async {
                await pause(reason);
                await settled;
              },
              action: _execute,
              pause: pause,
              canContinueInBackground: () => hasBackgroundLease)
          .catchError((Object error) {
        if (error is! AgentQueueCancelled) throw error;
      });

  Future<void> get settled => _started ?? Future<void>.value();

  Future<void> pause(String reason) async {
    if (_stopped) return;
    final ownsTicket =
        channel.owns(scope.accountHash, workflow.cid, _channelOwner);
    channel.cancelQueued(scope.accountHash, workflow.cid, owner: _channelOwner);
    final current = scope.isCurrent;
    final control = current ? scope.fork() : null;
    _stopped = true;
    scope.cancel();
    if (!_abort.isCompleted) _abort.complete();
    if (control != null) {
      try {
        await _write(() async {
          final live = await dao.read(workflow.id);
          if (live != null &&
              (_claimedLease != null
                  ? live.leaseId == _claimedLease
                  : ownsTicket &&
                      live.state == WorkflowState.queued &&
                      live.revision == workflow.revision) &&
              live.state != WorkflowState.complete &&
              live.state != WorkflowState.cancelled) {
            workflow =
                await dao.stop(control, live.id, live.revision, reason: reason);
          }
        });
      } on WorkflowStale {
        // 账号/恢复/删除已撤销运行，不能用旧结果写回。
      }
    }
    await _refresh();
  }

  Future<void> _execute() async {
    try {
      scope.verify();
      if (_stopped || !foreground()) {
        await pause('排队期间应用进入后台，请回前台明确继续');
        return;
      }
      workflow = await dao.claim(scope, workflow.id, workflow.revision);
      _claimedLease = workflow.leaseId;
      _guard();
      if (backgroundEnabled) {
        _runId = 'workflow_${workflow.id}_${workflow.leaseId}';
        final result = await Future.any([
          background.start(
              runId: _runId!,
              cid: workflow.cid,
              title: '多Agent协作任务',
              onInterrupted: (reason) => pause('系统停止后台执行：$reason，可明确继续')),
          _abort.future.then((_) => const AgentBackgroundStartResult(
              active: false, reason: 'cancelled')),
        ]);
        backgroundNotice =
            result.active ? '本机后台继续已获准，系统仍可中断' : '后台许可未获准；前台可执行，进入后台会暂停';
      }
      _guard();
      final remaining = workflow.deadlineAt! - dao.now();
      if (remaining > 0) {
        _deadline = Timer(Duration(milliseconds: remaining),
            () => unawaited(pause('任务时限已到，需明确追加预算')));
      }
      await _refresh();
      final tools = workspaceTools;
      if (tools != null) {
        final userAt = await dao.sourceCreatedAt(scope, workflow.id);
        _guard();
        await tools.beginTurn(
            userAt, workflow.inputs.map((i) => i.fileId).toList(),
            resume: true,
            criteriaOverride:
                TaskAcceptanceCriteria.fromJson(workflow.acceptance),
            executionGuard: () => canDispatch,
            transactionGuard: (tx) => dao.verifyTransaction(scope, _fence, tx),
            stableOperation: (action) => scope.stable(action));
        _guard();
      }
      final analysis =
          nodes.singleWhere((n) => n.role == WorkflowRole.analysis);
      if (analysis.state != WorkflowState.complete) await _dispatch(analysis);
      await _refresh();
      var writer = nodes.singleWhere((n) => n.role == WorkflowRole.writing);
      if (writer.state != WorkflowState.complete) await _dispatch(writer);
      await _refresh();
      var reviewer = nodes.singleWhere((n) => n.role == WorkflowRole.review);
      writer = nodes.singleWhere((n) => n.role == WorkflowRole.writing);
      if (reviewer.state != WorkflowState.complete ||
          (writer.cycles == 2 && reviewer.cycles == 1)) {
        await _dispatch(reviewer,
            repeatReview: reviewer.state == WorkflowState.complete);
      }
      await _refresh();
      reviewer = nodes.singleWhere((n) => n.role == WorkflowRole.review);
      var verdict = _review(reviewer.result);
      var objective = await _verify();
      if ((verdict['decision'] == 'revise' ||
              objective != null &&
                  objective.checks.any((c) =>
                      !c.passed &&
                      (c.label.startsWith('全文阅读') ||
                          c.label.startsWith('PDF 文字覆盖')))) &&
          workflow.reworks == 0) {
        await _dispatch(
            nodes.singleWhere((n) => n.role == WorkflowRole.writing),
            rework: true,
            feedback:
                '${verdict['feedback']}\n${objective == null ? '' : objective.checks.where((c) => !c.passed).map((c) => '${c.label}：${c.detail}').join('\n')}');
        await _refresh();
        await _dispatch(nodes.singleWhere((n) => n.role == WorkflowRole.review),
            repeatReview: true);
        await _refresh();
        verdict = _review(
            nodes.singleWhere((n) => n.role == WorkflowRole.review).result);
        objective = await _verify();
      }
      if (verdict['decision'] == 'revise') {
        await pause('模型审阅仍建议修改；一次自动返工额度已用完');
        return;
      }
      if (objective != null && !objective.isPassed) {
        workflow = await _write(() => dao.stop(
            scope, workflow.id, workflow.revision,
            state: WorkflowState.waitingConfirmation,
            reason: '模型审阅已完成，客观文件检查未通过；需要处理输入或明确确认保存成果后重新验收'));
        await _refresh();
        return;
      }
      _guard();
      workflow = await _write(() => dao.complete(scope, _fence));
      await _refresh();
    } on _BudgetStopped {
      // 预算耗尽已经在发送前事务保存，不能改成成功或退还预算。
      notifyListeners();
    } on _ReviewRejected {
      // 已知的格式失败已落盘；只有用户明确继续才重试审阅节点。
      notifyListeners();
    } catch (error) {
      if (_claimedLease == null && error is WorkflowStale) {
        admissionNotice = error.reason;
      }
      // 网络适配器会将发送钩子的异常包装成传输错误；以已保存的预算状态为准。
      if (workflow.state == WorkflowState.budgetExhausted) {
        await _refresh();
        return;
      }
      if (!_stopped && scope.isCurrent) {
        if (_attemptId != null && workflow.state == WorkflowState.running) {
          try {
            final unsent = error is ChatTransportException &&
                error.unsentReason == ChatUnsentReason.configurationRevoked;
            final definite = unsent ||
                error is ChatTransportException &&
                    error.statusCode != null &&
                    !error.responseStarted;
            workflow = await _write(() => dao.finishAttempt(
                scope, _fence, _attemptId!,
                state: definite
                    ? WorkflowAttemptState.failed
                    : WorkflowAttemptState.unknown,
                promptTokens: unsent ? 0 : null,
                completionTokens: unsent ? 0 : null,
                estimatedCost: unsent ? 0 : null,
                reason: unsent
                    ? '配置已撤销，明确未发送；预留预算仍已扣用'
                    : definite
                        ? '请求失败，预算已扣用'
                        : '请求或结果不明，不能自动重放'));
            _attemptId = null;
            if (unsent) {
              workflow = await dao.stop(scope, workflow.id, workflow.revision,
                  state: WorkflowState.needsConfiguration,
                  reason: '配置已撤销，明确未发送；恢复配置后需明确继续');
            }
          } on WorkflowStale {
            // 行或运行代次已变化，丢弃迟到结果。
            await pause('任务来源或运行状态已变化，迟到结果未保存');
          }
        } else if (workflow.state == WorkflowState.running &&
            (error is WorkflowConfigurationMissing || _configurationMissing)) {
          workflow = await dao.stop(scope, workflow.id, workflow.revision,
              state: WorkflowState.needsConfiguration,
              reason: '原模型配置不可用，请重新配置；未自动替换模型');
        } else {
          await pause(
              error is WorkflowStale ? error.reason : '节点执行未完成，需要明确处理后继续');
        }
      }
      await _refresh();
    } finally {
      _deadline?.cancel();
      if (_runId != null) {
        await background.stop(
            runId: _runId!, success: workflow.state == WorkflowState.complete);
      }
    }
  }

  Future<AgentTaskVerificationReport?> _verify() async {
    if (workspaceTools == null) return null;
    _guard();
    final report = await workspaceTools!.verify(canCommit: () => canDispatch);
    _guard();
    workflow = await _write(() => dao.saveVerification(scope, _fence, report));
    return report;
  }

  static Map<String, dynamic> _review(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map ||
        decoded.length != 2 ||
        !const ['accept', 'revise'].contains(decoded['decision']) ||
        decoded['feedback'] is! String ||
        (decoded['feedback'] as String).length > 2000) {
      throw const FormatException('模型审阅格式不完整；仅为模型意见，不能作为客观验收');
    }
    return decoded.cast<String, dynamic>();
  }

  static String _instructions(WorkflowRole role) => switch (role) {
        WorkflowRole.analysis =>
          '职责：分析本次用户任务与明确选中的输入，给出有界方案。不要读取其它对话、记忆或角色卡资料。',
        WorkflowRole.writing => '职责：根据本次任务、已提交分析和选中输入撰写结果。中间结果不是发布或覆盖文件的授权。',
        WorkflowRole.review =>
          '职责：审阅本次任务与已提交稿件。仅输出JSON对象：{"decision":"accept或revise","feedback":"简短修改意见"}。结论只是模型意见，不代表文件/客观条件验收通过。',
      };
  Future<void> _dispatch(WorkflowStep node,
      {bool rework = false,
      bool repeatReview = false,
      String feedback = ''}) async {
    _guard();
    if (!await profileAvailable(node.profile)) {
      throw const WorkflowConfigurationMissing();
    }
    _guard();
    final inputs = await dao.inputTexts(scope, _fence);
    final payload = jsonEncode({
      'task': workflow.task,
      'confirmedAcceptance': workflow.acceptance,
      'acceptanceBoundary': '验收条件不授予新权限；成果文件需用户在前台确认保存，模型审阅不代替客观检查。',
      'selectedInputs': [
        for (var i = 0; i < inputs.length; i++)
          {'reference': workflow.inputs[i].toJson(), 'text': inputs[i]}
      ],
      'committedResults': {
        for (final previous in nodes)
          if (previous.state == WorkflowState.complete &&
              previous.role != node.role)
            previous.role.name: previous.result
      },
      if (feedback.isNotEmpty) 'reviewFeedback': feedback,
    });
    final system =
        CompletionDao.injectSystemPrompt([], _instructions(node.role))
            .single['content'] as String;
    final plan = const ChatContextPlanner().plan(
        history: [],
        systemPrompt: system,
        prompt: payload,
        policy: const ChatContextPolicy(inputBudgetTokens: 12000),
        maxOutputTokens: WorkflowBudget.outputTokens);
    if (!plan.canSend) throw ChatContextBudgetException(plan);
    workflow = await _write(() => dao.beginStep(scope, _fence, node.id,
        inputHash: workflowHash(payload),
        rework: rework,
        repeatReview: repeatReview));
    stage = switch (node.role) {
      WorkflowRole.analysis => '分析任务',
      WorkflowRole.writing => rework ? '修改稿件' : '撰写稿件',
      WorkflowRole.review => '审阅稿件',
    };
    await _refresh();
    final service = await serviceForProfile(node.profile);
    _guard();
    final previousOutput = (await dao.attemptHistory(workflow.id))
        .where((a) => a['stepId'] == node.id)
        .fold<int>(0, (n, a) => n + (a['result'] as String? ?? '').length);
    if (previousOutput >= WorkflowBudget.outputCharacters) {
      await pause('节点输出额度已用完；已保存结果，请缩小范围后新建任务');
      return;
    }
    if (service is! AttemptAwareChatService ||
        service is! OptionsAwareNonStreamingChatService) {
      throw const WorkflowConfigurationMissing();
    }
    final options = ChatRequestOptions(
        maxAutoRetries: 0,
        maxOutputTokensOverride: WorkflowBudget.outputTokens,
        abortTrigger: _abort.future,
        dispatchIsCurrent: () => canDispatch,
        beforeDispatch: (messages) async {
          _guard();
          if (ChatContextPlanner.estimateMessages(messages) > 12000) {
            throw const FormatException('节点单次输入超过12000估算Token');
          }
          if (!await profileAvailable(node.profile)) {
            _configurationMissing = true;
            throw const WorkflowConfigurationMissing();
          }
          await _write(() async {
            _guard();
            final reservation = await dao.reserveDispatch(
                scope, _fence, node.id,
                inputHash: workflowHash(jsonEncode(messages)),
                estimatedInput: ChatContextPlanner.estimateMessages(messages));
            workflow = reservation.workflow;
            if (!reservation.allowed) throw _BudgetStopped();
            _attemptId = reservation.attemptId;
            _guard();
          });
        });
    final useTools = workspaceTools != null &&
        node.tools.isNotEmpty &&
        service.capabilities.tool;
    final Future<ChatCompletionResult> request;
    if (useTools) {
      if (service is! OptionsAwareChatService) {
        throw const WorkflowConfigurationMissing();
      }
      final liveNode =
          (await dao.steps(workflow.id)).singleWhere((s) => s.id == node.id);
      final userAt = await dao.sourceCreatedAt(scope, workflow.id);
      _guard();
      request = WorkflowToolLoop(
          cid: workflow.cid,
          userCreatedAt: userAt,
          node: liveNode,
          inputs: workflow.inputs,
          workspace: workspaceTools!,
          service: service,
          usedOutputCharacters: previousOutput,
          options: options,
          guard: _guard,
          verifyTool: (name, id) => verifyTool(node.id, name, fileId: id),
          checkpoint: (value, rounds) =>
              saveCheckpoint(node.id, value, toolRounds: rounds),
          finishToolRequest: (result) async {
            _guard();
            if (_attemptId == null) throw const WorkflowStale('请求未预留预算');
            workflow = await _write(() => dao.finishAttempt(
                scope, _fence, _attemptId!,
                state: WorkflowAttemptState.succeeded,
                result: result.content ?? '',
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens,
                estimatedCost: result.promptTokens == null ||
                        result.completionTokens == null
                    ? null
                    : priceEstimate?.call(node.profile, result.promptTokens!,
                        result.completionTokens!),
                completesStep: false));
            _attemptId = null;
          }).run(payload, plan.history);
    } else {
      request = service.chatWithUsageWithOptions(
          prompt: payload, history: plan.history, options: options);
    }
    final result = await Future.any<ChatCompletionResult>(
        [request, _abort.future.then((_) => throw const WorkflowStale('已停止'))]);
    _guard();
    if (_attemptId == null) throw const WorkflowStale('传输未执行预算预留，拒绝接纳结果');
    final content = result.content ?? '';
    if (!useTools &&
        previousOutput + content.length > WorkflowBudget.outputCharacters) {
      workflow = await _write(() => dao.finishAttempt(
          scope, _fence, _attemptId!,
          state: WorkflowAttemptState.failed,
          result: content.substring(
              0, WorkflowBudget.outputCharacters - previousOutput),
          promptTokens: result.promptTokens,
          completionTokens: result.completionTokens,
          reason: '节点累计输出超过12000字符，截取部分仅保留为失败证据，未完成节点'));
      _attemptId = null;
      await _refresh();
      throw _ReviewRejected();
    }
    if ((content.isEmpty && node.role != WorkflowRole.review) ||
        content.length > WorkflowBudget.outputCharacters) {
      throw const FormatException('节点结果为空或超过12000字符');
    }
    final cost = result.promptTokens != null && result.completionTokens != null
        ? priceEstimate?.call(
            node.profile, result.promptTokens!, result.completionTokens!)
        : null;
    if (node.role == WorkflowRole.review) {
      try {
        _review(content);
      } on FormatException {
        workflow = await _write(() => dao.finishAttempt(
            scope, _fence, _attemptId!,
            state: WorkflowAttemptState.failed,
            result: content,
            promptTokens: result.promptTokens,
            completionTokens: result.completionTokens,
            estimatedCost: cost,
            reason: '审阅结果格式无效，原始结果和已用预算已保留；明确继续可重试审阅'));
        _attemptId = null;
        await _refresh();
        throw _ReviewRejected();
      }
    }
    workflow = await _write(() => dao.finishAttempt(scope, _fence, _attemptId!,
        state: WorkflowAttemptState.succeeded,
        result: content,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        estimatedCost: cost));
    _attemptId = null;
    await _refresh();
  }

  /// 当前节点工具只能读取用户批准的工作区输入，不授予历史/MCP/网络/写操作。
  Future<void> verifyTool(String stepId, String name, {int? fileId}) async {
    _guard();
    await dao.verifyCurrent(scope, _fence);
    final node =
        (await dao.steps(workflow.id)).singleWhere((n) => n.id == stepId);
    if (node.state != WorkflowState.running ||
        !AgentWorkflowDao.readOnlyTools.contains(name) ||
        !node.tools.contains(name) ||
        (name != 'list_files' &&
            !workflow.inputs.any((f) => f.fileId == fileId))) {
      throw const WorkflowStale('工具未获当前节点/输入范围授权');
    }
    _guard();
  }

  Future<void> saveCheckpoint(String stepId, Map<String, dynamic> value,
      {required int toolRounds}) async {
    _guard();
    workflow = await _write(() =>
        dao.checkpoint(scope, _fence, stepId, value, toolRounds: toolRounds));
    _guard();
  }
}
