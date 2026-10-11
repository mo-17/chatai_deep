import 'dart:async';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:flutter/widgets.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 身份在提交时固定，页面导航及全局服务商设置不会改变执行中的请求。
class AgentTaskKey {
  final String accountHash;
  final int cid;
  const AgentTaskKey(this.accountHash, this.cid);
  @override
  bool operator ==(Object other) =>
      other is AgentTaskKey &&
      other.accountHash == accountHash &&
      other.cid == cid;
  @override
  int get hashCode => Object.hash(accountHash, cid);
}

enum AgentRunPhase { queued, running, paused, complete }

typedef AgentConfirmation = Future<bool> Function(String title, String detail);

/// 只接收已经保存的用户轮次和独立服务对象，绝不持有页面 State 或 Context。
class PreparedAgentRun {
  final AgentTaskKey key;
  final ConversationModel conversation;
  final MessageModel user;
  final MessageModel receiver;
  final AISettings settings;
  final CompletionDao completion;
  final MessageDao messages;
  final UsageRecordService usage;
  final AgentTaskSession session;
  final AgentWorkspaceService workspace;
  final AgentWorkspaceTools workspaceTools;
  final ChatAttachments attachments;
  final ToolRegistry? tools;
  final bool webSearch;
  final bool hasAssistant;
  final AgentBackgroundExecution background;

  PreparedAgentRun(
      {required this.key,
      required ConversationModel conversation,
      required this.user,
      required this.receiver,
      required AISettings settings,
      required this.completion,
      required this.messages,
      required this.usage,
      required this.session,
      required this.workspace,
      required this.workspaceTools,
      required this.attachments,
      required this.background,
      this.tools,
      this.webSearch = false,
      this.hasAssistant = false})
      : conversation = ConversationModel.fromJson(conversation.toJson()),
        settings = AISettings.fromJson(settings.toJson());
}

class AgentTaskRun extends ChangeNotifier {
  final PreparedAgentRun prepared;
  final ChatBlockStore blocks = ChatBlockStore();
  final Completer<void> _abort = Completer<void>();
  final Completer<void> _finished = Completer<void>();
  AgentRunPhase phase = AgentRunPhase.queued;
  ChatSendProgress? progress;
  ChatContextPlan? contextPlan;
  MessageModel? reply;

  /// 仅真实回复事务成功后设置，页面不能用显示快照伪造落盘绑定。
  int? persistedReplyRowId;
  String? backgroundNotice;
  String? pauseReason;
  ChatFailureDiagnosis? _failureDiagnosis;
  bool _cancelled = false;
  bool _retired = false;
  Future<void>? _queuedCancellation;
  bool get isRetired => _retired;
  bool _confirming = false;
  StreamDispatcher? _dispatcher;
  Completer<void>? _streamDone;
  StreamSubscription<StreamEvent>? _subscription;
  Timer? _notificationTimer;
  String? _nativeRunId;
  int _promptTokens = 0, _cachedTokens = 0, _completionTokens = 0;
  bool _hasUsage = false;

  AgentTaskRun(this.prepared);
  AgentTaskKey get key => prepared.key;
  bool get busy =>
      phase == AgentRunPhase.queued || phase == AgentRunPhase.running;
  bool get queued => phase == AgentRunPhase.queued;
  bool get awaitingApproval => _confirming;
  Future<void> get finished => _finished.future;
  String get messageKey => chatMessageKey(prepared.receiver.createdAt);
  bool get hasBackgroundLease =>
      _nativeRunId != null && prepared.background.isActive(_nativeRunId!);

  void requestPause(String reason) {
    if (!busy || _cancelled) return;
    _cancelled = true;
    pauseReason = reason;
    _failureDiagnosis = null;
    prepared.session.failureDiagnosis = null;
    _dispatcher?.onStopped();
    if (!_abort.isCompleted) _abort.complete();
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete();
    notifyListeners();
  }

  Future<bool> _conversationExists() async {
    final rows = await prepared.messages.storage.db.query(
        'tb_conversation_list',
        columns: ['cid'],
        where: 'cid = ?',
        whereArgs: [key.cid],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> _pauseSnapshot(String reason,
      {ChatFailureDiagnosis? diagnosis}) async {
    if (!await _conversationExists()) {
      prepared.session.status = 'paused';
      prepared.session.pauseReason = '原对话已删除';
      prepared.session.failureDiagnosis = null;
      return;
    }
    // 排队项持久化为可明确继续的 paused；进程重启不会自动计费发送。
    if (prepared.session.status != 'running') {
      prepared.session.status = 'running';
    }
    await prepared.session.pause(reason, diagnosis: diagnosis);
    await prepared.session.flush();
  }

  Future<void> _cancelQueued(String reason) =>
      _queuedCancellation ??= _settleQueued(reason);

  Future<void> _settleQueued(String reason) async {
    if (_retired) return;
    requestPause(reason);
    try {
      await _pauseSnapshot(reason);
    } catch (_) {
      _checkpointFailed();
    } finally {
      phase = AgentRunPhase.paused;
      if (!_finished.isCompleted) _finished.complete();
      notifyListeners();
    }
  }

  Future<void> _execute(AgentTaskExecutor owner) async {
    if (_cancelled || !owner.accountCurrent(key)) {
      await _cancelQueued(pauseReason ?? '账户已切换，任务已暂停');
      return;
    }
    phase = AgentRunPhase.running;
    progress = const ChatSendProgress('准备请求');
    notifyListeners();
    try {
      if (!await _conversationExists()) {
        requestPause('原对话已删除');
        return;
      }
      await prepared.session.begin(
          userAt: prepared.user.createdAt,
          input: prepared.user.content,
          resume: true);
      if (_cancelled || !owner.accountCurrent(key)) return;
      if (!owner.foreground) {
        requestPause('应用在后台，等待返回前台后明确继续');
        return;
      }
      if (prepared.session.backgroundEnabled) {
        final runId =
            '${key.cid}_${prepared.session.generation}_${DateTime.now().microsecondsSinceEpoch}';
        _nativeRunId = runId;
        final pendingLease = prepared.background.start(
            runId: runId,
            cid: key.cid,
            title: 'Agent 任务',
            onInterrupted: (reason) async {
              requestPause(switch (reason) {
                'userStopped' => '已从系统通知停止，可继续任务',
                'expired' => '系统后台时限已到，可继续任务',
                _ => '系统已停止后台执行，可继续任务',
              });
              await finished.timeout(const Duration(seconds: 2),
                  onTimeout: () {});
            });
        final lease = await Future.any<AgentBackgroundStartResult>([
          pendingLease,
          _abort.future.then((_) => const AgentBackgroundStartResult(
              active: false, reason: 'cancelled')),
        ]);
        backgroundNotice =
            lease.active ? '后台执行已获准，可切换页面或返回桌面' : '后台执行未获准；返回桌面时会保存并暂停';
        if (!owner.foreground && !hasBackgroundLease) {
          requestPause('应用进入后台，任务已暂停');
        }
        if (_cancelled || !owner.accountCurrent(key)) return;
        if (lease.active) {
          _notificationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            final todos = prepared.session.todos;
            unawaited(prepared.background.update(
                runId: runId,
                completed:
                    todos.where((todo) => todo.status == 'completed').length,
                total: todos.length,
                status: progress?.label ?? '执行任务'));
          });
        }
      }
      reply = prepared.receiver;
      final dispatcher = StreamDispatcher(blocks, messageKey,
          modelId: prepared.settings.effectiveModel)
        ..start();
      _dispatcher = dispatcher;
      blocks.addListener(_blocksChanged);
      notifyListeners();
      final done = Completer<void>();
      _streamDone = done;
      _subscription = prepared.completion
          .streamCompletionEvents(
        prompt: prepared.user.content,
        attachments: prepared.attachments.isEmpty ? null : prepared.attachments,
        abortTrigger: _abort.future,
        webSearch: prepared.webSearch,
        tools: prepared.tools,
        task: prepared.session,
        verifyFinal: prepared.workspaceTools.correctionForFinal,
        onProgress: (value) {
          if (_cancelled) return;
          progress = value;
          notifyListeners();
        },
        onContextPlan: (plan) {
          contextPlan = plan;
          notifyListeners();
        },
      )
          .listen((event) {
        if (_cancelled || !owner.accountCurrent(key)) return;
        switch (event.type) {
          case StreamEventType.reasoning:
            dispatcher.onThinkingChunk(event.delta);
          case StreamEventType.text:
            progress = const ChatSendProgress('生成回答');
            dispatcher.onTextChunk(event.delta);
          case StreamEventType.toolCall:
            dispatcher.onToolCall(
                toolId: event.toolId ?? '',
                name: event.toolName,
                args: event.toolArguments);
          case StreamEventType.toolResult:
            dispatcher.onToolResult(
                toolId: event.toolId ?? '', content: event.toolContent);
          case StreamEventType.image:
            dispatcher.onImage(event.imageUrl ?? '');
          case StreamEventType.citation:
            dispatcher.onCitation(event.webResults ?? const [],
                localSources: event.localSources ?? const []);
          case StreamEventType.usage:
            _hasUsage = true;
            _promptTokens += event.promptTokens ?? 0;
            _cachedTokens += event.cachedPromptTokens ?? 0;
            _completionTokens += event.completionTokens ?? 0;
        }
      }, onError: (Object error, StackTrace trace) {
        if (!done.isCompleted) done.completeError(error, trace);
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, cancelOnError: true);
      try {
        await done.future;
        if (!_cancelled) dispatcher.finish();
      } catch (error) {
        if (!_cancelled) {
          final diagnosis = ChatFailureDiagnosis.from(error);
          _failureDiagnosis = diagnosis.code == 'cancelled' ? null : diagnosis;
          pauseReason = _diagnosisText(diagnosis);
          dispatcher.onError(pauseReason!);
        }
      }
      await _cancelSubscription();
      await _persist(dispatcher);
    } catch (error) {
      // 用户轮次已保存，准备阶段失败仍留下明确可继续的任务快照。
      if (!_cancelled) {
        final diagnosis = ChatFailureDiagnosis.from(error);
        _failureDiagnosis = diagnosis.code == 'cancelled' ? null : diagnosis;
        pauseReason = _diagnosisText(diagnosis);
        _cancelled = true;
      }
    } finally {
      if (!_abort.isCompleted) _abort.complete();
      _notificationTimer?.cancel();
      try {
        await _cancelSubscription();
        if (_cancelled) {
          await _pauseSnapshot(pauseReason ?? '任务已暂停',
              diagnosis: _failureDiagnosis);
        }
        if (_dispatcher?.hasError == true && pauseReason != null) {
          await _pauseSnapshot(pauseReason!, diagnosis: _failureDiagnosis);
        }
        await prepared.session.flush();
      } catch (_) {
        _checkpointFailed();
      } finally {
        try {
          final runId = _nativeRunId;
          if (runId != null) {
            await prepared.background.stop(
                runId: runId, success: prepared.session.status == 'complete');
          }
        } catch (_) {
          backgroundNotice = '后台执行已结束，请检查系统通知状态';
        } finally {
          phase = prepared.session.status == 'complete'
              ? AgentRunPhase.complete
              : AgentRunPhase.paused;
          progress = null;
          if (!_finished.isCompleted) _finished.complete();
          notifyListeners();
          AppEvents.notifyConversationsChanged();
        }
      }
    }
  }

  static String _diagnosisText(ChatFailureDiagnosis diagnosis) =>
      '${diagnosis.message}\n${diagnosis.suggestion}\n'
      '${diagnosis.statusCode == null ? '' : 'HTTP ${diagnosis.statusCode} · '}诊断 ${diagnosis.diagnosticReference}';

  void _checkpointFailed() {
    pauseReason = '任务进度保存失败，请检查存储空间后继续';
    prepared.session.status = 'paused';
    prepared.session.pauseReason = pauseReason;
    _failureDiagnosis = null;
    prepared.session.failureDiagnosis = null;
  }

  @override
  void notifyListeners() {
    if (!_retired) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_retired) return;
    _retired = true;
    blocks.removeListener(_blocksChanged);
    blocks.dispose();
    super.dispose();
  }

  Future<void> _cancelSubscription() async {
    final subscription = _subscription;
    _subscription = null;
    if (subscription == null) return;
    // cancel 请求同步解绑监听；不能等待内部 async*（例如 401 正在 await logout），
    // 否则 logout 的保存钩子会与本任务相互等待。迟到事件仍受 _cancelled 限制。
    unawaited(subscription
        .cancel()
        .timeout(const Duration(seconds: 2), onTimeout: () {})
        .catchError((Object _) {}));
  }

  void _blocksChanged() => notifyListeners();

  Future<void> _persist(StreamDispatcher dispatcher) async {
    final snapshot = <MessageBlock>[];
    for (final block in blocks.blocksFor(messageKey)) {
      if (block is PlaceholderBlock) continue;
      if (!block.isActive) {
        snapshot.add(block);
        continue;
      }
      snapshot.add(switch (block) {
        final MainTextBlock b => b.copyWith(status: MessageBlockStatus.success),
        final ThinkingBlock b => b.copyWith(status: MessageBlockStatus.success),
        final CodeBlock b => b.copyWith(status: MessageBlockStatus.success),
        final ToolBlock b => b.copyWith(
            status: _cancelled
                ? MessageBlockStatus.paused
                : MessageBlockStatus.success),
        _ => block,
      });
    }
    final protocol = prepared.completion.lastProtocolMessages;
    if (protocol.isNotEmpty && _protocolBalanced(protocol)) {
      final index = snapshot.indexWhere((block) => block is MainTextBlock);
      if (index >= 0) {
        snapshot[index] = (snapshot[index] as MainTextBlock)
            .copyWith(protocolMessages: protocol);
      } else {
        snapshot.add(MainTextBlock(
            id: 'blk_${messageKey}_protocol',
            messageId: messageKey,
            createdAt: prepared.receiver.createdAt,
            status: MessageBlockStatus.success,
            protocolMessages: protocol));
      }
    }
    final text = dispatcher.mainText;
    if (prepared.hasAssistant && text.trim().isEmpty) {
      final thinking = snapshot
          .whereType<ThinkingBlock>()
          .map((block) => block.content.trim())
          .where((value) => value.isNotEmpty)
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll('<<<', '')
          .replaceAll('>>>', '')
          .trim();
      if (thinking.isNotEmpty) {
        final summary = thinking.characters.length <= 240
            ? thinking
            : '${thinking.characters.take(240)}...';
        snapshot.add(RoleContinuationBlock(
            id: 'blk_${messageKey}_role_continuation',
            messageId: messageKey,
            createdAt: prepared.receiver.createdAt,
            status: MessageBlockStatus.success,
            modelId: prepared.settings.effectiveModel,
            content:
                '${dispatcher.hasError ? '上一轮回复中断，' : '上一轮尚未正式开口，'}角色已形成的心理/动作状态：$summary'));
      }
    }
    final model = prepared.receiver.copyWith(
        content: text.isNotEmpty
            ? text
            : dispatcher.hasError
                ? '请求失败'
                : 'no response');
    final saved = await prepared.messages.storage.db.transaction((txn) async {
      final conversations = await txn.query('tb_conversation_list',
          columns: ['cid'], where: 'cid = ?', whereArgs: [key.cid], limit: 1);
      if (conversations.isEmpty) return null;
      final data = model.toJson()..['cid'] = key.cid;
      if (snapshot.isNotEmpty) {
        data['blocks'] = MessageBlock.encodeList(snapshot);
      }
      final rowId = await txn.insert('tb_messages', data);
      final counts = await txn.rawQuery(
          'select count(*) as n from tb_messages where cid = ?', [key.cid]);
      // 仅更新摘要，不覆盖其他页面刚修改的模型、助手或偏好。
      await txn.update(
          'tb_conversation_list',
          {
            'lastMessage': model.content,
            'updateAt': model.createdAt,
            'messageCount': counts.single['n'],
          },
          where: 'cid = ?',
          whereArgs: [key.cid]);
      return rowId;
    });
    if (saved == null) {
      requestPause('原对话已删除');
      return;
    }
    persistedReplyRowId = saved;
    prepared.completion.appendTurn(prepared.user, model,
        assistantBlocks: snapshot,
        userFileText: prepared.attachments.extraText);
    if (!_cancelled && await _conversationExists()) {
      await prepared.session.finish(
          complete: !dispatcher.hasError &&
              (prepared.workspaceTools.lastReport?.isPassed ?? true),
          requiresCorrection:
              !(prepared.workspaceTools.lastReport?.isPassed ?? true));
    }
    try {
      await prepared.usage.recordTurn(
          modelId: prepared.settings.effectiveModel,
          providerId: prepared.settings.mode == AIMode.local
              ? prepared.settings.activeProviderId
              : prepared.conversation.modelProviderId,
          projectId: prepared.conversation.projectId,
          cid: key.cid,
          prompt: prepared.user.content,
          completion: model.content,
          promptTokens: _hasUsage ? _promptTokens : null,
          cachedPromptTokens: _hasUsage ? _cachedTokens : null,
          completionTokens: _hasUsage ? _completionTokens : null,
          costConfig: prepared.settings.usageCostConfig,
          createdAt: model.createdAt);
    } catch (_) {
      // 回复与任务状态已保存，用量记录失败不能回退已完成任务或重复回复。
    }
    reply = model;
    blocks.seedMessage(messageKey, snapshot);
    blocks.commitSeed();
  }

  static bool _protocolBalanced(List<Map<String, dynamic>> messages) {
    final pending = <String>{};
    for (final message in messages) {
      if (message['role'] == 'assistant') {
        for (final call in (message['tool_calls'] as List? ?? const [])) {
          if (call is Map && call['id'] is String) {
            pending.add(call['id'] as String);
          }
        }
      } else if (message['role'] == 'tool') {
        if (!pending.remove(message['tool_call_id'])) return false;
      }
    }
    return pending.isEmpty;
  }
}

class _ConfirmationHost {
  final Object owner;
  final bool Function() visible;
  final AgentConfirmation confirm;
  final VoidCallback dismiss;
  _ConfirmationHost(this.owner, this.visible, this.confirm, this.dismiss);
}

/// App 级 FIFO；一个执行器只启动一个 HTTP/原生许可，不依赖任何页面存活。
class AgentTaskExecutor extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = AgentTaskExecutor();
  static AgentTaskExecutor ensureInitialized() => instance;
  final String Function() currentAccount;
  final List<AgentTaskRun> _queue = [];
  final Map<AgentTaskKey, AgentTaskRun> _runs = {};
  final Map<AgentTaskKey, _ConfirmationHost> _hosts = {};
  AgentTaskRun? _active;
  bool _draining = false;
  int _stoppingAll = 0;
  final Map<String, int> _maintenanceAccounts = {};
  bool foreground;

  AgentTaskExecutor(
      {String Function()? currentAccount,
      bool observeApplication = true,
      this.foreground = true})
      : currentAccount = currentAccount ?? HiDBManager.getAccountHash {
    if (observeApplication) {
      foreground = WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      WidgetsBinding.instance.addObserver(this);
      LoginDao.addLoginReadyHook(() async {
        final stale = _runs.values
            .where((run) => run.busy && !accountCurrent(run.key))
            .toList();
        for (final run in stale) {
          await cancel(run.key, reason: '账户已切换，任务已暂停');
        }
        _hosts.removeWhere((key, _) => !accountCurrent(key));
      });
    }
  }

  bool accountCurrent(AgentTaskKey key) => key.accountHash == currentAccount();
  AgentTaskRun? lookup(AgentTaskKey key) => _runs[key];
  int queuePosition(AgentTaskKey key) {
    final index = _queue.indexWhere((run) => run.key == key);
    return index < 0 ? 0 : index + 1;
  }

  Future<AgentTaskRun> enqueue(PreparedAgentRun prepared) async {
    if (!accountCurrent(prepared.key)) throw StateError('账户已切换');
    if ((_maintenanceAccounts[prepared.key.accountHash] ?? 0) > 0) {
      throw StateError('正在恢复账户数据，请稍后继续任务');
    }
    if (_runs[prepared.key]?.busy == true) throw StateError('该对话已有任务');
    final previous = _runs.remove(prepared.key);
    if (previous != null) _retire(previous);
    final run = AgentTaskRun(prepared);
    // 在第一个 await 前保留身份，阻止同会话双击形成两个收费请求。
    _runs[run.key] = run;
    // 工具在启动时捕获此运行的许可；停止/替换后，迟到的异步结果不能
    // 越过备份恢复或删除边界写回 SQLite。回调只持有固定运行与执行器。
    prepared.workspaceTools.bindExecutionGuard(() =>
        !run._cancelled &&
        !run._retired &&
        run.phase == AgentRunPhase.running &&
        accountCurrent(run.key) &&
        identical(_runs[run.key], run));
    run.addListener(notifyListeners);
    try {
      await run._pauseSnapshot('等待执行，前方任务完成后开始');
      if (run.isRetired || !identical(_runs[run.key], run)) return run;
      if (_stoppingAll > 0 ||
          (_maintenanceAccounts[run.key.accountHash] ?? 0) > 0 ||
          !accountCurrent(run.key) ||
          run._cancelled) {
        await run._cancelQueued('账户已切换或排队已取消，可继续任务');
      } else {
        _queue.add(run);
      }
    } catch (_) {
      run._checkpointFailed();
      run.phase = AgentRunPhase.paused;
      if (!run._finished.isCompleted) run._finished.complete();
    }
    notifyListeners();
    unawaited(_drain());
    return run;
  }

  void _retire(AgentTaskRun run) {
    run.removeListener(notifyListeners);
    run.dispose();
  }

  void _trimTerminalRuns() {
    final terminal = _runs.values.where((run) => !run.busy).toList();
    // 当前页面有自己的块快照，历史详情随时可从 SQLite 重载。
    for (final run
        in terminal.take((terminal.length - 6).clamp(0, terminal.length))) {
      _runs.remove(run.key);
      _retire(run);
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final run = _queue.removeAt(0);
        if (_stoppingAll > 0 ||
            (_maintenanceAccounts[run.key.accountHash] ?? 0) > 0 ||
            !foreground ||
            !accountCurrent(run.key)) {
          await run
              ._cancelQueued(!foreground ? '应用在后台，等待返回前台后明确继续' : '账户已切换，任务已暂停');
          continue;
        }
        _active = run;
        notifyListeners();
        try {
          await run._execute(this);
        } finally {
          _active = null;
          _trimTerminalRuns();
          notifyListeners();
        }
      }
    } finally {
      _active = null;
      _draining = false;
    }
  }

  Future<void> cancel(AgentTaskKey key, {String reason = '已停止任务，可继续'}) async {
    final run = _runs[key];
    if (run == null || !run.busy) return;
    if (run.queued && !identical(run, _active)) {
      _queue.remove(run);
      await run._cancelQueued(reason);
    } else {
      run.requestPause(reason);
      await run.finished;
    }
    notifyListeners();
  }

  /// 覆盖式恢复等操作持有账户维护许可，期间不得入队或启动网络请求。
  Future<T> runWithTasksPaused<T>(
      String accountHash, String reason, Future<T> Function() action) async {
    _maintenanceAccounts.update(accountHash, (count) => count + 1,
        ifAbsent: () => 1);
    try {
      final keys = _runs.values
          .where((run) => run.key.accountHash == accountHash)
          .map((run) => run.key)
          .toList();
      for (final key in keys) {
        await forget(key, reason: reason);
      }
      return await action();
    } finally {
      final count = (_maintenanceAccounts[accountHash] ?? 1) - 1;
      if (count <= 0) {
        _maintenanceAccounts.remove(accountHash);
      } else {
        _maintenanceAccounts[accountHash] = count;
      }
      notifyListeners();
    }
  }

  /// 用户删除对话时先终止并移除运行身份，迟到工具结果不能重建已删除快照。
  Future<void> forget(AgentTaskKey key,
      {String reason = '原对话即将删除，任务已停止'}) async {
    await cancel(key, reason: reason);
    final run = _runs.remove(key);
    if (run != null) {
      run.prepared.session.generation++;
      _retire(run);
    }
    _hosts.remove(key)?.dismiss();
    notifyListeners();
  }

  Future<void> cancelAll(String reason) async {
    _stoppingAll++;
    try {
      final keys =
          _runs.values.where((run) => run.busy).map((run) => run.key).toList();
      for (final key in keys) {
        await cancel(key, reason: reason);
      }
      _hosts.clear();
      for (final run in _runs.values) {
        run.prepared.session.generation++;
        _retire(run);
      }
      _runs.clear();
      notifyListeners();
    } finally {
      _stoppingAll--;
    }
  }

  void bindConfirmation(AgentTaskKey key, Object owner,
      {required bool Function() visible,
      required AgentConfirmation confirm,
      required VoidCallback dismiss}) {
    _hosts[key] = _ConfirmationHost(owner, visible, confirm, dismiss);
  }

  void unbindConfirmation(AgentTaskKey key, Object owner) {
    if (identical(_hosts[key]?.owner, owner)) {
      final host = _hosts.remove(key);
      host?.dismiss();
      final run = _runs[key];
      if (run?._confirming == true) run!.requestPause('操作需要确认，请返回原对话后继续');
    }
  }

  Future<bool> confirm(AgentTaskKey key, String title, String detail) async {
    final run = _runs[key];
    final host = _hosts[key];
    if (run == null ||
        !run.busy ||
        !foreground ||
        !accountCurrent(key) ||
        host == null ||
        !host.visible()) {
      run?.requestPause('操作需要确认，请返回原对话后继续');
      return false;
    }
    run._confirming = true;
    try {
      final accepted = await Future.any<bool>([
        host.confirm(title, detail),
        run._abort.future.then((_) => false),
      ]);
      return accepted &&
          !run._cancelled &&
          foreground &&
          accountCurrent(key) &&
          identical(_hosts[key], host) &&
          host.visible();
    } finally {
      run._confirming = false;
      if (run._cancelled || !foreground || !accountCurrent(key)) host.dismiss();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      foreground = true;
      return;
    }
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    foreground = false;
    final active = _active;
    if (active != null &&
        (state == AppLifecycleState.detached ||
            active._confirming ||
            !active.hasBackgroundLease)) {
      active.requestPause(
          active._confirming ? '操作需要确认，进入后台后任务已暂停' : '应用进入后台，任务已暂停');
    }
    for (final run in _queue.toList()) {
      unawaited(cancel(run.key, reason: '应用在后台，等待返回前台后明确继续'));
    }
  }
}
