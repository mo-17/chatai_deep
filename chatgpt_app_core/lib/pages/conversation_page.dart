import 'dart:async';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/application/checklist_state_coordinator.dart';

import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_send_guard.dart';
import 'package:chatgpt_app_core/chat/application/assistant_conversation_avatar_resolver.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/user_message_context.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/widget/message_reference_picker.dart';
import 'package:chatgpt_app_core/chat/application/composer_prediction_service.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_detail_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/workspace_attachment_processor.dart';
import 'package:chatgpt_app_core/chat/application/semantic_chat_summary_service.dart';
import 'package:chatgpt_app_core/db/semantic_chat_summary_dao.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_service.dart';
import 'package:chatgpt_app_core/widget/agent_task_panel.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/retry_attachment_restorer.dart';
import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_memory_suggestion_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_state_suggester.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_debug_export.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_context_preview.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/skill/js_runtime_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/pages/personal_memory_page.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:chatgpt_app_core/pages/agent_workspace_page.dart';
import 'package:chatgpt_app_core/pages/agent_task_detail_page.dart';
import 'package:chatgpt_app_core/pages/ai_health_check_page.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/ai_provider_detail_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:chatgpt_app_core/util/scroll_jump.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/ai_readiness_card.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/widget/configured_ai_model_picker_sheet.dart';
import 'package:chatgpt_app_core/widget/forward_sheet.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:chatgpt_app_core/widget/deepseek_reasoning_selector.dart';
import 'package:chatgpt_app_core/widget/chat_send_status_panel.dart';
import 'package:chatgpt_app_core/widget/starcore_message_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';
// ItemScrollController / ItemPositionsListener 经 chat_message 的 chat_controller.dart
// 再导出（见该文件顶部 export），无需直接依赖 scrollable_positioned_list。

typedef OnConversationUpdate = void Function(
    ConversationModel conversationModel);

enum _ConversationModelTestState { idle, running, success, failure }

enum _ConversationMoreAction {
  taskMode,
  workspace,
  outline,
  assistantProfile,
  roleContext,
  roleDebug,
  voicePrefs,
}

class _ReadAloudTriggerMode {
  static const button = 'button';
  static const longPress = 'longPress';
  static const hidden = 'hidden';

  static const all = [button, longPress, hidden];

  static String normalize(String? value) =>
      all.contains(value) ? value! : button;

  static String labelOf(String value) => switch (normalize(value)) {
        button => '显示播放按钮',
        longPress => '长按菜单显示朗读',
        hidden => '隐藏播放按钮',
        _ => '显示播放按钮',
      };
}

///聊天对话框页面
class ConversationPage extends StatefulWidget {
  final ConversationModel conversationModel;
  final OnConversationUpdate? conversationUpdate;
  final String initialPrompt;
  final String initialAssistantOpening;
  final int? initialTargetCreatedAt;
  final bool resumeAgentTask;
  final int? initialAgentTaskGeneration;
  final String? expectedAccountHash;
  final AgentBackgroundExecution? backgroundExecution;
  final ReadAloudService? readAloudService;
  final ComposerPredictionService? predictionService;

  /// 嵌入方或测试可注入传输，默认沿用用户配置。
  final ChatService? chatService;

  /// 测试可延迟真实事务的返回，验证保存与下一轮发送的时序。
  @visibleForTesting
  final ChecklistStateCoordinator? checklistCoordinator;

  @visibleForTesting
  final ConversationDraftStore? draftStore;

  @visibleForTesting
  final ValueChanged<Object>? onSendPreparationError;

  const ConversationPage({
    super.key,
    required this.conversationModel,
    this.conversationUpdate,
    this.initialPrompt = '',
    this.initialAssistantOpening = '',
    this.initialTargetCreatedAt,
    this.resumeAgentTask = false,
    this.initialAgentTaskGeneration,
    this.expectedAccountHash,
    this.backgroundExecution,
    this.readAloudService,
    this.predictionService,
    this.chatService,
    this.checklistCoordinator,
    this.draftStore,
    this.onSendPreparationError,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage>
    with WidgetsBindingObserver {
  ///若为新建的对话框，则_pendingUpdate为true
  bool get _pendingUpdate => widget.conversationModel.title == null;

  ///是否有通知聊天列表页更新当前会话
  bool _hadUpdate = false;
  late Map<String, dynamic> userInfo;
  String _inputMessage = "";
  late final TextEditingController _inputController;
  late final ComposerPredictionController _prediction;
  late final AISettingsProvider _predictionSettings;
  int? _predictionCompletedTurn;
  late final String _pageAccount;
  late final ConversationDraftStore _draftStore;
  Timer? _draftTimer;
  int _draftRevision = 0;
  bool _ready = false;
  bool _hasEarlierContext = false;
  bool _contextAttachmentsPrepared = false;
  String _plannedPrompt = '';
  String _plannedAttachmentInfo = '';
  String _plannedFileText = '';
  bool _draftOnlyConversation = false;
  bool _draftLoaded = false;
  String? _draftNotice;
  ChatSendProgress? _sendProgress;
  ChatContextPlan? _contextPlan;
  AgentTaskSession? _agentTask;
  AgentWorkspaceService? _workspace;
  AgentWorkspaceTools? _workspaceTools;
  SkillCatalogService? _skillCatalog;
  SkillCatalogSnapshot? _taskSkills;
  SemanticChatSummaryDao? _summaryDao;
  bool _daoTaskMode = false;
  bool get _taskMode => _agentTask?.enabled ?? false;
  bool _isStreaming = false;
  late MessageDao messageDao;
  late FavoriteDao favoriteDao;
  late ConversationListDao conversationListDao;
  late ChatController chatController;
  late CompletionDao completionDao;
  late UsageDao usageDao;
  late UsageRecordService usageRecordService;
  late final ReadAloudService _readAloudService;
  int? _readAloudActiveMessageAt;
  ReadAloudStage? _readAloudStage;
  Future<void>? _manualReadAloudInFlight;
  String? _manualReadAloudSignature;
  DateTime? _lastManualReadAloudStartedAt;
  bool _manualReadAloudStopRequested = false;

  /// 按 index 精确跳转（置顶/置底 + 对话目录跳转）。
  final ItemScrollController _itemScrollController = ItemScrollController();

  /// 列表项可见性监听：驱动分页加载与按钮可见性。
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  /// 「回到顶部 / 回到底部」悬浮按钮的可见性（仅在未到对应端点时显示）。
  bool _showJumpTop = false;
  bool _showJumpBottom = false;

  /// 分页防抖：避免一次到顶触发多次加载更多。
  bool _isLoadingMore = false;

  /// 已无更早历史：到顶后不再反复空查 DB。
  bool _noMoreHistory = false;
  bool _handledInitialTarget = false;
  bool _handledInitialResume = false;
  bool _applicationInBackground = false;
  DialogRoute<bool>? _toolConfirmationRoute;
  late final AgentBackgroundExecution _backgroundExecution;
  String? _backgroundRunId;
  String? _backgroundNotice;
  Timer? _backgroundProgressTimer;
  Completer<void>? _sendRoundSettled;
  bool _taskCheckpointFailed = false;
  bool get _hasBackgroundLease =>
      _backgroundRunId != null &&
      _backgroundExecution.isActive(_backgroundRunId!);

  Future<void> _startBackgroundExecution() async {
    if (!_taskMode || _agentTask?.backgroundEnabled != true || _sendCancelled) {
      return;
    }
    if (_applicationInBackground) {
      _stopStream(reason: '应用已进入后台，任务已暂停');
      return;
    }
    final runId = '${widget.conversationModel.cid}_${_agentTask!.generation}_'
        '${DateTime.now().microsecondsSinceEpoch}';
    _backgroundRunId = runId;
    final result = await _backgroundExecution.start(
        runId: runId,
        cid: widget.conversationModel.cid,
        title: 'Agent 任务',
        onInterrupted: (reason) async {
          if (_backgroundRunId != runId || !_accountCurrent || !_isStreaming) {
            return;
          }
          final settled = _sendRoundSettled;
          if (_agentTask?.status == 'running') {
            _stopStream(
                reason: switch (reason) {
              'userStopped' => '已从系统任务通知停止，可继续任务',
              'expired' => '系统后台执行已结束，任务已暂停',
              _ => '系统已停止后台执行，任务已暂停',
            });
          }
          try {
            await settled?.future.timeout(const Duration(seconds: 2));
          } on TimeoutException {
            // 硬中断时由已持久化的工具断点恢复，不承诺系统无限等待。
          }
        });
    if (_backgroundRunId != runId || _sendCancelled) {
      await _backgroundExecution.stop(runId: runId);
      return;
    }
    if (mounted && _accountCurrent) {
      setState(() => _backgroundNotice =
          result.active ? '后台执行已获准，可切换页面或返回桌面' : '后台许可未获准，切到后台将暂停并保存进度');
    }
    if (result.active) {
      _updateBackgroundProgress();
      _backgroundProgressTimer = Timer.periodic(
          const Duration(seconds: 1), (_) => _updateBackgroundProgress());
    }
  }

  void _updateBackgroundProgress() {
    final runId = _backgroundRunId;
    final task = _agentTask;
    if (runId == null || task == null || !_hasBackgroundLease) return;
    if (!_accountCurrent) {
      _stopStream(reason: '账号已切换，任务已暂停');
      return;
    }
    unawaited(_backgroundExecution
        .update(
            runId: runId,
            completed: task.todos.where((t) => t.status == 'completed').length,
            total: task.todos.length,
            status: _sendProgress?.label.contains('验收') == true
                ? 'verifying'
                : task.executingToolId != null
                    ? 'tool'
                    : 'generating')
        .catchError(
            (Object error) => AILogger.log('background progress: $error')));
  }

  Future<void> _releaseBackgroundExecution({bool success = false}) async {
    final runId = _backgroundRunId;
    _backgroundRunId = null;
    _backgroundProgressTimer?.cancel();
    _backgroundProgressTimer = null;
    if (runId != null) {
      await _backgroundExecution.stop(runId: runId, success: success);
    }
  }

  void _stopBackgroundAfterCheckpoint() {
    final runId = _backgroundRunId;
    final settled = _sendRoundSettled;
    _backgroundProgressTimer?.cancel();
    _backgroundProgressTimer = null;
    if (runId == null) return;
    if (!_hasBackgroundLease || settled == null) {
      unawaited(_releaseBackgroundExecution());
      return;
    }
    unawaited(() async {
      try {
        await settled.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // 网络或工具不及时返回时也必须停止后台许可，断点按已保存结果恢复。
      }
      if (_backgroundRunId == runId) await _releaseBackgroundExecution();
    }());
  }

  void _settleSendRound(Completer<void> settled) {
    if (!settled.isCompleted) settled.complete();
    if (identical(_sendRoundSettled, settled)) _sendRoundSettled = null;
  }

  Future<void> _finishTaskCheckpoint({required bool accepted}) async {
    if (!accepted || !_taskMode) return;
    try {
      if (_agentTask?.status == 'running') {
        await _agentTask!.finish(complete: false);
      }
      await _agentTask?.flush();
    } catch (error) {
      _reportTaskCheckpointFailure(error);
    }
  }

  void _reportTaskCheckpointFailure(Object error) {
    AILogger.log('task checkpoint save failed: $error');
    if (_taskCheckpointFailed) return;
    _taskCheckpointFailed = true;
    if (mounted && _accountCurrent) {
      HiDialog.showSnackBar(context, '任务进度保存失败，请检查存储空间后重试');
    }
  }

  /// 块化消息系统：规范化的块仓库（每页一个，随页面生命周期销毁）。
  final ChatBlockStore _blockStore = ChatBlockStore();
  final Map<int, int> _cardRows = {};
  late final int _cardCid;
  ChecklistStateCoordinator? _checklistCoordinator;

  bool get _cardScopeCurrent =>
      mounted && _accountCurrent && widget.conversationModel.cid == _cardCid;

  bool _cardMessageCurrent(int createdAt, String blockId, String content) =>
      _cardScopeCurrent &&
      _cardRows.containsKey(createdAt) &&
      chatController.initialMessageList.any((m) =>
          m.createdAt == createdAt && m.ownerType == OwnerType.receiver) &&
      _blockStore.blocksFor(chatMessageKey(createdAt)).any(
          (b) => b is MainTextBlock && b.id == blockId && b.content == content);

  Future<void> _setCardChecked(int createdAt, MainTextBlock block,
      CardProjection card, String itemId, bool checked) async {
    final rowId = _cardRows[createdAt];
    bool current() =>
        _cardRows[createdAt] == rowId &&
        _cardMessageCurrent(createdAt, block.id, block.content);
    if (!mounted || _isStreaming || !current()) return;
    final coordinator = _checklistCoordinator ??= widget.checklistCoordinator ??
        ChecklistStateCoordinator(
            dao: messageDao,
            accountHash: _pageAccount,
            isCurrent: () => _cardScopeCurrent);
    final result = await coordinator.setChecked(
        createdAt: createdAt,
        blockId: block.id,
        expectedContent: block.content,
        cardKey: card.key,
        itemId: itemId,
        checked: checked,
        expectedRowId: rowId!,
        messageIsCurrent: current);
    if (!mounted || !current()) return;
    if (result.status == ChecklistWriteStatus.saved && result.state != null) {
      final latest = _blockStore.block(block.id);
      if (latest is MainTextBlock && latest.content == block.content) {
        _blockStore.upsertBlock(latest.copyWith(localCardStates: {
          ...latest.localCardStates,
          card.key: result.state!,
        }));
      }
    } else {
      HiDialog.showSnackBar(
          context,
          result.status == ChecklistWriteStatus.failed
              ? '清单保存失败，已保留上次勾选状态'
              : '这张清单已失效，请重新打开会话');
    }
  }

  void _insertCardText(String text, int capturedCid) {
    if (!_cardScopeCurrent ||
        capturedCid != _cardCid ||
        !_ready ||
        _isStreaming ||
        _savingReasoningEffort) {
      return;
    }
    final previous = _inputController.text;
    final next = previous.isEmpty
        ? text
        : '$previous${previous.endsWith('\n\n') ? '' : '\n\n'}$text';
    _inputController.value = TextEditingValue(
        text: next, selection: TextSelection.collapsed(offset: next.length));
    _inputChanged(next);
    setState(() {});
  }

  AgentTaskRun? _agentRun;
  int? _agentReadAloudAt;
  AgentTaskKey get _taskKey =>
      AgentTaskKey(_pageAccount, widget.conversationModel.cid);
  final AgentTaskExecutor _taskExecutor = AgentTaskExecutor.instance;

  Future<bool> Function(String, String) get _taskConfirmation {
    final executor = _taskExecutor;
    final key = _taskKey;
    return (title, detail) => executor.confirm(key, title, detail);
  }

  void _bindAgentRun(AgentTaskRun run) {
    _taskExecutor.removeListener(_syncAgentRun);
    _agentRun = run;
    _agentTask = run.prepared.session;
    _workspace = run.prepared.workspace;
    _workspaceTools = run.prepared.workspaceTools;
    completionDao = run.prepared.completion;
    _taskExecutor.addListener(_syncAgentRun);
    _syncAgentRun();
  }

  void _syncAgentRun() {
    final run = _agentRun;
    if (run == null || !mounted || _disposed || !_accountCurrent) return;
    final reply = run.reply;
    var bindingChanged = false;
    if (reply != null) {
      final current = chatController.initialMessageList
          .where((message) => message.createdAt == reply.createdAt)
          .firstOrNull;
      if (current == null) {
        chatController.addMessage(reply);
      } else if (current.content != reply.content) {
        chatController.updateMessage(reply);
      }
      // 执行器完成后的通知仍会带原快照；同一正文保留本页已保存的本地状态。
      final latestBlocks = run.blocks.blocksFor(run.messageKey).map((block) {
        final current = _blockStore.block(block.id);
        if (block is MainTextBlock &&
            current is MainTextBlock &&
            block.content == current.content) {
          return block.copyWith(localCardStates: current.localCardStates);
        }
        return block;
      }).toList();
      _blockStore.seedMessage(run.messageKey, latestBlocks);
      _blockStore.commitSeed();
      if (!run.busy && run.persistedReplyRowId != null) {
        bindingChanged = _cardRows[reply.createdAt] != run.persistedReplyRowId;
        _cardRows[reply.createdAt] = run.persistedReplyRowId!;
      }
    }
    final progress = run.queued
        ? ChatSendProgress(
            '等待执行（队列第 ${_taskExecutor.queuePosition(run.key)} 位）')
        : run.progress;
    final changed = bindingChanged ||
        _isStreaming != run.busy ||
        _sendProgress?.label != progress?.label ||
        _backgroundNotice != run.backgroundNotice;
    _contextPlan = run.contextPlan ?? _contextPlan;
    if (changed) {
      setState(() {
        _isStreaming = run.busy;
        _sendProgress = progress;
        _backgroundNotice = run.backgroundNotice;
      });
    }
    if (!run.busy &&
        run.pauseReason?.contains('保存失败') == true &&
        !_taskCheckpointFailed) {
      _taskCheckpointFailed = true;
      HiDialog.showSnackBar(context, run.pauseReason!);
    }
    if (!run.busy && reply != null) {
      widget.conversationModel.lastMessage = reply.content;
      widget.conversationModel.updateAt = reply.createdAt;
      if (run.phase == AgentRunPhase.complete &&
          _agentReadAloudAt != reply.createdAt &&
          !_applicationInBackground &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        _agentReadAloudAt = reply.createdAt;
        unawaited(_readAloudAssistant(reply.content));
      }
    }
  }

  Future<void> _enqueueAgentRun(
      MessageModel user, AISettings settings, ChatAttachments attachments,
      {required bool webSearch, ToolRegistry? tools}) async {
    final prepared = PreparedAgentRun(
        key: _taskKey,
        conversation: widget.conversationModel,
        user: user,
        receiver: _genMessageModel(ownerType: OwnerType.receiver, message: ''),
        settings: settings,
        completion: completionDao,
        messages: messageDao,
        usage: usageRecordService,
        session: _agentTask!,
        workspace: _workspace!,
        workspaceTools: _workspaceTools!,
        attachments: attachments,
        tools: tools,
        webSearch: webSearch,
        background: _backgroundExecution,
        hasAssistant: _assistant != null);
    final run = await _taskExecutor.enqueue(prepared);
    // 导航若发生在 enqueue 的存储等待期间，执行器仍独立接管。
    if (!run.isRetired && mounted && _accountCurrent) _bindAgentRun(run);
    _lastUserModel = null;
    _lastUserFileText = '';
  }

  /// 当前活跃的流式订阅 / 分发器 / 完成信号 / 接收方气泡（供「停止」与销毁时收尾）。
  StreamSubscription<StreamEvent>? _activeEventSub;
  StreamDispatcher? _activeDispatcher;
  Completer<void>? _streamCompleter;
  Completer<void>? _streamAbortCompleter;
  MessageModel? _activeReceiver;

  ///本轮用户消息，assistant 收尾时与之配对追加进会话历史。
  MessageModel? _lastUserModel;
  String? _usagePromptText;
  AISettings? _usageSettings;
  int _streamPromptTokens = 0;
  int _streamCachedPromptTokens = 0;
  int _streamCompletionTokens = 0;
  bool _hasStreamUsage = false;
  final Map<int, List<AssistantMemoryEntryPreview>> _memoryHitsByMessageAt = {};
  final Map<int, AssistantMemoryContextBudget> _memoryBudgetByMessageAt = {};
  final Set<int> _expandedMemoryHits = {};
  final Map<int, List<String>> _roleStateByMessageAt = {};
  final Map<int, String> _roleContextByMessageAt = {};
  final Map<int, String> _memorySuggestionsByMessageAt = {};
  final Set<int> _dismissedMemorySuggestions = {};

  ///本轮附件的降级文本，随 [_lastUserModel] 一起追加进历史（遗留项 6）。
  String _lastUserFileText = '';
  bool _userStopped = false;
  bool _disposed = false;
  bool _readinessDialogOpen = false;

  late AISettings _currentSettings;
  List<String> _pendingImages = [];
  List<String> _pendingFiles = [];
  List<ComposerReference> _references = [];
  bool _referencePickerOpen = false;

  bool get _accountCurrent =>
      !_disposed && (LoginDao.getAccountHash() ?? 'guest') == _pageAccount;

  bool get _predictionEligible =>
      _accountCurrent &&
      _ready &&
      !_isStreaming &&
      !_taskMode &&
      !_applicationInBackground &&
      !_savingReasoningEffort &&
      _predictionSettings.settings.composerPredictionsEnabled &&
      _inputController.text.isEmpty &&
      (!_inputController.value.composing.isValid ||
          _inputController.value.composing.isCollapsed) &&
      _pendingImages.isEmpty &&
      _pendingFiles.isEmpty &&
      _references.isEmpty &&
      !_referencePickerOpen;

  void _onPredictionChanged() {
    if (mounted && !_disposed) setState(() {});
  }

  void _invalidatePrediction() {
    _predictionCompletedTurn = null;
    _prediction.cancel();
  }

  void _acceptPrediction() {
    final suggestion = _prediction.suggestion;
    if (!_predictionEligible || suggestion == null) return;
    _prediction.cancel();
    _inputController.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
  }

  void _requestPredictionAfterReply() {
    final turn = _predictionCompletedTurn;
    _predictionCompletedTurn = null;
    if (turn == null || !_predictionEligible) return;
    final sourceSettings = _predictionSettings.settings;
    final settings = _effective(sourceSettings);
    final conversationId = widget.conversationModel.cid;
    final projectId = widget.conversationModel.projectId;
    final assistant = _assistant;
    final modelId = widget.conversationModel.modelId;
    final providerId = widget.conversationModel.modelProviderId;
    unawaited(_prediction.request(
      completedTurn: turn,
      settings: settings,
      messages: completionDao.currentMessages,
      isEligible: () =>
          _predictionEligible &&
          identical(sourceSettings, _predictionSettings.settings) &&
          conversationId == widget.conversationModel.cid &&
          identical(assistant, _assistant) &&
          modelId == widget.conversationModel.modelId &&
          providerId == widget.conversationModel.modelProviderId,
      onUsage: (result) async {
        if (!_accountCurrent) return;
        try {
          await usageRecordService.recordTurn(
            modelId: settings.effectiveModel,
            providerId: settings.mode == AIMode.local
                ? settings.activeProviderId
                : providerId,
            projectId: projectId,
            cid: conversationId,
            prompt: result.requestText,
            completion: result.usage.content ?? '',
            promptTokens: result.usage.promptTokens,
            cachedPromptTokens: result.usage.cachedPromptTokens,
            completionTokens: result.usage.completionTokens,
            estimated: result.usage.estimated,
            cost: result.usage.cost,
            costConfig: settings.usageCostConfig,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );
        } catch (_) {
          // 用量记录失败不阻塞可选建议，也不重复模型请求。
        }
      },
    ));
  }

  void _inputChanged(String text) {
    if (text.isNotEmpty ||
        (_inputController.value.composing.isValid &&
            !_inputController.value.composing.isCollapsed)) {
      _invalidatePrediction();
    }
    _inputMessage = text;
    if (!_isStreaming) {
      _plannedPrompt = text;
      _plannedAttachmentInfo = '';
      _plannedFileText = historyReferencesExtraText(_references);
      if (_ready) _draftNotice = null;
      _contextPlan = null;
      _contextAttachmentsPrepared = false;
    }
    _scheduleDraftSave();
  }

  void _scheduleDraftSave() {
    _draftRevision++;
    if (!_draftLoaded || !_accountCurrent) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_saveDraft());
    });
  }

  Future<FrozenComposerDraft> _freezeReferences(
      AttachmentProcessingLimits limits) async {
    final revision = _draftRevision;
    final cid = widget.conversationModel.cid;
    final frozen = await _draftStore.freezeForSend(
        text: _inputController.text,
        images: List.from(_pendingImages),
        files: List.from(_pendingFiles),
        references: List.from(_references),
        limits: limits);
    if (!mounted ||
        !_accountCurrent ||
        widget.conversationModel.cid != cid ||
        revision != _draftRevision ||
        frozen == null) {
      throw const DraftStorageException('输入已变化，请重新发送');
    }
    setState(() {
      _references = frozen.references;
      _pendingImages = frozen.imagePaths;
      _pendingFiles = frozen.filePaths;
    });
    if (frozen.missingAttachmentCount > 0 ||
        frozen.references.any((r) => !r.available)) {
      throw const DraftStorageException('引用冻结失败，请移除或重新选择后发送');
    }
    return frozen;
  }

  Future<ConversationDraft?> _saveDraft() async {
    if (!_draftLoaded || !_accountCurrent) {
      return null;
    }
    final revision = _draftRevision;
    final cid = widget.conversationModel.cid;
    final text = _inputController.text;
    final images = List<String>.from(_pendingImages);
    final files = List<String>.from(_pendingFiles);
    final references = List<ComposerReference>.from(_references);
    try {
      final draft = await _draftStore.save(
          text: text, images: images, files: files, references: references);
      if (!mounted ||
          !_accountCurrent ||
          widget.conversationModel.cid != cid ||
          revision != _draftRevision ||
          draft == null) {
        return null;
      }
      setState(() {
        _references = draft.references;
        _pendingImages = draft.imagePaths;
        _pendingFiles = draft.filePaths;
        _draftNotice = draft.missingAttachmentCount > 0
            ? '${draft.missingAttachmentCount} 个附件未能保存，请重新选择；文字草稿已保存'
            : (_draftNotice?.startsWith('已恢复') == true ? _draftNotice : null);
        if (!_isStreaming && _ready) {
          _plannedPrompt = text;
          _plannedFileText = historyReferencesExtraText(_references);
          _contextPlan = completionDao.previewContext(
              prompt: text,
              attachments: ChatAttachments(
                  extraText: historyReferencesExtraText(_references)));
          _contextAttachmentsPrepared = false;
        }
      });
      if (!_isStreaming) {
        await _retainNewDraftConversation(text, images, files, references);
      }
      return draft;
    } catch (_) {
      if (mounted &&
          _accountCurrent &&
          widget.conversationModel.cid == cid &&
          revision == _draftRevision) {
        setState(() => _draftNotice = '草稿未能保存，请保留当前页面后重试');
      }
      return null;
    }
  }

  void _markNewDraftConversation(
      String text, List<String> images, List<String> files,
      [List<ComposerReference> references = const []]) {
    if (!_ready ||
        chatController.initialMessageList.any((m) => m.createdAt > 0)) {
      return;
    }
    if (!_draftOnlyConversation && widget.conversationModel.title != null) {
      return;
    }
    if (text.trim().isEmpty &&
        images.isEmpty &&
        files.isEmpty &&
        references.isEmpty) {
      return;
    }
    _draftOnlyConversation = true;
    final preview =
        text.trim().isEmpty ? '引用与附件草稿' : text.trim().split('\n').first;
    widget.conversationModel.title =
        preview.length > 60 ? preview.substring(0, 60) : preview;
    widget.conversationModel.lastMessage = '[草稿] $preview';
    widget.conversationModel.updateAt = DateTime.now().millisecondsSinceEpoch;
    widget.conversationModel.messageCount = 0;
    widget.conversationModel.hadChanged = true;
  }

  Future<void> _retainNewDraftConversation(
      String text, List<String> images, List<String> files,
      [List<ComposerReference> references = const []]) async {
    if (!_accountCurrent) return;
    if (_draftOnlyConversation &&
        text.trim().isEmpty &&
        images.isEmpty &&
        files.isEmpty &&
        references.isEmpty) {
      final deleted = await conversationListDao.storage.db.rawDelete(
          'delete from tb_conversation_list where cid = ? and not exists '
          '(select 1 from tb_messages where cid = ?)',
          [widget.conversationModel.cid, widget.conversationModel.cid]);
      if (deleted > 0 && !_isStreaming && _accountCurrent) {
        widget.conversationModel.title = null;
        widget.conversationModel.lastMessage = null;
        _draftOnlyConversation = false;
        AppEvents.notifyConversationsChanged();
      }
      return;
    }
    _markNewDraftConversation(text, images, files, references);
    if (_draftOnlyConversation) {
      await conversationListDao.saveConversation(widget.conversationModel);
      AppEvents.notifyConversationsChanged();
    }
  }

  Future<void> _restoreDraft() async {
    final revision = _draftRevision;
    try {
      final draft = await _draftStore.load();
      if (!mounted || !_accountCurrent || revision != _draftRevision) return;
      if (draft != null && widget.initialPrompt.isEmpty) {
        _inputController.text = draft.text;
        _inputMessage = draft.text;
        _pendingImages = draft.imagePaths;
        _pendingFiles = draft.filePaths;
        _references = draft.references;
        _draftNotice = draft.missingAttachmentCount > 0
            ? '已恢复文字草稿；${draft.missingAttachmentCount} 个附件已失效，请重新选择'
            : '已恢复此会话的草稿';
      }
    } catch (_) {
      if (mounted && _accountCurrent) _draftNotice = '草稿读取失败，已有聊天记录不受影响';
    } finally {
      _draftLoaded = true;
    }
  }

  void _onSendProgress(ChatSendProgress progress) {
    if (!mounted || !_accountCurrent || _userStopped) return;
    setState(() => _sendProgress = progress);
  }

  /// 会话绑定的助手（阶段七）。null = 未绑定 / 已被删除（自然回落无助手）。
  AssistantModel? _assistant;

  /// 构建当前 completionDao 时所用的助手，用于「切换助手后重建 Dao」的判断。
  AssistantModel? _daoAssistant;
  String? _daoSystemPrompt;
  String? _daoModelProviderId;
  String? _daoModelId;
  DeepSeekReasoningEffort? _daoReasoningEffort;
  bool _savingReasoningEffort = false;
  AssistantDao? _assistantDao;
  AssistantMemoryDao? _assistantMemoryDao;
  List<AssistantMemoryModel> _assistantMemories = const [];
  PersonalMemoryDao? _personalMemoryDao;
  PersonalMemoryTurn? _personalMemoryTurn;

  Future<String> Function(bool)? _memoryResolver() {
    final personal = _personalMemoryDao;
    final assistant = _assistantMemoryDao;
    if (personal == null || assistant == null) return null;
    return ConversationMemoryContext(
            storage: messageDao.storage,
            accountHash: _pageAccount,
            cid: widget.conversationModel.cid,
            assistantId: widget.conversationModel.assistantId,
            taskMode: _taskMode,
            personal: personal,
            assistant: assistant)
        .resolve;
  }

  Future<void> _proposePersonalMemory(int replyCreatedAt) async {
    final turn = _personalMemoryTurn;
    final user = _lastUserModel;
    _personalMemoryTurn = null;
    if (turn == null ||
        user == null ||
        !_accountCurrent ||
        _taskMode ||
        widget.conversationModel.assistantId != null ||
        turn.cid != widget.conversationModel.cid) {
      return;
    }
    try {
      await _personalMemoryDao?.suggestAfterPersist(turn,
          userCreatedAt: user.createdAt, replyCreatedAt: replyCreatedAt);
    } catch (_) {
      if (mounted && _accountCurrent) {
        HiDialog.showSnackBar(context, '回复已保存，个人记忆建议保存失败');
      }
    }
  }

  /// 应用助手的模型覆盖后的设置 —— 能力位与请求构造都用它，
  /// 保证「助手指定了模型时，capabilitiesFor 用覆盖后的模型算」。
  AISettings _effective(AISettings s) {
    final next = (_assistant?.applyTo(s) ?? s).clone();
    next.deepSeekReasoningEffort =
        widget.conversationModel.deepSeekReasoningEffort;
    if (_taskMode) next.streamEnabled = true;
    final webSearchOverride = widget.conversationModel.webSearchEnabled;
    if (webSearchOverride != null) {
      next.webSearchEnabled = webSearchOverride;
    }
    final modelId = widget.conversationModel.modelId?.trim() ?? '';
    if (modelId.isEmpty) return next;
    if (next.mode == AIMode.backend) {
      next.backendModel = modelId;
      return next;
    }
    final providerId = widget.conversationModel.modelProviderId;
    if (providerId != null &&
        next.providers.any((p) => p.id == providerId && p.enabled)) {
      next.activeProviderId = providerId;
    }
    next.setActiveModel(modelId);
    return next;
  }

  Future<String?> _assistantSystemPromptForSafely(String inputMessage,
      {bool resumeTask = false, bool workspaceInputs = false}) async {
    final scanText = _roleMemoryScanText(inputMessage);
    var preview = await ConversationRoleContextPreview.buildSafely(
      assistant: _assistant,
      userInput: scanText,
      conversation: widget.conversationModel,
      memories: const [],
    );
    if (_taskMode) {
      _taskSkills = await _skillCatalog?.prepare(
          assistant: _assistant?.emoji == '🧩' ? _assistant : null);
      if (_taskSkills?.replacesAssistantPrompt == true) {
        preview =
            preview.replaceFirst(_assistant?.prompt.trim() ?? '', '').trim();
      }
      preview = [
        preview,
        _agentTask!.contextPromptFor(resume: resumeTask),
        _taskSkills?.systemPrompt ?? '',
        _workspaceTools?.systemPrompt ?? '',
        if (_workspaceTools != null)
          await _workspaceTools!.acceptancePrompt(
              hasInputs: workspaceInputs || _pendingFiles.isNotEmpty,
              resume: resumeTask),
        if (_workspace != null) await _workspace!.manifest(),
      ].where((text) => text.isNotEmpty).join('\n\n');
    } else {
      _taskSkills = null;
    }
    return [preview, interactiveCardSystemPrompt]
        .where((text) => text.trim().isNotEmpty)
        .join('\n\n');
  }

  SemanticChatSummaryService? _summaryServiceFor(AISettings settings) =>
      !_taskMode || _summaryDao == null
          ? null
          : SemanticChatSummaryService(
              store: _summaryDao!,
              summarizer: SemanticChatSummaryService.chatSummarizer(
                  ChatService.from(settings)),
            );

  void _openTaskMode() {
    _invalidatePrediction();
    final task = _agentTask;
    if (task == null || !_ready) return;
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => AnimatedBuilder(
              animation: task,
              builder: (ctx, _) => SafeArea(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('任务模式',
                                style: Theme.of(ctx).textTheme.titleLarge),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('在当前对话启用'),
                                subtitle: const Text(
                                    '保存计划与进度，长文件按需阅读，成果写入工作区并进行客观验收。'),
                                value: task.enabled,
                                onChanged: _isStreaming
                                    ? null
                                    : (value) async {
                                        final caps =
                                            ChatService.capabilitiesFor(
                                                _effective(context
                                                    .read<AISettingsProvider>()
                                                    .settings));
                                        if (value && !caps.tool) {
                                          HiDialog.showSnackBar(
                                              context, '请先选择支持工具调用的模型');
                                          return;
                                        }
                                        try {
                                          await task.setEnabled(value);
                                          if (mounted && _accountCurrent) {
                                            setState(() {});
                                          }
                                        } catch (_) {
                                          if (mounted) {
                                            HiDialog.showSnackBar(
                                                context, '任务设置未保存，请重试');
                                          }
                                        }
                                      }),
                            if (task.enabled)
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('允许后台继续'),
                                  subtitle: const Text(
                                      'Android 使用任务通知，iOS 26 申请系统许可。未获准时保存进度并暂停；切换页面继续执行；未获后台许可时返回桌面会暂停。'),
                                  value: task.backgroundEnabled,
                                  onChanged: _isStreaming
                                      ? null
                                      : (value) async {
                                          if (!_accountCurrent) return;
                                          try {
                                            await task
                                                .setBackgroundEnabled(value);
                                            if (mounted && _accountCurrent) {
                                              setState(() {});
                                            }
                                          } catch (_) {
                                            if (mounted) {
                                              HiDialog.showSnackBar(
                                                  context, '后台设置未保存，请重试');
                                            }
                                          }
                                        }),
                            if (task.executingToolId != null)
                              const Text('中断前有工具执行结果未确认，继续时会标记结果不明，不会自动重复该操作。'),
                            if (task.canResume && task.pauseReason != null)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(task.pauseReason!)),
                            for (final todo in task.todos)
                              ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(todo.status == 'completed'
                                      ? Icons.check_circle_outline
                                      : todo.status == 'in_progress'
                                          ? Icons.pending_outlined
                                          : Icons.radio_button_unchecked),
                                  title: Text(todo.content)),
                            if (_workspaceTools?.lastReport case final report?)
                              ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(report.isPassed
                                      ? Icons.fact_check_outlined
                                      : Icons.warning_amber_outlined),
                                  title: Text(report.summary),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _openWorkspace();
                                  }),
                            TextButton.icon(
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _openWorkspace();
                                },
                                icon: const Icon(Icons.folder_open),
                                label: const Text('文件工作区与验收设置')),
                            if (task.canResume && !_isStreaming)
                              FilledButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _resumeTask();
                                  },
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('继续任务')),
                          ]))),
            ));
  }

  Future<void> _openWorkspace() async {
    final workspace = _workspace;
    final tools = _workspaceTools;
    if (!_ready || workspace == null || tools == null) return;
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => AgentWorkspacePage(
                workspace: workspace,
                tools: tools,
                readOnly: _isStreaming,
                maxImportBytes: context
                    .read<AISettingsProvider>()
                    .settings
                    .attachmentProcessingLimits
                    .normalized
                    .maxTextFileBytes)));
    final report = _workspaceTools?.lastReport;
    if (_accountCurrent &&
        _taskMode &&
        !_isStreaming &&
        _agentTask?.status == 'complete' &&
        report != null &&
        report.userCreatedAt == _agentTask?.userCreatedAt &&
        !report.isPassed) {
      await _agentTask!.finish(complete: false, requiresCorrection: true);
    }
    if (mounted && _accountCurrent) setState(() {});
  }

  Future<void> _resolveTaskFailure() async {
    if (!_ready || !mounted || !_accountCurrent || _isStreaming) return;
    final diagnosis = _agentTask?.failureDiagnosis;
    if (diagnosis == null) return;
    switch (diagnosis.action) {
      case ChatFailureAction.retry:
        _resumeTask();
        return;
      case ChatFailureAction.chooseModel:
        _switchModel();
        return;
      case ChatFailureAction.none:
        return;
      case ChatFailureAction.checkInput:
        await Navigator.push<void>(
            context, MaterialPageRoute(builder: (_) => const AISettingsPage()));
      case ChatFailureAction.configureProvider:
      case ChatFailureAction.checkBalance:
        final settings =
            _effective(context.read<AISettingsProvider>().settings);
        final providerId = settings.activeProviderId;
        final hasProvider = settings.mode == AIMode.local &&
            settings.providers.any((provider) => provider.id == providerId);
        await Navigator.push<void>(
            context,
            MaterialPageRoute(
                builder: (_) => hasProvider
                    ? AiProviderDetailPage(providerId: providerId)
                    : const AISettingsPage()));
    }
    // 修改设置仅影响下一次明确继续，不在返回时自动重发。
    if (mounted && _accountCurrent) setState(() {});
  }

  Future<void> _openTaskDetails() async {
    if (!_ready ||
        !mounted ||
        !_accountCurrent ||
        _agentTask?.userCreatedAt == null) {
      return;
    }
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => AgentTaskDetailPage(
                cid: widget.conversationModel.cid,
                expectedAccountHash: _pageAccount)));
    if (mounted && _accountCurrent) setState(() {});
  }

  void _resumeTask() async {
    _invalidatePrediction();
    final task = _agentTask;
    if (!_ready ||
        !mounted ||
        !_accountCurrent ||
        _applicationInBackground ||
        !(ModalRoute.of(context)?.isCurrent ?? false) ||
        task == null ||
        !task.canResume ||
        _isStreaming ||
        _taskExecutor.lookup(_taskKey)?.busy == true) {
      return;
    }
    final userAt = task.userCreatedAt!;
    final generation = task.generation;
    try {
      final service = await AgentTaskDetailService.create(messageDao.storage,
          accountHash: _pageAccount, executor: _taskExecutor);
      final conversation = await service.conversationForResume(task.cid,
          userCreatedAt: userAt, generation: generation);
      if (!mounted ||
          !_accountCurrent ||
          _applicationInBackground ||
          !(ModalRoute.of(context)?.isCurrent ?? false) ||
          _isStreaming) {
        return;
      }
      if (conversation == null ||
          task.generation != generation ||
          task.userCreatedAt != userAt ||
          !task.canResume ||
          _taskExecutor.lookup(_taskKey)?.busy == true) {
        HiDialog.showSnackBar(context, '任务状态已变化，请查看最新详情后继续');
        return;
      }
    } catch (_) {
      if (mounted && _accountCurrent) {
        HiDialog.showSnackBar(context, '任务进度读取失败，请重试');
      }
      return;
    }
    final messages = chatController.initialMessageList;
    final users = messages.where((m) =>
        m.createdAt == task.userCreatedAt && m.ownerType == OwnerType.sender);
    if (users.isEmpty ||
        messages.any((m) =>
            m.ownerType == OwnerType.sender &&
            m.createdAt > task.userCreatedAt!)) {
      HiDialog.showSnackBar(context, '任务对应提问已变化，请重新发送任务');
      return;
    }
    final replies = messages.where((m) =>
        m.ownerType == OwnerType.receiver && m.createdAt > task.userCreatedAt!);
    await _retryUserMessage(users.first,
        oldReply: replies.isEmpty ? null : replies.first, resumeTask: true);
  }

  static bool _protocolIsBalanced(List<Map<String, dynamic>> messages) {
    final pending = <String>{};
    for (final message in messages) {
      for (final call in message['tool_calls'] as List? ?? const []) {
        pending.add(call['id'] as String);
      }
      if (message['role'] == 'tool' &&
          !pending.remove(message['tool_call_id'])) {
        return false;
      }
    }
    return pending.isEmpty;
  }

  List<String> _recentRoleMemoryMessages() {
    return chatController.initialMessageList
        .where((message) => message.createdAt > 0)
        .map((message) => message.content)
        .where((content) => content.trim().isNotEmpty)
        .toList();
  }

  String _roleMemoryScanText(String inputMessage) {
    return ConversationRoleContextPreview.scanText(
      userInput: inputMessage,
      recentMessages: _recentRoleMemoryMessages(),
    );
  }

  Future<void> _loadAssistantMemories() async {
    final assistantId = _assistant?.id;
    if (assistantId == null || _assistantMemoryDao == null) {
      _assistantMemories = const [];
      return;
    }
    _assistantMemories =
        await _assistantMemoryDao!.getMemories(assistantId, limit: 20);
  }

  /// 工具运行上下文：注入确认回调 + 当前助手 id（run_script 据此查脚本）
  /// + JS 执行钩子（仅支持的平台注入，OHOS/Web 为 null → run_script 优雅跳过）。
  ToolActionContext _toolActions() {
    final storage = messageDao.storage;
    return ToolActionContext(
      openStorage: () async => storage,
      confirm: _taskMode ? _taskConfirmation : _confirmToolAction,
      assistantId: _assistant?.id,
      projectId: widget.conversationModel.projectId,
      runJs: JsRuntimeService.isSupported
          ? (code, input) => const JsRuntimeService().run(code, input: input)
          : null,
    );
  }

  /// 发现当前设置下的 MCP 工具（方案 A 直连 + 方案 B 后端 Host）。MCP 工具
  /// 来自外部不可信，执行前经 [_confirmToolAction] 确认（信任源除外）。任何
  /// 来源失败都只返回已成功部分，绝不阻断发送。未配置 MCP 时直接返回空。
  ///
  /// 按助手绑定过滤（item 5）：绑定了助手时，只暴露该助手 toolIds 里勾选的
  /// MCP 工具（与内置工具一致）；无助手的临时会话则暴露全部（受设置开关约束）。
  Future<List<ChatTool>> _discoverMcpTools(AISettings settings) async {
    if (!settings.mcpConfigured) return const [];
    final storage = messageDao.storage;
    final auditDao = await ToolAuditDao.create(storage);
    final all = await McpToolSource.discover(settings,
        confirm: _taskMode ? _taskConfirmation : _confirmToolAction,
        auditDao: auditDao,
        currentProjectId: widget.conversationModel.projectId);
    final assistant = _assistant;
    if (assistant == null) return all;
    final bound = {...?assistant.toolIds};
    return all.where((t) => bound.contains(t.name)).toList();
  }

  List<String>? get _effectiveToolIds =>
      widget.conversationModel.toolIds ?? _assistant?.toolIds;

  /// 块上记录的 modelId（覆盖后实际生效的模型）。
  String get _effectiveModelId => _effective(_currentSettings).effectiveModel;

  Widget get _chatList {
    final appearance = context.watch<ThemeProvider?>();
    final visualTheme = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 10),
            child: ChatList(
              chatController: chatController,
              onBubbleLongPress: _onBubbleLongPress,
              avatarBuilder: buildStarcoreMessageAvatar,
              showAvatars: appearance?.showMessageAvatars ?? true,
              receiverBackgroundColor:
                  appearance?.bubbleColor(Theme.of(context), isUser: false) ??
                      colorScheme.primaryContainer,
              senderBackgroundColor:
                  appearance?.bubbleColor(Theme.of(context), isUser: true) ??
                      colorScheme.surfaceContainerHighest,
              receiverAvatarBackgroundColor:
                  visualTheme.isAnime ? colorScheme.primary : null,
              senderAvatarBackgroundColor:
                  visualTheme.isAnime ? colorScheme.secondary : null,
              bubbleRadius:
                  visualTheme.isAnime ? const Radius.circular(18) : null,
            ),
          ),
          // 置顶/置底悬浮按钮：叠在对话区右下角，不占输入框空间。
          Positioned(right: 12, bottom: 12, child: _scrollJumpButtons()),
        ],
      ),
    );
  }

  /// 右下角的「回到顶部 / 回到底部」按钮组：按可见性按需出现，都隐藏时为空盒。
  Widget _scrollJumpButtons() {
    final children = <Widget>[];
    if (_showJumpTop) {
      children.add(_jumpButton(
        icon: Icons.keyboard_double_arrow_up_rounded,
        tooltip: '回到顶部',
        onTap: _scrollToTop,
      ));
    }
    if (_showJumpBottom) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 10));
      children.add(_jumpButton(
        icon: Icons.keyboard_double_arrow_down_rounded,
        tooltip: '回到底部',
        onTap: _scrollToBottom,
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _jumpButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Icon(icon, size: 22, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// reverse:true 下 index 0 = 最新消息（最底部）。
  void _scrollToBottom() {
    if (!_itemScrollController.isAttached) return;
    _itemScrollController.scrollTo(
        index: 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut);
  }

  /// 跳到当前已加载的最旧一条（index 最大）。若上面还有未加载历史，停在顶部时
  /// 会顺带触发分页加载更多（见 [_onPositionsChanged]）。
  void _scrollToTop() {
    if (!_itemScrollController.isAttached) return;
    final last = chatController.initialMessageList.length - 1;
    if (last < 0) return;
    _itemScrollController.scrollTo(
        index: last,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut);
  }

  /// 列表项可见性变化回调：刷新按钮可见性 + 到顶时分页加载更多。
  void _onPositionsChanged() {
    if (!mounted) return;
    final positions = _itemPositionsListener.itemPositions.value;
    final itemCount = chatController.initialMessageList.length;
    final edges = computeChatListEdges(
      visibleIndices: positions.map((p) => p.index),
      itemCount: itemCount,
    );
    // 到达最旧的已加载项 -> 加载更早一页。
    if (edges.atTop && itemCount > 0) _maybeLoadMore();
    final showTop = !edges.atTop;
    final showBottom = !edges.atBottom;
    if (showTop != _showJumpTop || showBottom != _showJumpBottom) {
      setState(() {
        _showJumpTop = showTop;
        _showJumpBottom = showBottom;
      });
    }
  }

  /// 加载更早一页（带防抖与「无更多」短路），返回是否真的有新数据。
  Future<bool> _maybeLoadMore() async {
    if (_isLoadingMore || _noMoreHistory) return false;
    _isLoadingMore = true;
    try {
      final list = await _loadData(loadMore: true);
      if (list.isEmpty) {
        _noMoreHistory = true;
        return false;
      }
      return true;
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 把整段会话的历史全部加载进来（对话目录跳转前调用，保证任意提问都能按 index 跳到）。
  Future<void> _loadAllHistory() async {
    while (!_noMoreHistory) {
      final before = chatController.initialMessageList.length;
      final got = await _maybeLoadMore();
      if (!got || chatController.initialMessageList.length == before) break;
    }
  }

  Future<void> _jumpToInitialTargetMessage() async {
    final target = widget.initialTargetCreatedAt;
    if (_handledInitialTarget || target == null) return;
    _handledInitialTarget = true;
    await _loadAllHistory();
    if (!mounted) return;
    final index = chatController.initialMessageList
        .indexWhere((message) => message.createdAt == target);
    if (index < 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未找到命中的历史消息')));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.scrollTo(
        index: index,
        alignment: 0.08,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    });
  }

  /// 打开「对话目录」：先把历史加载全，再用底部弹窗列出全部提问，点选跳转。
  Future<void> _openOutline() async {
    // 加载全量历史时给个轻提示（长会话可能要查几页）。
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('正在整理对话目录…'), duration: Duration(milliseconds: 600)));
    await _loadAllHistory();
    if (!mounted) return;

    // initialMessageList：index 0 = 最新。目录按时间正序（旧→新）展示，跳转用原 index。
    final list = chatController.initialMessageList;
    final entries = <({int index, String text})>[];
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.ownerType != OwnerType.sender) continue;
      final text = m.content.trim().replaceAll('\n', ' ');
      if (text.isEmpty) continue;
      entries.add((index: i, text: text));
    }

    if (entries.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('还没有提问可定位')));
      return;
    }

    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _outlineSheet(ctx, entries),
    );
    if (picked != null && _itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: picked,
        // 让选中的提问落在偏上位置，下方紧跟它的回答。
        alignment: 0.08,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _outlineSheet(
      BuildContext ctx, List<({int index, String text})> entries) {
    final maxH = MediaQuery.of(ctx).size.height * 0.6;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.format_list_bulleted, size: 20),
                  const SizedBox(width: 8),
                  Text('对话目录 · ${entries.length} 个提问',
                      style: Theme.of(ctx).textTheme.titleMedium),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final e = entries[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 13,
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 11)),
                    ),
                    title: Text(e.text,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(ctx).pop(e.index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  get _appBar => AppBar(
        title: _appBarTitle,
        actions: [
          IconButton(
            icon: const Icon(Icons.support_agent),
            tooltip: '切换助手',
            onPressed: _switchAssistant,
          ),
          PopupMenuButton<_ConversationMoreAction>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: _onConversationMoreAction,
            itemBuilder: (_) => [
              _moreMenuItem(_ConversationMoreAction.taskMode,
                  Icons.checklist_rounded, '任务模式'),
              _moreMenuItem(_ConversationMoreAction.workspace,
                  Icons.folder_open_outlined, '文件工作区'),
              _moreMenuItem(
                _ConversationMoreAction.outline,
                Icons.format_list_bulleted,
                '对话目录',
              ),
              if (_assistant != null)
                _moreMenuItem(
                  _ConversationMoreAction.assistantProfile,
                  Icons.badge_outlined,
                  '角色资料',
                ),
              if (_assistant != null)
                _moreMenuItem(
                  _ConversationMoreAction.roleContext,
                  Icons.fact_check_outlined,
                  '下一轮上下文',
                ),
              if (_assistant != null)
                _moreMenuItem(
                  _ConversationMoreAction.roleDebug,
                  Icons.bug_report_outlined,
                  '复制会话调试包',
                ),
              _moreMenuItem(
                _ConversationMoreAction.voicePrefs,
                Icons.record_voice_over_outlined,
                '语音偏好',
              ),
            ],
          ),
        ],
      );

  PopupMenuItem<_ConversationMoreAction> _moreMenuItem(
    _ConversationMoreAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  void _onConversationMoreAction(_ConversationMoreAction action) {
    switch (action) {
      case _ConversationMoreAction.taskMode:
        _openTaskMode();
      case _ConversationMoreAction.workspace:
        _openWorkspace();
      case _ConversationMoreAction.outline:
        _openOutline();
      case _ConversationMoreAction.assistantProfile:
        _openAssistantProfile();
      case _ConversationMoreAction.roleContext:
        _openRoleContextPreview();
      case _ConversationMoreAction.roleDebug:
        _copyConversationRoleDebugPackage();
      case _ConversationMoreAction.voicePrefs:
        _openVoicePrefs();
    }
  }

  String _aiName = '';

  Widget get _appBarTitle {
    final assistant = _assistant;
    final subtitle = _roleSubtitle;
    final visualTheme = AppVisualTheme.of(context);
    final theme = Theme.of(context);
    final titleText = visualTheme.isAnime
        ? Text(
            subtitle.isEmpty ? _title : '$_title · $subtitle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ],
          );
    if (assistant == null) return titleText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AssistantAvatar(assistant: assistant, radius: 17),
        const SizedBox(width: 8),
        Flexible(child: titleText),
      ],
    );
  }

  String get _title {
    if (_isStreaming) return '对方正在输入...';
    if (_aiName.isNotEmpty) return '与$_aiName的会话';
    return 'ChatGPT';
  }

  String get _roleSubtitle {
    final assistant = _assistant;
    if (assistant == null) return '';
    final description = assistant.description.trim();
    if (description.isNotEmpty) return description;
    final summary = AssistantRoleCardService.summarize(assistant);
    final parts = <String>[
      if (summary.memoryCount > 0) '世界书 ${summary.memoryCount}',
      if (_assistantMemories.isNotEmpty) '记忆 ${_assistantMemories.length}',
      if (summary.hasDefaultVoice) '语音 ${assistant.defaultVoiceStyle.trim()}',
    ];
    return parts.join(' · ');
  }

  void _openRoleContextPreview() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RoleContextPreviewSheet(
        assistant: _assistant,
        conversation: widget.conversationModel,
        memories: _assistantMemories,
        recentMessages: _recentRoleMemoryMessages(),
      ),
    );
  }

  String _modelLabel(AISettings settings) {
    final effective = _effective(settings);
    final model = effective.effectiveModel;
    final prefix = widget.conversationModel.modelId == null ? '跟随全局' : '当前模型';
    if (effective.mode == AIMode.backend) return '$prefix：$model';
    return '$prefix：${effective.activeProvider.name} · $model';
  }

  _inputWidget(ModelCapabilities caps, AISettings settings) {
    final effective = _effective(settings);
    final supportsEffort = ReasoningControlAdapter.supportsDeepSeekEffort(
      providerId: effective.mode == AIMode.local
          ? effective.activeProvider.id
          : 'deepseek',
      providerCode: ChatService.providerCodeFor(effective),
      modelId: effective.effectiveModel,
    );
    return MessageInputWidget(
      '请输入',
      enable: _ready && !_isStreaming && !_savingReasoningEffort,
      editingEnabled: _ready && !_isStreaming && !_savingReasoningEffort,
      isStreaming: _isStreaming,
      controller: _inputController,
      referencesEnabled: true,
      referenceScopeKey: '$_pageAccount:${widget.conversationModel.cid}',
      isReferenceScopeCurrent: () => _accountCurrent,
      references: _references,
      pickHistoryReference: _pickHistoryReference,
      onReferencePicked: _addReference,
      onRemoveReference: _removeReference,
      onPreviewReference: _previewReference,
      onReferencePickerChanged: (open) {
        if (!mounted || !_accountCurrent) return;
        _invalidatePrediction();
        setState(() => _referencePickerOpen = open);
      },
      suggestedMessage: _predictionEligible ? _prediction.suggestion : null,
      onAcceptSuggestion: _acceptPrediction,
      onDismissSuggestion: _prediction.cancel,
      clearOnSend: false,
      onStop: _isStreaming ? _stopStream : null,
      onChanged: _inputChanged,
      canSend: () =>
          _ready &&
          !_savingReasoningEffort &&
          _accountCurrent &&
          _canStartAIRequest(showPrompt: true),
      onSend: () => _onSend(_inputMessage),
      // 联网搜索开关（阶段五）：当前所选服务商配置了 key 才展示；独立于
      // caps.tool，搜索结果以上下文回填，任何模型都可用（与 Cherry 一致）。
      showWebSearch: effective.webSearchConfigured,
      webSearchEnabled: effective.webSearchEnabled,
      onToggleWebSearch: _toggleWebSearch,
      modelLabel: _modelLabel(settings),
      onModelTap: _switchModel,
      modelAccessory: supportsEffort
          ? DeepSeekReasoningSelector(
              effort: widget.conversationModel.deepSeekReasoningEffort,
              onTap: _ready && !_isStreaming && !_savingReasoningEffort
                  ? _selectReasoningEffort
                  : null,
            )
          : null,
      speechInputEnabled: widget.conversationModel.speechInputEnabled ?? true,
      speechLocale: widget.conversationModel.voiceLocale,
      pendingImages: _pendingImages,
      imagesEnabled: caps.image,
      imagesDisabledReason:
          caps.image ? '' : '当前模型不支持图片，请切换 deepseek-flash、gpt-4o 等多模态模型',
      onImagesPicked: (images) => _setAttachmentPaths(images, photo: true),
      onRemoveImage: (index) {
        _setAttachmentPaths(List.from(_pendingImages)..removeAt(index),
            photo: true);
      },
      // 文件入口不按能力位关闭：不支持原生文件的模型走抽文本降级（阶段四）。
      pendingFiles: _pendingFiles,
      onFilesPicked: (files) => _setAttachmentPaths(files, photo: false),
      onRemoveFile: (index) {
        _setAttachmentPaths(List.from(_pendingFiles)..removeAt(index),
            photo: false);
      },
    );
  }

  void _setAttachmentPaths(List<String> paths, {required bool photo}) {
    if (!_accountCurrent || !_ready || _isStreaming) return;
    final kind =
        photo ? ComposerReferenceKind.photo : ComposerReferenceKind.file;
    final unique = paths
        .map((path) {
          final identity =
              ComposerReference.attachment(path, photo: photo).sourceIdentity;
          final existing = _references
              .where((r) =>
                  r.kind == kind &&
                  (r.attachmentPath == path || r.sourceIdentity == identity))
              .firstOrNull;
          return existing?.attachmentPath ?? path;
        })
        .toSet()
        .toList();
    _invalidatePrediction();
    setState(() {
      _references = _references
          .where((r) =>
              r.kind != kind ||
              !r.available ||
              unique.contains(r.attachmentPath))
          .toList();
      for (final path in unique) {
        if (!_references
            .any((r) => r.kind == kind && r.attachmentPath == path)) {
          _references.add(ComposerReference.attachment(path, photo: photo));
        }
      }
      if (photo) {
        _pendingImages = unique;
      } else {
        _pendingFiles = unique;
      }
    });
    _inputChanged(_inputController.text);
    _draftTimer?.cancel();
    unawaited(_saveDraft());
  }

  Future<void> _previewReference(ComposerReference reference) async {
    if (!_accountCurrent || !_ready || _isStreaming) return;
    final cid = widget.conversationModel.cid;
    final revision = _draftRevision;
    bool current() =>
        mounted &&
        _accountCurrent &&
        !_isStreaming &&
        widget.conversationModel.cid == cid &&
        _draftRevision == revision;
    if (reference.kind == ComposerReferenceKind.historyMessage) {
      await showReferencePreview(context, reference, isCurrent: current);
      return;
    }
    try {
      _draftTimer?.cancel();
      final frozen = await _freezeReferences(context
          .read<AISettingsProvider>()
          .settings
          .attachmentProcessingLimits);
      if (!current()) return;
      // 预览取消了防抖，冻结后立即保存最新草稿；容量不足仅提示，不阻止预览。
      await _saveDraft();
      final preview = frozen.previewForReference(reference.id);
      if (!mounted || !current() || preview == null) return;
      await showDraftAttachmentPreview(context, preview, isCurrent: current);
    } catch (_) {
      if (!current()) return;
      // 冻结失败也取消了防抖，立即保留最新正文与不可用标签，避免退出后丢失。
      final saved = await _saveDraft();
      if (!mounted || !current()) return;
      HiDialog.showSnackBar(
          context,
          saved == null
              ? '引用无法冻结或已合并，请重新选择；草稿未能保存，请保留当前页面后重试'
              : '引用无法冻结或已合并，请重新选择');
    }
  }

  void _addReference(ComposerReference reference) {
    if (!_accountCurrent ||
        !_ready ||
        _isStreaming ||
        reference.historySnapshot?.accountToken !=
            AccountResourceScope.tokenFor(_pageAccount)) {
      return;
    }
    _invalidatePrediction();
    if (_references.any((r) => r.sourceIdentity == reference.sourceIdentity)) {
      return;
    }
    setState(() => _references = [..._references, reference]);
    _inputChanged(_inputController.text);
  }

  void _removeReference(String id) {
    if (!_accountCurrent || _isStreaming) return;
    _invalidatePrediction();
    setState(() {
      _references = _references.where((r) => r.id != id).toList();
      _pendingImages = _references
          .where((r) => r.kind == ComposerReferenceKind.photo && r.available)
          .map((r) => r.attachmentPath)
          .whereType<String>()
          .toList();
      _pendingFiles = _references
          .where((r) => r.kind == ComposerReferenceKind.file && r.available)
          .map((r) => r.attachmentPath)
          .whereType<String>()
          .toList();
    });
    _inputChanged(_inputController.text);
  }

  Future<ComposerReference?> _pickHistoryReference() async {
    if (!_accountCurrent || !_ready || _isStreaming) return null;
    final value = _inputController.value;
    final cid = widget.conversationModel.cid;
    bool current() =>
        mounted &&
        _accountCurrent &&
        !_isStreaming &&
        widget.conversationModel.cid == cid &&
        _inputController.value == value;
    final result = await showModalBottomSheet<ComposerReference>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => HistoryReferencePicker(
            dao: MessageReferenceDao(messageDao.storage,
                accountHash: _pageAccount),
            isCurrent: current));
    return current() ? result : null;
  }

  @override
  void initState() {
    super.initState();
    _cardCid = widget.conversationModel.cid;
    _backgroundExecution =
        widget.backgroundExecution ?? PlatformAgentBackgroundExecution.instance;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _applicationInBackground = lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached;
    WidgetsBinding.instance.addObserver(this);
    _pageAccount = widget.expectedAccountHash ??
        context.read<AISettingsProvider>().accountHash;
    _draftOnlyConversation = widget.conversationModel.messageCount == 0 &&
        (widget.conversationModel.lastMessage?.startsWith('[草稿] ') ?? false);
    _prediction =
        ComposerPredictionController(service: widget.predictionService)
          ..addListener(_onPredictionChanged);
    _predictionSettings = context.read<AISettingsProvider>()
      ..addListener(_invalidatePrediction);
    _inputController = TextEditingController(text: widget.initialPrompt);
    _inputMessage = widget.initialPrompt;
    _draftStore = widget.draftStore ??
        ConversationDraftStore(
          conversationId: widget.conversationModel.cid.toString(),
          accountHash: _pageAccount,
        );
    _readAloudService = widget.readAloudService ?? HybridReadAloudService();
    if (_accountCurrent) _prewarmReadAloudIfNeeded();
    _doInit();
  }

  @override
  void didUpdateWidget(covariant ConversationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationModel.cid != widget.conversationModel.cid) {
      _invalidatePrediction();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _applicationInBackground = false;
      return;
    }
    // inactive 也会因系统文件选择器、权限弹窗出现，不代表已进入后台。
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    if (_applicationInBackground && state != AppLifecycleState.detached) return;
    _applicationInBackground = true;
    _invalidatePrediction();
    if (_agentRun?.busy == true) {
      if (_toolConfirmationRoute != null) _dismissToolConfirmation();
      return;
    }
    if (_taskMode && _isStreaming && _accountCurrent) {
      if (state == AppLifecycleState.detached ||
          _toolConfirmationRoute != null ||
          !_hasBackgroundLease) {
        _stopStream(
            reason: _toolConfirmationRoute != null
                ? '操作需要确认，进入后台后任务已暂停'
                : '应用进入后台，任务已暂停');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _predictionSettings.removeListener(_invalidatePrediction);
    _prediction.removeListener(_onPredictionChanged);
    _prediction.dispose();
    _draftTimer?.cancel();
    _taskExecutor.removeListener(_syncAgentRun);
    _taskExecutor.unbindConfirmation(_taskKey, this);
    if (_agentRun?.busy != true) _stopBackgroundAfterCheckpoint();
    // 快照必须先于 dispose；草稿写入只使用固定账号，不跟随新登录账号。
    if (_draftLoaded && _accountCurrent) {
      if (_ready &&
          _draftOnlyConversation &&
          _inputController.text.trim().isEmpty &&
          _pendingImages.isEmpty &&
          _pendingFiles.isEmpty &&
          _references.isEmpty &&
          !chatController.initialMessageList.any((m) => m.createdAt > 0)) {
        widget.conversationModel.title = null;
        widget.conversationModel.lastMessage = null;
        _draftOnlyConversation = false;
        unawaited(conversationListDao.storage.db
            .rawDelete(
                'delete from tb_conversation_list where cid = ? and not exists '
                '(select 1 from tb_messages where cid = ?)',
                [widget.conversationModel.cid, widget.conversationModel.cid])
            .then((_) => AppEvents.notifyConversationsChanged())
            .catchError((_) {}));
      }
      _markNewDraftConversation(
          _inputController.text, _pendingImages, _pendingFiles, _references);
      if (_draftOnlyConversation) {
        unawaited(conversationListDao
            .saveConversation(widget.conversationModel)
            .then((_) => AppEvents.notifyConversationsChanged())
            .catchError((_) {}));
      }
      unawaited(_draftStore
          .save(
            text: _inputController.text,
            images: List.from(_pendingImages),
            files: List.from(_pendingFiles),
            references: List.from(_references),
          )
          .catchError((_) => null));
    }
    if (_taskMode && _isStreaming && _agentRun?.busy != true) {
      _userStopped = true;
      _activeDispatcher?.onStopped();
      final task = _agentTask;
      if (task != null) {
        unawaited(task.pause('已离开对话，可从保存的进度继续').catchError(
            (Object error) => AILogger.log('pause task failed: $error')));
      }
    }
    _dismissToolConfirmation();
    _disposed = true;
    // 流式中途离开页面：先把已收到的块落库，避免半截回复丢失（旧逻辑在
    // catch/stop 分支里保存，新流程只在 completer 解开后保存，而 cancel 不触发
    // onDone，所以这里必须主动收尾）。快照是同步读取的，先于 _blockStore.dispose()。
    final dispatcher = _activeDispatcher;
    final receiver = _activeReceiver;
    if (dispatcher != null && receiver != null) {
      // fire-and-forget：DB 写不依赖 widget 生命周期；不触碰 UI / 不 notify store。
      _persistAssistant(receiver, dispatcher);
    }
    // 完成挂起的 completer，让 _onSendStream 的 await 解开（其后续会因 _disposed 跳过）。
    final c = _streamCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _abortStreamRequest();
    _cancelActiveEventSubscription();
    unawaited(_readAloudService.stop());
    _itemPositionsListener.itemPositions.removeListener(_onPositionsChanged);
    _blockStore.dispose();
    if (_agentRun?.busy != true) _updateConversation();
    _inputController.dispose();
    super.dispose();
    //fix A ScrollController was used after being disposed.
    // chatController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 能力探测响应式：watch settings，用户在「AI 服务设置」改模型返回本页时
    // 立即重算能力位并刷新图片入口（修复阶段三复审遗留 1：原先缓存在字段里，
    // 要等下次发送才更新）。与 completionDao.capabilities 同源（见 ChatService）。
    final settings = context.watch<AISettingsProvider>().settings;
    if (!_accountCurrent) {
      return Scaffold(
        appBar: AppBar(title: const Text('对话')),
        body: const Center(child: Text('账号已切换，请返回当前账号的对话')),
      );
    }
    // 阶段七：助手指定了模型时，能力位用覆盖后的模型算（同 _onSend 的请求路径）。
    final caps = ChatService.capabilitiesFor(_effective(settings));
    _aiName = (_assistant?.name.isNotEmpty ?? false)
        ? _assistant!.name
        : settings.aiDisplayName;
    // 把块仓库提供给气泡内部的块渲染（BlockMessageContent 用 Selector 精确订阅）。
    return ChangeNotifierProvider<ChatBlockStore>.value(
      value: _blockStore,
      child: Scaffold(
        appBar: _appBar,
        body: Column(
          children: [
            _chatList,
            if (_agentTask != null)
              AgentTaskPanel(
                  session: _agentTask!,
                  busy: _isStreaming || _savingReasoningEffort,
                  onOpen: _openTaskMode,
                  onResume: _resumeTask,
                  onDetails: _openTaskDetails,
                  onResolveFailure: _resolveTaskFailure,
                  backgroundNotice: _isStreaming ? _backgroundNotice : null,
                  queued: _agentRun?.queued == true,
                  queuePosition: _taskExecutor.queuePosition(_taskKey),
                  onCancelQueued: () => _stopStream(reason: '已取消排队，可继续任务'),
                  verificationSummary:
                      _workspaceTools?.lastReport?.hasChecks == true
                          ? _workspaceTools!.lastReport!.summary
                          : null),
            ChatSendStatusPanel(
              progress: _sendProgress,
              busy: _isStreaming,
              draftNotice: _draftNotice,
              contextPlan: _contextPlan,
              attachmentsPending: !_contextAttachmentsPrepared &&
                  (_pendingImages.isNotEmpty || _pendingFiles.isNotEmpty),
              onCancel: _isStreaming ? _stopStream : null,
              onPreview: _ready ? _showContextPreview : null,
              onDismissDraft: () => setState(() => _draftNotice = null),
            ),
            if (_ready &&
                !_isStreaming &&
                chatController.initialMessageList.isNotEmpty &&
                chatController.initialMessageList.first.ownerType ==
                    OwnerType.sender)
              TextButton.icon(
                  key: const ValueKey('retry_unanswered_chat_prompt'),
                  onPressed: () => _retryUserMessage(
                      chatController.initialMessageList.first),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试上次未完成的提问')),
            _inputWidget(caps, settings),
          ],
        ),
      ),
    );
  }

  /// 切换联网搜索开关：当前会话优先覆盖，避免改动全局 AI 设置影响其它会话。
  void _toggleWebSearch() async {
    if (!_ready || !_accountCurrent || _isStreaming || _savingReasoningEffort) {
      return;
    }
    final effective = _effective(context.read<AISettingsProvider>().settings);
    final enabled = !effective.webSearchEnabled;
    setState(() => widget.conversationModel.webSearchEnabled = enabled);
    widget.conversationModel.hadChanged = true;
    await conversationListDao.updateWebSearchOverride(
        widget.conversationModel, enabled);
    if (!mounted) return;
    HiDialog.showSnackBar(context, enabled ? '当前会话已开启联网搜索' : '当前会话已关闭联网搜索');
  }

  /// 气泡内部内容构造器（注入给 chat_message 包）：
  /// 已有块的消息 -> 块化渲染（assistant 的流式块、用户的文件/图片块），
  /// 其余（纯文本/纯图片用户消息、旧的无块消息）-> 回退默认渲染。
  Widget? _buildBlockContent(BuildContext context, MessageModel message) {
    final key = chatMessageKey(message.createdAt);
    final hasBlocks = _blockStore.hasBlocks(key);
    final hasPersistedRoleContext = hasBlocks &&
        _blockStore.blocksFor(key).whereType<RoleContextBlock>().isNotEmpty;
    final roleStatePanel = _roleStatePanel(message.createdAt);
    final hasRoleStatePanel = roleStatePanel != null;
    final memoryPanel = _memoryHitPanel(message.createdAt);
    final hasMemoryPanel = memoryPanel != null;
    final roleContextPanel =
        hasPersistedRoleContext ? null : _roleContextPanel(message.createdAt);
    final hasRoleContextPanel = roleContextPanel != null;
    final suggestionPanel = _memorySuggestionPanel(message.createdAt);
    final hasSuggestionPanel = suggestionPanel != null;
    if (!hasBlocks &&
        message.ownerType != OwnerType.receiver &&
        !hasRoleStatePanel &&
        !hasMemoryPanel &&
        !hasRoleContextPanel &&
        !hasSuggestionPanel) {
      return null;
    }
    if (!hasBlocks && message.content.trim().isEmpty) return null;
    if (!hasBlocks) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message.content),
          if (hasRoleStatePanel) roleStatePanel,
          if (hasMemoryPanel) memoryPanel,
          if (hasRoleContextPanel) roleContextPanel,
          if (hasSuggestionPanel) suggestionPanel,
          if (message.ownerType == OwnerType.receiver)
            MessageFooterBar(
              charCount: message.content.characters.length,
              trailing: _readAloudBubbleButton(
                  context, message.content, message.createdAt),
            ),
        ],
      );
    }
    // 仅 assistant 回复显示生成字数（流式中实时累加）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        BlockMessageContent(
          enableInteractiveCards: message.ownerType == OwnerType.receiver,
          cardReplyCompleted: _cardRows.containsKey(message.createdAt),
          cardsWritable: _cardScopeCurrent &&
              !_isStreaming &&
              _cardRows.containsKey(message.createdAt),
          cardInsertEnabled: _cardScopeCurrent &&
              _ready &&
              !_isStreaming &&
              !_savingReasoningEffort,
          cardScopeCurrent: () =>
              _cardScopeCurrent &&
              chatController.initialMessageList
                  .any((m) => m.createdAt == message.createdAt),
          onCardCheck: (block, card, item, checked) =>
              _setCardChecked(message.createdAt, block, card, item, checked),
          onCardInsert: (text) => _insertCardText(text, _cardCid),
          sourceAccountHash: _pageAccount,
          messageKey: key,
          showCharCount: message.ownerType == OwnerType.receiver,
          footerTrailing: message.ownerType == OwnerType.receiver
              ? _readAloudBubbleButton(
                  context, message.content, message.createdAt)
              : null,
        ),
        if (message.ownerType == OwnerType.receiver)
          Selector<ChatBlockStore, bool>(
            selector: (_, store) =>
                store.blocksFor(key).whereType<ErrorBlock>().isNotEmpty,
            builder: (_, failed, __) => failed &&
                    chatController.initialMessageList.isNotEmpty &&
                    chatController.initialMessageList.first.createdAt ==
                        message.createdAt
                ? TextButton.icon(
                    key: const ValueKey('retry_failed_chat_reply'),
                    onPressed: () => _regenerate(message),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试此条提问'))
                : const SizedBox.shrink(),
          ),
        if (hasRoleStatePanel) roleStatePanel,
        if (hasMemoryPanel) memoryPanel,
        if (hasRoleContextPanel) roleContextPanel,
        if (hasSuggestionPanel) suggestionPanel,
      ],
    );
  }

  Widget? _roleStatePanel(int createdAt) {
    final lines = _roleStateByMessageAt[createdAt];
    if (lines == null || lines.isEmpty) return null;
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground = visual.isAnime ? scheme.secondary : Colors.teal[700]!;
    final background = visual.isAnime
        ? scheme.secondaryContainer.withValues(alpha: 0.72)
        : Colors.teal.withValues(alpha: 0.08);
    final borderColor = visual.isAnime
        ? scheme.secondary.withValues(alpha: 0.22)
        : Colors.teal.withValues(alpha: 0.18);
    final bodyColor = visual.isAnime ? scheme.onSurfaceVariant : Colors.black54;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.theater_comedy_outlined, size: 16, color: foreground),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '已带入当前会话状态',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制会话状态摘要',
                visualDensity: visual.isAnime
                    ? VisualDensity.standard
                    : VisualDensity.compact,
                constraints: BoxConstraints.tightFor(
                  width: visual.isAnime ? 44 : 28,
                  height: visual.isAnime ? 44 : 28,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.copy_outlined, size: 15),
                color: foreground,
                onPressed: () => _copyRoleStateSummary(lines),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final line in lines.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: bodyColor),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _copyRoleStateSummary(List<String> lines) async {
    if (lines.isEmpty) return;
    final assistantName = _assistant?.name.trim();
    final title = assistantName == null || assistantName.isEmpty
        ? '本轮当前会话状态'
        : '$assistantName · 本轮当前会话状态';
    final text = ['# $title', ...lines].join('\n').trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '会话状态摘要已复制');
  }

  Widget? _memoryHitPanel(int createdAt) {
    final hits = _roleMemoryHitsFor(createdAt);
    if (hits.isEmpty) return null;
    final budget = _roleMemoryBudgetFor(createdAt);
    final expanded = _expandedMemoryHits.contains(createdAt);
    final visibleHits = expanded ? hits : hits.take(3).toList();
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground = visual.isAnime ? scheme.tertiary : Colors.blueGrey[700]!;
    final secondaryForeground =
        visual.isAnime ? scheme.onSurfaceVariant : Colors.blueGrey[600]!;
    final background = visual.isAnime
        ? scheme.tertiaryContainer.withValues(alpha: 0.72)
        : Colors.blueGrey.withValues(alpha: 0.08);
    final borderColor = visual.isAnime
        ? scheme.tertiary.withValues(alpha: 0.22)
        : Colors.blueGrey.withValues(alpha: 0.16);
    final bodyColor = visual.isAnime ? scheme.onSurfaceVariant : Colors.black54;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories_outlined, size: 16, color: foreground),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  AssistantRoleCardService.memoryHitSummary(hits),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制命中摘要',
                visualDensity: visual.isAnime
                    ? VisualDensity.standard
                    : VisualDensity.compact,
                constraints: BoxConstraints.tightFor(
                  width: visual.isAnime ? 44 : 28,
                  height: visual.isAnime ? 44 : 28,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.copy_outlined, size: 15),
                color: foreground,
                onPressed: () => _copyMemoryHitSummary(hits),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (budget?.affected == true)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '世界书预算：${budget!.compactSummary}',
                style: TextStyle(fontSize: 11, color: secondaryForeground),
              ),
            ),
          for (final hit in visibleHits)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                AssistantRoleCardService.memoryHitPreviewLine(hit),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: bodyColor),
              ),
            ),
          if (hits.length > 3)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    if (expanded) {
                      _expandedMemoryHits.remove(createdAt);
                    } else {
                      _expandedMemoryHits.add(createdAt);
                    }
                  });
                },
                style: visual.isAnime
                    ? TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      )
                    : TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                icon: Icon(
                  expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 16,
                ),
                label: Text(
                  expanded ? '收起命中设定' : '展开全部 ${hits.length} 条',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _copyMemoryHitSummary(
      List<AssistantMemoryEntryPreview> hits) async {
    final text = AssistantRoleCardService.memoryHitCopyText(hits).trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '角色记忆命中摘要已复制');
  }

  Widget? _roleContextPanel(int createdAt) {
    final snapshot = _roleContextByMessageAt[createdAt]?.trim();
    if (snapshot == null || snapshot.isEmpty) return null;
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        visual.isAnime ? scheme.primary : Colors.deepPurple[700]!;
    final background = visual.isAnime
        ? scheme.primaryContainer.withValues(alpha: 0.72)
        : Colors.deepPurple.withValues(alpha: 0.08);
    final borderColor = visual.isAnime
        ? scheme.primary.withValues(alpha: 0.22)
        : Colors.deepPurple.withValues(alpha: 0.16);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.fact_check_outlined, size: 16, color: foreground),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '已记录本轮完整上下文',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _showRoleContextSnapshot(snapshot),
            style: visual.isAnime
                ? TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  )
                : TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
            child: const Text('查看', style: TextStyle(fontSize: 11)),
          ),
          IconButton(
            tooltip: '复制本轮上下文',
            visualDensity:
                visual.isAnime ? VisualDensity.standard : VisualDensity.compact,
            constraints: BoxConstraints.tightFor(
              width: visual.isAnime ? 44 : 28,
              height: visual.isAnime ? 44 : 28,
            ),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.copy_outlined, size: 15),
            color: foreground,
            onPressed: () => _copyRoleContextSnapshot(snapshot),
          ),
        ],
      ),
    );
  }

  Future<void> _copyRoleContextSnapshot(String snapshot) async {
    final text = _roleContextSnapshotCopyText(snapshot);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '本轮上下文已复制');
  }

  String _roleContextSnapshotCopyText(String snapshot) {
    final text = snapshot.trim();
    if (text.isEmpty) return '';
    final assistantName = _assistant?.name.trim();
    final title = assistantName == null || assistantName.isEmpty
        ? '本轮完整上下文'
        : '$assistantName · 本轮完整上下文';
    return ['# $title', text].join('\n').trim();
  }

  void _showRoleContextSnapshot(String snapshot) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final maxHeight = MediaQuery.of(ctx).size.height * 0.72;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '本轮完整上下文',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '复制本轮上下文',
                      onPressed: () => _copyRoleContextSnapshot(snapshot),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      snapshot,
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget? _memorySuggestionPanel(int createdAt) {
    final suggestion = _memorySuggestionsByMessageAt[createdAt];
    if (suggestion == null ||
        _dismissedMemorySuggestions.contains(createdAt) ||
        AssistantMemoryDao.hasDuplicateContent(
            _assistantMemories, suggestion)) {
      return null;
    }
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final warning = AppStatusPalette.of(context, AppStatusKind.warning);
    final foreground = visual.isAnime ? warning.foreground : Colors.amber[900]!;
    final background = visual.isAnime
        ? warning.container
        : Colors.amber.withValues(alpha: 0.12);
    final borderColor = visual.isAnime
        ? warning.foreground.withValues(alpha: 0.20)
        : Colors.amber.withValues(alpha: 0.24);
    final bodyColor = visual.isAnime ? scheme.onSurfaceVariant : Colors.black54;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lightbulb_outline, size: 16, color: foreground),
              const SizedBox(width: 4),
              Text(
                '建议记住',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            suggestion,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () =>
                    _confirmMemorySuggestion(createdAt, suggestion),
                style: visual.isAnime
                    ? TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      )
                    : TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                child: const Text('记住'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _dismissedMemorySuggestions.add(createdAt));
                },
                style: visual.isAnime
                    ? TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      )
                    : TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                child: const Text('忽略'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _readAloudBubbleButton(
      BuildContext context, String text, int createdAt) {
    final content = text.trim();
    if (content.isEmpty) return const SizedBox.shrink();
    final mode = _ReadAloudTriggerMode.normalize(
        widget.conversationModel.readAloudTriggerMode);
    final active = _readAloudActiveMessageAt == createdAt;
    if (mode != _ReadAloudTriggerMode.button && !active) {
      return const SizedBox.shrink();
    }
    final busy = _manualReadAloudInFlight != null;
    final colorScheme = Theme.of(context).colorScheme;
    final disabled = busy && !active;
    final stage = active ? _readAloudStage : null;
    final generating = ReadAloudStageUi.showsProgress(stage);
    final playing = active && stage == ReadAloudStage.playing;
    final foreground = disabled
        ? colorScheme.onSurfaceVariant
        : playing
            ? colorScheme.error
            : generating
                ? colorScheme.primary
                : active
                    ? colorScheme.tertiary
                    : colorScheme.onSurfaceVariant;
    final background = disabled
        ? colorScheme.onSurface.withValues(alpha: 0.045)
        : playing
            ? colorScheme.error.withValues(alpha: 0.10)
            : generating
                ? colorScheme.primary.withValues(alpha: 0.12)
                : active
                    ? colorScheme.tertiary.withValues(alpha: 0.12)
                    : colorScheme.onSurface.withValues(alpha: 0.055);
    final onTap = active
        ? _stopManualReadAloud
        : disabled
            ? null
            : () => _readAloudAssistantManually(content, createdAt);
    final statusLabel = ReadAloudStageUi.label(stage);
    final label = active
        ? playing
            ? '停止'
            : statusLabel
        : '朗读';
    final icon = active
        ? playing
            ? Icons.stop_circle_outlined
            : stage == ReadAloudStage.preparing
                ? Icons.hourglass_empty_rounded
                : Icons.graphic_eq_rounded
        : Icons.volume_up_outlined;
    return Tooltip(
      message: active ? '停止朗读' : '播放音频',
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: active
            ? playing
                ? '停止朗读，当前$statusLabel'
                : '停止朗读，当前$label'
            : '播放音频',
        child: Opacity(
          opacity: disabled ? 0.48 : 1,
          child: Material(
            color: background,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              key: const ValueKey('assistant_read_aloud_button'),
              borderRadius: BorderRadius.circular(999),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (active && ReadAloudStageUi.showsProgress(stage)) ...[
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: foreground,
                          ),
                        ),
                      ] else
                        Icon(
                          icon,
                          size: 17,
                          color: foreground,
                        ),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ///不用_inputMessage是因为在结果回来之前_inputMessage可能会变
  Future<void> _onSend(final String inputMessage) async {
    final personalTurnStartedAt = DateTime.now().millisecondsSinceEpoch;
    if (inputMessage.trim().isEmpty &&
        _pendingImages.isEmpty &&
        _pendingFiles.isEmpty &&
        _references.isEmpty) {
      return;
    }
    if (!_ready ||
        !_accountCurrent ||
        _isStreaming ||
        _referencePickerOpen ||
        _savingReasoningEffort ||
        !_canStartAIRequest(showPrompt: true)) {
      return;
    }
    if (_references.any((r) => !r.available)) {
      HiDialog.showSnackBar(context, '有不可用引用，请移除或重新选择后发送');
      return;
    }
    _invalidatePrediction();
    // 锁覆盖附件准备、持久化及网络等待，停止准备时仍保留输入和草稿。
    _draftTimer?.cancel();
    _userStopped = false;
    _streamAbortCompleter = Completer<void>();
    final settled = Completer<void>();
    _sendRoundSettled = settled;
    _taskCheckpointFailed = false;
    _backgroundNotice = null;
    setState(() {
      _isStreaming = true;
      _sendProgress = const ChatSendProgress('准备发送');
    });
    var accepted = false;
    var handedOff = false;
    _personalMemoryTurn = null;
    try {
      _personalMemoryTurn = await _personalMemoryDao?.beginTurn(
          cid: widget.conversationModel.cid,
          assistantId: widget.conversationModel.assistantId,
          taskMode: _taskMode,
          rawInput: inputMessage,
          startedAt: personalTurnStartedAt);
      if (!mounted || _sendCancelled) return;
      final rawSettings = context.read<AISettingsProvider>().settings;
      final assistantSystemPrompt =
          await _assistantSystemPromptForSafely(inputMessage);
      if (_sendCancelled) return;
      final modelChanged =
          _daoModelProviderId != widget.conversationModel.modelProviderId ||
              _daoModelId != widget.conversationModel.modelId ||
              _daoReasoningEffort !=
                  widget.conversationModel.deepSeekReasoningEffort;
      if (rawSettings != _currentSettings ||
          !identical(_assistant, _daoAssistant) ||
          assistantSystemPrompt != _daoSystemPrompt ||
          _daoTaskMode != _taskMode ||
          modelChanged) {
        _currentSettings = rawSettings;
        _daoAssistant = _assistant;
        _daoSystemPrompt = assistantSystemPrompt;
        _daoModelProviderId = widget.conversationModel.modelProviderId;
        _daoModelId = widget.conversationModel.modelId;
        _daoReasoningEffort = widget.conversationModel.deepSeekReasoningEffort;
        _daoTaskMode = _taskMode;
        completionDao = CompletionDao(
          memoryContextResolver: _memoryResolver(),
          chatService: widget.chatService,
          manageContext: true,
          settings: _effective(rawSettings),
          systemPrompt: assistantSystemPrompt,
          messages: completionDao.currentMessages,
          toolHistory: completionDao.currentToolHistory,
          fileHistory: completionDao.currentFileHistory,
          roleContinuationHistory: completionDao.currentRoleContinuationHistory,
          protocolHistory: completionDao.currentProtocolHistory,
          conversationId: widget.conversationModel.cid,
          semanticSummaryService: _summaryServiceFor(_effective(rawSettings)),
        );
      }
      final settings = _effective(rawSettings);
      final caps = ChatService.capabilitiesFor(settings);
      final frozen =
          await _freezeReferences(settings.attachmentProcessingLimits);
      if (_sendCancelled) return;
      final references =
          List<ComposerReference>.unmodifiable(frozen.references);
      final pendingImages = List<String>.from(frozen.imagePaths);
      final pendingFiles = List<String>.from(frozen.filePaths);
      final batchBudget = AttachmentBatchBudget(
          limits: settings.attachmentProcessingLimits,
          expectedDigests: {
            for (final reference in references)
              if (reference.attachmentPath != null &&
                  reference.snapshotDigest.isNotEmpty)
                reference.attachmentPath!: reference.snapshotDigest
          });
      _onSendProgress(const ChatSendProgress('检查附件总大小'));
      await batchBudget.preflightPaths([...pendingImages, ...pendingFiles],
          isCancelled: () => _sendCancelled);
      if (_sendCancelled) return;
      final abort = _streamAbortCompleter!.future;
      final imagePaths = <String>[];
      final b64Images = pendingImages.isEmpty
          ? <String>[]
          : await FileProcessor.encodeImages(pendingImages,
              batchBudget: batchBudget,
              onSnapshot: (_, managedPath) => imagePaths.add(managedPath),
              onProgress: _onSendProgress,
              abortTrigger: abort,
              isCancelled: () => _sendCancelled);
      final officialDeepSeek = (settings.mode == AIMode.backend &&
              ModelCapabilities.isDeepSeekVisionModel(
                  settings.effectiveModel)) ||
          (settings.mode == AIMode.local &&
              Uri.tryParse(settings.activeLocal.baseUrl)?.host.toLowerCase() ==
                  'api.deepseek.com');
      final processed = pendingFiles.isEmpty
          ? const ProcessedFiles()
          : _taskMode
              ? await _prepareWorkspaceFiles(
                  pendingFiles, settings, batchBudget)
              : await FileProcessor.process(pendingFiles,
                  officialDeepSeek ? caps.copyWith(pdf: false) : caps,
                  limits: settings.attachmentProcessingLimits,
                  batchBudget: batchBudget,
                  onProgress: _onSendProgress,
                  abortTrigger: abort,
                  isCancelled: () => _sendCancelled);
      if (_sendCancelled) return;
      final referenceText = historyReferencesExtraText(references);
      if (referenceText.isNotEmpty) {
        batchBudget.consumeText(
            '${processed.extraText.isEmpty ? '' : '\n\n'}$referenceText');
      }
      if (processed.hasWarnings &&
          !await _confirmAttachmentWarnings(processed.diagnostics)) {
        return;
      }
      if (_sendCancelled) return;
      // 编码和消息持久化使用同一份已计量的图片快照。
      final attachments = ChatAttachments(
          images: b64Images,
          nativeFiles: processed.nativeFiles,
          extraText: [processed.extraText, referenceText]
              .where((text) => text.isNotEmpty)
              .join('\n\n'));
      final webSearch =
          settings.webSearchEnabled && settings.webSearchConfigured;
      final tools = await _toolsForSend(settings, caps, webSearch);
      if (_sendCancelled) return;
      final plan = completionDao.previewContext(
          prompt: inputMessage, attachments: attachments, tools: tools);
      _plannedPrompt = inputMessage;
      _plannedAttachmentInfo =
          '${pendingImages.length} 张图片，${pendingFiles.length} 份文件，${references.where((r) => r.historySnapshot != null).length} 条历史引用';
      _plannedFileText = attachments.extraText;
      _onContextPlan(plan);
      if (!plan.canSend) throw ChatContextBudgetException(plan);
      final userModel = _genMessageModel(
          ownerType: OwnerType.sender,
          message: inputMessage,
          imagePaths: imagePaths.isEmpty ? null : imagePaths,
          imageUrlsOrB64: b64Images.isEmpty ? null : b64Images);
      final roleContextSnapshot = assistantSystemPrompt?.trim() ?? '';
      if (roleContextSnapshot.isNotEmpty) {
        _roleContextByMessageAt[userModel.createdAt] = roleContextSnapshot;
      }
      final roleStatePreview = _conversationRoleStatePreview();
      if (roleStatePreview.isNotEmpty) {
        _roleStateByMessageAt[userModel.createdAt] = roleStatePreview;
      }
      final memoryHits = _assistant == null
          ? const <AssistantMemoryEntryPreview>[]
          : await AssistantRoleCardService.matchMemoryEntriesSafely(
              _assistant!.memoryBook,
              _roleMemoryScanText(inputMessage),
            );
      if (memoryHits.isNotEmpty) {
        _memoryHitsByMessageAt[userModel.createdAt] = memoryHits;
      }
      AssistantMemoryContextBudget? memoryBudget;
      if (_assistant != null) {
        memoryBudget = await AssistantMemoryBook.budgetContextSafely(
          _assistant!.memoryBook,
          _roleMemoryScanText(inputMessage),
        );
        if (memoryBudget.affected) {
          _memoryBudgetByMessageAt[userModel.createdAt] = memoryBudget;
        }
      }
      final memorySuggestion = _assistant?.id == null
          ? null
          : AssistantMemorySuggestionService.suggestFromUserMessage(
              inputMessage,
              _assistantMemories,
            );
      if (memorySuggestion != null) {
        _memorySuggestionsByMessageAt[userModel.createdAt] = memorySuggestion;
      }

      if (_sendCancelled) return;
      if (processed.metas.isNotEmpty ||
          roleContextSnapshot.isNotEmpty ||
          referenceText.isNotEmpty) {
        await _addUserMessageWithBlocks(userModel, imagePaths, processed.metas,
            roleContextSnapshot: roleContextSnapshot,
            roleMemoryBudget:
                memoryBudget?.affected == true ? memoryBudget : null,
            roleMemoryHits: memoryHits,
            references: references);
      } else {
        await messageDao.saveMessageWithBlocks(userModel);
        if (mounted && _accountCurrent) chatController.addMessage(userModel);
        _notifyConversationListUpdate();
      }
      accepted = true;
      if (_taskMode) {
        await _agentTask!
            .begin(userAt: userModel.createdAt, input: inputMessage);
        await _workspaceTools!.beginTurn(userModel.createdAt, [
          for (final meta in processed.metas)
            if (meta.workspaceFileId != null) meta.workspaceFileId!
        ]);
      }
      _lastUserModel = userModel;
      _lastUserFileText = attachments.extraText;
      if (_draftOnlyConversation) {
        widget.conversationModel.title = null;
        _draftOnlyConversation = false;
      }
      await _saveConversationSummary(userModel);
      widget.conversationModel.hadChanged = true;
      _markUsageRound(prompt: inputMessage, settings: settings);
      _draftRevision++;
      _draftTimer?.cancel();
      if (mounted && _accountCurrent) {
        setState(() {
          _inputController.clear();
          _inputMessage = '';
          _pendingImages = [];
          _pendingFiles = [];
          _references = [];
          _draftNotice = null;
        });
      }
      _draftTimer?.cancel();
      try {
        await _draftStore.clear(discardAttachments: true);
      } catch (_) {
        if (mounted && _accountCurrent) {
          setState(() => _draftNotice = '消息已保存，草稿清理失败');
        }
      }
      if (_sendCancelled) {
        // 用户消息已入库：留下可重试的停止回复，避免重复发送提问。
        if (!_disposed && _accountCurrent) {
          await _saveFailedReply('已停止发送，可重试此条提问');
        }
        return;
      }
      if (_taskMode) {
        await _enqueueAgentRun(userModel, settings, attachments,
            webSearch: webSearch && tools == null, tools: tools);
        handedOff = true;
        return;
      }
      await _startBackgroundExecution();
      if (_sendCancelled) {
        if (!_disposed && _accountCurrent) {
          await _saveFailedReply('已停止发送，可重试此条提问');
        }
        return;
      }
      if (settings.streamEnabled) {
        await _onSendStream(inputMessage, attachments,
            webSearch: webSearch && tools == null, tools: tools);
      } else {
        await _onSendNonStream(inputMessage, attachments, webSearch: webSearch);
      }
    } catch (e) {
      if (mounted && _accountCurrent) {
        if (accepted && _lastUserModel != null) {
          await _saveFailedReply(_friendlyError(e));
        } else if (!_userStopped) {
          widget.onSendPreparationError?.call(e);
          HiDialog.showSnackBar(context, '发送前检查失败：${_friendlyError(e)}');
        }
      }
    } finally {
      _personalMemoryTurn = null;
      if (!handedOff) await _finishTaskCheckpoint(accepted: accepted);
      _settleSendRound(settled);
      await _releaseBackgroundExecution(
          success: _agentTask?.status == 'complete');
      _abortStreamRequest();
      _streamAbortCompleter = null;
      _clearUsageRound();
      if (!handedOff && mounted && _accountCurrent) {
        setState(() {
          _isStreaming = false;
          _sendProgress = null;
        });
        _requestPredictionAfterReply();
      }
      // 失败或准备阶段取消也在本轮 Future 收尾前保存，避免依赖防抖定时器。
      if (!accepted && mounted && _accountCurrent) await _saveDraft();
    }
  }

  Future<void> _saveConversationSummary(MessageModel latest) async {
    try {
      final hasHistoryReference = _blockStore
          .blocksFor(chatMessageKey(latest.createdAt))
          .any((block) => block is ReferenceBlock);
      if (latest.ownerType == OwnerType.sender &&
          !_isUsableConversationText(widget.conversationModel.title)) {
        final content = latest.content.trim();
        widget.conversationModel.title = content.isNotEmpty
            ? content
            : (latest.imageUrlsOrB64?.isNotEmpty == true
                ? '图片对话'
                : hasHistoryReference
                    ? '引用对话'
                    : '文件对话');
      }
      widget.conversationModel.lastMessage = latest.content.trim().isNotEmpty
          ? latest.content.trim()
          : hasHistoryReference
              ? '引用消息'
              : '附件消息';
      widget.conversationModel.updateAt = latest.createdAt;
      widget.conversationModel.messageCount =
          await messageDao.getMessageCount();
      widget.conversationModel.hadChanged = true;
      await conversationListDao.saveConversation(widget.conversationModel);
      AppEvents.notifyConversationsChanged();
    } catch (e) {
      // 用户消息已经入库；索引刷新失败不能阻断输入清理或导致重复发送。
      AILogger.log('conversation summary save failed: ${e.runtimeType}');
      if (mounted && _accountCurrent) {
        HiDialog.showSnackBar(context, '消息已保存，会话列表刷新失败');
      }
    }
  }

  bool get _sendCancelled => _userStopped || !_accountCurrent || !mounted;

  Future<ToolRegistry?> _toolsForSend(
      AISettings settings, ModelCapabilities caps, bool webSearch) async {
    final allowTools = _taskMode || (_assistant?.useTools ?? true);
    if (!caps.tool || !settings.streamEnabled || !allowTools) return null;
    _onSendProgress(const ChatSendProgress('准备工具'));
    final mcpTools = await _discoverMcpTools(settings);
    final registry = ToolRegistry.fromAssistant(settings, _effectiveToolIds,
        forceWebSearch: webSearch,
        actions: _toolActions(),
        extraTools: [
          ...mcpTools,
          if (_taskMode) _agentTask!.todoTool,
          if (_taskMode) ...?_workspaceTools?.tools,
          if (_taskMode) ...?_taskSkills?.tools
        ]);
    return registry.isEmpty ? null : registry;
  }

  Future<ProcessedFiles> _prepareWorkspaceFiles(List<String> paths,
          AISettings settings, AttachmentBatchBudget batchBudget) =>
      WorkspaceAttachmentProcessor(_workspace!).process(paths,
          limits: settings.attachmentProcessingLimits,
          batchBudget: batchBudget,
          onProgress: _onSendProgress,
          isCancelled: () => _sendCancelled);

  void _onContextPlan(ChatContextPlan plan) {
    if (mounted && _accountCurrent && !_userStopped) {
      setState(() {
        _contextPlan = plan;
        _contextAttachmentsPrepared = true;
      });
    }
  }

  Future<bool> _confirmAttachmentWarnings(
      List<FileProcessingDiagnostic> diagnostics) async {
    if (_sendCancelled) return false;
    final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('附件内容需要确认'),
              content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    for (final warning in diagnostics)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child:
                              Text('${warning.filename}：${warning.message}')),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('返回修改')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('继续发送')),
              ],
            ));
    return result == true && !_sendCancelled;
  }

  void _showContextPreview() {
    if (!_ready || !_accountCurrent) return;
    final plan = _contextPlan ??
        completionDao.previewContext(
            prompt: _inputController.text,
            attachments: ChatAttachments(
                extraText: historyReferencesExtraText(_references)));
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SizedBox(
              height: MediaQuery.sizeOf(ctx).height * .75,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text('本轮上下文预览', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(
                    '预计输入 ${plan.estimatedInputTokens} Token / 输入预算 ${plan.inputBudgetTokens}'),
                Text('输出预留 ${plan.reservedOutputTokens} Token'),
                Text(
                    '完整带入 ${plan.includedHistoryTurns} 轮，省略 ${plan.omittedHistoryTurns} 轮'),
                const SizedBox(height: 12),
                const Text('本轮提问'),
                SelectableText(_contextPlan == null
                    ? _inputController.text
                    : _plannedPrompt),
                if (_plannedAttachmentInfo.isNotEmpty)
                  Text(_plannedAttachmentInfo),
                if (_plannedFileText.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('附件正文摘录（最多 3000 字）'),
                  SelectableText(_plannedFileText.length > 3000
                      ? _plannedFileText.substring(0, 3000)
                      : _plannedFileText),
                ],
                if (!_contextAttachmentsPrepared &&
                    (_pendingImages.isNotEmpty || _pendingFiles.isNotEmpty))
                  const Text('附件尚未处理，此处仅预览文字；发送前会重新估算完整附件。'),
                if (_hasEarlierContext)
                  const Text('更早记录未进入候选范围，仍完整保存在本地，可从对话目录查看。'),
                for (final warning in plan.warnings)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(warning)),
                if (plan.error != null)
                  Text(plan.error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                if (plan.summary.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(plan.usesSemanticSummary ? '较早对话语义摘要' : '较早对话原文摘录'),
                  SelectableText(plan.summary),
                ],
                const SizedBox(height: 16),
                const Text('历史轮次（正文摘录）'),
                for (final turn in plan.turns.reversed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(turn.included
                        ? Icons.check_circle_outline
                        : Icons.compress),
                    title: Text(
                        '第 ${turn.index + 1} 轮 · ${turn.included ? '完整带入' : '摘录或省略'}'),
                    subtitle: Text(
                        turn.excerpt.isEmpty ? '图片、附件或工具消息' : turn.excerpt),
                  ),
              ]),
            ));
  }

  bool _canStartAIRequest({required bool showPrompt}) {
    final readiness = context.read<AIReadinessProvider?>();
    // 独立 widget 测试/嵌入方没有注册 readiness 时保持旧行为；正式 App 的
    // mainProviders 始终提供它。
    if (readiness == null) return true;

    final state = readiness.initialized
        ? resolveAIReadiness(
            settings: _effective(
              context.read<AISettingsProvider>().settings,
            ),
            isGuest: LoginDao.isGuest(),
          )
        : readiness.state;
    final decision = resolveAISendGuard(
      state: state,
      onboardingStatus: readiness.onboardingStatus,
    );
    if (decision.allowed) return true;
    if (showPrompt && !_readinessDialogOpen) {
      unawaited(_showAIReadinessBlocker(state, decision));
    }
    return false;
  }

  Future<void> _showAIReadinessBlocker(
    AIReadyState state,
    AISendGuardDecision decision,
  ) async {
    if (!mounted || _readinessDialogOpen) return;
    _readinessDialogOpen = true;
    try {
      final presentation = aiReadinessPresentation(state);
      final action = await showDialog<AISendGuardAction>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(presentation.title),
          content: Text(presentation.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            if (decision.action == AISendGuardAction.verify)
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  AISendGuardAction.configure,
                ),
                child: const Text('服务设置'),
              ),
            FilledButton(
              key: const ValueKey('ai_send_guard_primary'),
              onPressed: () => Navigator.pop(dialogContext, decision.action),
              child: Text(_sendGuardActionLabel(decision.action)),
            ),
          ],
        ),
      );
      if (!mounted || action == null) return;
      await _runSendGuardAction(action);
    } finally {
      _readinessDialogOpen = false;
    }
  }

  String _sendGuardActionLabel(AISendGuardAction action) => switch (action) {
        AISendGuardAction.none => '确定',
        AISendGuardAction.retry => '稍后重试',
        AISendGuardAction.configure => '去配置',
        AISendGuardAction.verify => '检查连接',
        AISendGuardAction.login => '去登录',
      };

  Future<void> _runSendGuardAction(AISendGuardAction action) async {
    switch (action) {
      case AISendGuardAction.none:
        return;
      case AISendGuardAction.retry:
        HiDialog.showSnackBar(context, '账号状态仍在初始化，请稍后再试');
        return;
      case AISendGuardAction.configure:
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const AISettingsPage()),
        );
        break;
      case AISendGuardAction.verify:
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const AiHealthCheckPage()),
        );
        break;
      case AISendGuardAction.login:
        await LoginDao.logOut();
        return;
    }
    if (!mounted) return;
    final readiness = context.read<AIReadinessProvider?>();
    if (readiness?.state.status == AIReadyStatus.ready) {
      try {
        await readiness!.markCompleted();
      } catch (error) {
        if (mounted) HiDialog.showSnackBar(context, 'AI 引导状态未保存：$error');
      }
    }
  }

  /// L3b 写工具的人工确认：助手要修改数据前弹框征得同意（防提示注入静默写入）。
  Future<bool> _confirmToolAction(String title, String detail) async {
    if (_sendCancelled) return false;
    if (_taskMode && _applicationInBackground) {
      _stopStream(reason: '操作需要确认，请回到前台后继续任务');
      return false;
    }
    final route = DialogRoute<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: Text(detail),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('拒绝')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('允许')),
              ],
            ));
    _toolConfirmationRoute = route;
    try {
      final ok = await Navigator.of(context).push(route);
      return ok == true && !_sendCancelled;
    } finally {
      if (identical(_toolConfirmationRoute, route)) {
        _toolConfirmationRoute = null;
      }
    }
  }

  void _dismissToolConfirmation() {
    final route = _toolConfirmationRoute;
    _toolConfirmationRoute = null;
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route, false);
    }
  }

  /// 带文件的用户消息：把图片/文件/文本组装成块，seed 进块仓库并连块落库。
  /// （纯图片消息沿用默认气泡的九宫格渲染，不走块化 —— 保留点击预览。）
  Future<void> _addUserMessageWithBlocks(
    MessageModel userModel,
    List<String>? imagePaths,
    List<FileMetadata> metas, {
    String roleContextSnapshot = '',
    AssistantMemoryContextBudget? roleMemoryBudget,
    List<AssistantMemoryEntryPreview> roleMemoryHits = const [],
    List<ComposerReference> references = const [],
  }) async {
    final key = chatMessageKey(userModel.createdAt);
    var seq = 0;
    final blocks = <MessageBlock>[
      for (final p in imagePaths ?? const <String>[])
        ImageBlock(
          id: 'blk_${key}_uimg_${seq++}',
          messageId: key,
          createdAt: userModel.createdAt,
          status: MessageBlockStatus.success,
          filePath: p,
        ),
      for (final m in metas)
        FileBlock(
          id: 'blk_${key}_ufile_${seq++}',
          messageId: key,
          createdAt: userModel.createdAt,
          status: MessageBlockStatus.success,
          file: m,
        ),
      for (final reference in references
          .where((r) => r.kind == ComposerReferenceKind.historyMessage))
        ReferenceBlock(
            id: 'blk_${key}_uref_${seq++}',
            messageId: key,
            createdAt: userModel.createdAt,
            status: MessageBlockStatus.success,
            reference: reference),
      if (userModel.content.isNotEmpty)
        MainTextBlock(
          id: 'blk_${key}_utext_${seq++}',
          messageId: key,
          createdAt: userModel.createdAt,
          status: MessageBlockStatus.success,
          content: userModel.content,
        ),
      if (roleContextSnapshot.trim().isNotEmpty)
        RoleContextBlock(
          id: 'blk_${key}_rolectx_${seq++}',
          messageId: key,
          createdAt: userModel.createdAt,
          status: MessageBlockStatus.success,
          content: roleContextSnapshot.trim(),
          memoryBudget: roleMemoryBudget,
          memoryHits: roleMemoryHits,
        ),
    ];
    await messageDao.saveMessageWithBlocks(userModel,
        blocksJson: MessageBlock.encodeList(blocks));
    if (!mounted || !_accountCurrent) return;
    _blockStore.seedMessage(key, blocks);
    _blockStore.commitSeed();
    chatController.addMessage(userModel);
    _notifyConversationListUpdate();
  }

  /// 非流式 + 联网搜索的回复：组装「正文块 + 引用块」，seed 进块仓库并连块落库。
  Future<void> _addReceiverMessageWithCitations(
      MessageModel receiverModel, List<WebSearchResult> webResults) async {
    final key = chatMessageKey(receiverModel.createdAt);
    final blocks = <MessageBlock>[
      MainTextBlock(
        id: 'blk_${key}_text_0',
        messageId: key,
        createdAt: receiverModel.createdAt,
        status: MessageBlockStatus.success,
        modelId: _effectiveModelId,
        content: receiverModel.content,
      ),
      if (webResults.isNotEmpty)
        CitationBlock(
          id: 'blk_${key}_cite_1',
          messageId: key,
          createdAt: receiverModel.createdAt,
          status: MessageBlockStatus.success,
          modelId: _effectiveModelId,
          webResults: webResults,
        ),
    ];
    final rowId = await messageDao.saveMessageWithBlocks(receiverModel,
        blocksJson: MessageBlock.encodeList(blocks));
    if (!mounted || !_accountCurrent) return;
    _cardRows[receiverModel.createdAt] = rowId;
    _blockStore.seedMessage(key, blocks);
    _blockStore.commitSeed();
    chatController.addMessage(receiverModel);
    _notifyConversationListUpdate();
  }

  void _stopStream({String reason = '已手动暂停，可从保存的进度继续'}) {
    _invalidatePrediction();
    if (_agentRun?.busy == true) {
      _dismissToolConfirmation();
      unawaited(_taskExecutor.cancel(_taskKey, reason: reason));
      return;
    }
    // 用户主动停止：把当前活跃块标记 paused，取消订阅，并放行 await。
    _userStopped = true;
    _stopBackgroundAfterCheckpoint();
    _dismissToolConfirmation();
    final task = _agentTask;
    if (_taskMode && task != null) {
      unawaited(task.pause(reason).catchError(
          (Object error) => AILogger.log('pause task failed: $error')));
    }
    if (mounted && _accountCurrent) {
      setState(() => _sendProgress = const ChatSendProgress('正在停止'));
    }
    _activeDispatcher?.onStopped();
    _abortStreamRequest();
    _cancelActiveEventSubscription();
    final c = _streamCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _abortStreamRequest() {
    final abort = _streamAbortCompleter;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _cancelActiveEventSubscription() {
    final subscription = _activeEventSub;
    _activeEventSub = null;
    if (subscription == null) return;
    unawaited(() async {
      try {
        await subscription.cancel();
      } catch (error) {
        // async* 取消也可能以取消异常完成，不能留下未处理的 Future。
        AILogger.log(
            'event subscription cancellation: ${_friendlyError(error)}');
      }
    }());
  }

  Future<void> _onSendNonStream(
      String inputMessage, ChatAttachments attachments,
      {bool webSearch = false}) async {
    try {
      final result = await completionDao.createCompletionsWithSearch(
          prompt: inputMessage,
          attachments: attachments.isEmpty ? null : attachments,
          webSearch: webSearch,
          abortTrigger: _streamAbortCompleter?.future,
          onProgress: _onSendProgress,
          onContextPlan: _onContextPlan);
      if (_sendCancelled) {
        if (!_disposed && _accountCurrent) {
          await _saveFailedReply('已停止等待，可重试此条提问');
        }
        return;
      }
      final response = result.content?.trim().isNotEmpty == true
          ? result.content!
          : 'no response';
      final receiverModel =
          _genMessageModel(ownerType: OwnerType.receiver, message: response);
      await _addReceiverMessageWithCitations(receiverModel, result.webResults);
      if (!_accountCurrent) return;
      await _saveConversationSummary(receiverModel);
      if (!_sendCancelled && result.content?.trim().isNotEmpty == true) {
        await _proposePersonalMemory(receiverModel.createdAt);
      }
      final user = _lastUserModel;
      if (user != null) {
        completionDao.appendTurn(user, receiverModel,
            userFileText: _lastUserFileText);
        _lastUserModel = null;
        _lastUserFileText = '';
        await _recordUsageFromCompletion(
            completionText: response,
            completionResult: result,
            createdAt: receiverModel.createdAt);
        if (!_sendCancelled) await _readAloudAssistant(receiverModel.content);
        if (!_sendCancelled && result.content?.trim().isNotEmpty == true) {
          _predictionCompletedTurn = receiverModel.createdAt;
        }
        _clearUsageRound();
      }
    } catch (e) {
      if (!_disposed && _accountCurrent) {
        await _saveFailedReply(
            _userStopped ? '已停止等待，可重试此条提问' : _friendlyError(e));
      }
    }
  }

  Future<void> _saveFailedReply(String message) async {
    if (_lastUserModel == null || _disposed || !_accountCurrent) return;
    final receiver =
        _genMessageModel(ownerType: OwnerType.receiver, message: '');
    final dispatcher = StreamDispatcher(
        _blockStore, chatMessageKey(receiver.createdAt),
        modelId: _effectiveModelId)
      ..start()
      ..onError(message);
    chatController.addMessage(receiver);
    await _persistAssistant(receiver, dispatcher);
    _notifyConversationListUpdate();
  }

  Future<void> _onSendStream(String inputMessage, ChatAttachments attachments,
      {bool webSearch = false, ToolRegistry? tools}) async {
    // 创建空内容的 AI 气泡（只加入 UI，不存 DB；落库在收尾时连块一起写）。
    final receiverModel =
        _genMessageModel(ownerType: OwnerType.receiver, message: '');
    final messageKey = chatMessageKey(receiverModel.createdAt);

    // 先建占位块，再把气泡加入列表 —— 这样气泡首次构建时即走块化渲染分支。
    final dispatcher =
        StreamDispatcher(_blockStore, messageKey, modelId: _effectiveModelId)
          ..start();
    chatController.addMessage(receiverModel);

    final completer = Completer<void>();
    final abort = _streamAbortCompleter ?? Completer<void>();
    _streamCompleter = completer;
    _streamAbortCompleter = abort;
    _activeDispatcher = dispatcher;
    _activeReceiver = receiverModel;

    // 块化分发：把「带类型」事件落到 thinking / mainText / tool 块。
    // token 只更新 _blockStore（ChangeNotifier），不触动消息列表，
    // 因此流式中只有「当前块」重渲染，其它块（如已完成的思考块）不动。
    _activeEventSub = completionDao
        .streamCompletionEvents(
            prompt: inputMessage,
            attachments: attachments.isEmpty ? null : attachments,
            abortTrigger: abort.future,
            webSearch: webSearch,
            onProgress: _onSendProgress,
            onContextPlan: _onContextPlan,
            task: _taskMode ? _agentTask : null,
            verifyFinal: _taskMode ? _workspaceTools?.correctionForFinal : null,
            tools: tools)
        .listen(
      (event) {
        if (_sendCancelled) return;
        switch (event.type) {
          case StreamEventType.reasoning:
            dispatcher.onThinkingChunk(event.delta);
            break;
          case StreamEventType.text:
            if (_sendProgress?.label != '生成回答') {
              _onSendProgress(const ChatSendProgress('生成回答'));
            }
            dispatcher.onTextChunk(event.delta);
            break;
          case StreamEventType.toolCall:
            dispatcher.onToolCall(
                toolId: event.toolId ?? '',
                name: event.toolName,
                args: event.toolArguments);
            break;
          case StreamEventType.image:
            // 阶段四：模型生成图片 -> ImageBlock（到达即完整）。
            dispatcher.onImage(event.imageUrl ?? '');
            break;
          case StreamEventType.citation:
            // 阶段五：联网搜索来源（编排器在正文流结束后发，块落在消息底部）。
            dispatcher.onCitation(event.webResults ?? const [],
                localSources: event.localSources ?? const []);
            break;
          case StreamEventType.toolResult:
            // 阶段六：工具执行完成 -> 对应 ToolBlock 填结果置 success。
            dispatcher.onToolResult(
                toolId: event.toolId ?? '', content: event.toolContent);
            break;
          case StreamEventType.usage:
            _captureStreamUsage(event);
            break;
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
      // 页面已销毁：dispose 已负责落库，这里不再重复（且不可触碰已销毁的 store/UI）。
      if (_disposed) return;
      // 正常结束（或用户停止）：收尾块、落库。
      if (!_userStopped) dispatcher.finish();
      await _persistAssistant(receiverModel, dispatcher);
      if (!_sendCancelled &&
          !dispatcher.hasError &&
          dispatcher.mainText.trim().isNotEmpty) {
        _predictionCompletedTurn = receiverModel.createdAt;
      }
      _notifyConversationListUpdate();
    } catch (e) {
      if (_disposed) return;
      // 网络/服务错误：插入 error 块并落库。
      AILogger.log('stream exception: $e');
      dispatcher.onError(_friendlyError(e));
      await _persistAssistant(receiverModel, dispatcher);
      _notifyConversationListUpdate();
    } finally {
      if (!abort.isCompleted) abort.complete();
      _streamAbortCompleter = null;
      _activeEventSub = null;
      _activeDispatcher = null;
      _streamCompleter = null;
      _activeReceiver = null;
      if (mounted) {
        setState(() {
          _sendProgress = null;
        });
      }
    }
  }

  /// 收尾落库：content 存「主文本」（供历史上下文 + 会话预览，不含思考），
  /// blocks 列存整条消息的块列表 JSON（含思考块）。
  ///
  /// 块快照同步读取并就地收尾状态（不回写 store、不 notify），因此从 dispose()
  /// 调用时也安全 —— 此刻 store 即将被销毁，绝不能再触发 Selector 重建。
  Future<void> _persistAssistant(
      MessageModel receiverModel, StreamDispatcher dispatcher) async {
    final messageKey = chatMessageKey(receiverModel.createdAt);
    final blocks = _blocksWithRoleContinuation(
      _finalizeBlocksForPersist(_blockStore.blocksFor(messageKey)),
      receiverCreatedAt: receiverModel.createdAt,
      messageKey: messageKey,
      mainText: dispatcher.mainText,
      hasError: dispatcher.hasError,
    );
    final mainText = dispatcher.mainText;
    final protocol = completionDao.lastProtocolMessages;
    if (protocol.isNotEmpty && _protocolIsBalanced(protocol)) {
      final index = blocks.indexWhere((b) => b is MainTextBlock);
      if (index >= 0) {
        blocks[index] = (blocks[index] as MainTextBlock)
            .copyWith(protocolMessages: protocol);
      } else {
        blocks.add(MainTextBlock(
            id: 'blk_${messageKey}_protocol',
            messageId: messageKey,
            createdAt: receiverModel.createdAt,
            status: MessageBlockStatus.success,
            protocolMessages: protocol));
      }
    }
    // 空回复（空流 / 仅思考 / 停止前无正文）不落空串，否则会作为空 assistant
    // 轮次回灌历史，部分上游会拒绝；用「no response」兜底，回退平铺渲染可见。
    final content = mainText.isNotEmpty
        ? mainText
        : (dispatcher.hasError ? '请求失败' : 'no response');
    final finalModel = receiverModel.copyWith(content: content);
    // 更新列表里该消息的 content（气泡内容仍由块驱动，这里只为预览/历史）。
    // 页面销毁中跳过 UI 更新，仅落库。
    if (!_disposed) chatController.updateMessage(finalModel);
    final blocksJson =
        blocks.isNotEmpty ? MessageBlock.encodeList(blocks) : null;
    final rowId = await messageDao.saveMessageWithBlocks(finalModel,
        blocksJson: blocksJson);
    if (!_disposed && _accountCurrent) {
      _cardRows[finalModel.createdAt] = rowId;
      _blockStore.seedMessage(messageKey, blocks);
      _blockStore.commitSeed();
    }
    await _saveConversationSummary(finalModel);
    if (!dispatcher.hasError && !_sendCancelled && mainText.trim().isNotEmpty) {
      await _proposePersonalMemory(finalModel.createdAt);
    }
    // 把本轮「用户 + assistant」追加进会话历史，使后续轮次携带完整上下文
    // （CompletionDao._messageList 不会自动增长；正文已不含思考内容）。
    // 连块一起传：其中的 ToolBlock 记入工具历史，使工具调用跨轮可见（遗留项 2）。
    final user = _lastUserModel;
    if (user != null) {
      completionDao.appendTurn(user, finalModel,
          assistantBlocks: blocks, userFileText: _lastUserFileText);
      if (_taskMode && _agentTask?.userCreatedAt == user.createdAt) {
        try {
          await _agentTask!.finish(
              complete: !dispatcher.hasError &&
                  !_sendCancelled &&
                  (_workspaceTools?.lastReport?.isPassed ?? true),
              requiresCorrection:
                  !(_workspaceTools?.lastReport?.isPassed ?? true));
        } catch (error) {
          // 回复正文已保存；任务快照失败不能递归生成另一条失败回复。
          _reportTaskCheckpointFailure(error);
        }
      }
      _lastUserModel = null;
      _lastUserFileText = '';
      await _recordUsageFromStream(
        completionText: finalModel.content,
        createdAt: finalModel.createdAt,
      );
      if (!dispatcher.hasError && !_sendCancelled) {
        await _readAloudAssistant(finalModel.content);
      }
      _clearUsageRound();
    }
  }

  List<MessageBlock> _blocksWithRoleContinuation(
    List<MessageBlock> blocks, {
    required int receiverCreatedAt,
    required String messageKey,
    required String mainText,
    required bool hasError,
  }) {
    final snapshot = _roleContinuationSnapshot(
      blocks,
      mainText: mainText,
      hasError: hasError,
    );
    if (snapshot.isEmpty) return blocks;
    return [
      ...blocks,
      RoleContinuationBlock(
        id: 'blk_${messageKey}_role_continuation',
        messageId: messageKey,
        createdAt: receiverCreatedAt,
        status: MessageBlockStatus.success,
        modelId: _effectiveModelId,
        content: snapshot,
      ),
    ];
  }

  String _roleContinuationSnapshot(
    List<MessageBlock> blocks, {
    required String mainText,
    required bool hasError,
  }) {
    if (_assistant == null) return '';
    if (mainText.trim().isNotEmpty) return '';
    final thinking = blocks
        .whereType<ThinkingBlock>()
        .map((block) => block.content.trim())
        .where((content) => content.isNotEmpty)
        .join('\n');
    if (thinking.isEmpty) return '';
    final summary = _compactRoleContinuationText(thinking);
    if (summary.isEmpty) return '';
    final prefix = hasError ? '上一轮回复中断，' : '上一轮尚未正式开口，';
    return '$prefix角色已形成的心理/动作状态：$summary';
  }

  static String _compactRoleContinuationText(String text) {
    final value = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('<<<', '')
        .replaceAll('>>>', '')
        .trim();
    if (value.isEmpty) return '';
    const maxChars = 240;
    if (value.characters.length <= maxChars) return value;
    return '${value.characters.take(maxChars).toString()}...';
  }

  Future<void> _readAloudAssistant(String text) async {
    try {
      await ReadAloudCoordinator.maybeSpeak(
        service: _readAloudService,
        text: text,
        enabled: widget.conversationModel.readAloudEnabled,
        locale: widget.conversationModel.voiceLocale,
        rate: widget.conversationModel.voiceRate,
        voiceStyle: widget.conversationModel.voiceStyle,
      );
    } catch (e) {
      AILogger.log('read aloud failed: $e');
    }
  }

  Future<void> _readAloudAssistantManually(String text, int createdAt) {
    final content = text.trim();
    if (content.isEmpty) return Future.value();
    final signature = _manualReadAloudRequestSignature(content, createdAt);
    final inFlight = _manualReadAloudInFlight;
    if (inFlight != null) {
      if (_manualReadAloudSignature == signature) return inFlight;
      AILogger.log('manual read aloud ignored: another request is running');
      return inFlight;
    }
    final startedAt = DateTime.now();
    final previousStartedAt = _lastManualReadAloudStartedAt;
    if (_manualReadAloudSignature == signature &&
        previousStartedAt != null &&
        startedAt.difference(previousStartedAt) <
            const Duration(milliseconds: 800)) {
      return Future.value();
    }

    _manualReadAloudSignature = signature;
    _lastManualReadAloudStartedAt = startedAt;
    _manualReadAloudStopRequested = false;
    final task = _runManualReadAloud(content, createdAt);
    _manualReadAloudInFlight = task;
    task.whenComplete(() {
      if (_manualReadAloudInFlight != task) return;
      _manualReadAloudInFlight = null;
      if (mounted) setState(() {});
    });
    return task;
  }

  String _manualReadAloudRequestSignature(String text, int createdAt) => [
        createdAt,
        widget.conversationModel.voiceLocale ?? '',
        widget.conversationModel.voiceRate ?? 1.0,
        widget.conversationModel.voiceStyle ?? '',
        text,
      ].join('\n');

  Future<void> _runManualReadAloud(String text, int createdAt) async {
    try {
      setState(() {
        _readAloudActiveMessageAt = createdAt;
        _readAloudStage = ReadAloudStage.preparing;
      });
      await ReadAloudCoordinator.maybeSpeak(
        service: _readAloudService,
        text: text,
        enabled: true,
        locale: widget.conversationModel.voiceLocale,
        rate: widget.conversationModel.voiceRate,
        voiceStyle: widget.conversationModel.voiceStyle,
        isCancelled: () => _manualReadAloudStopRequested,
        onStage: (stage) {
          if (!mounted || _readAloudActiveMessageAt != createdAt) return;
          setState(() => _readAloudStage = stage);
        },
      );
    } catch (e) {
      AILogger.log('manual read aloud failed: $e');
    } finally {
      if (mounted && _readAloudActiveMessageAt == createdAt) {
        setState(() {
          _readAloudActiveMessageAt = null;
          _readAloudStage = null;
        });
      }
    }
  }

  Future<void> _stopManualReadAloud() async {
    if (_manualReadAloudInFlight == null && _readAloudActiveMessageAt == null) {
      return;
    }
    _manualReadAloudStopRequested = true;
    if (mounted && _readAloudActiveMessageAt != null) {
      setState(() {
        _readAloudActiveMessageAt = null;
        _readAloudStage = null;
      });
    }
    try {
      await _readAloudService.stop();
    } catch (e) {
      AILogger.log('manual read aloud stop failed: $e');
    }
  }

  void _prewarmReadAloudIfNeeded() {
    final service = _readAloudService;
    if (service is! ReadAloudPreparer) return;
    unawaited((service as ReadAloudPreparer).prepare(ReadAloudRequest(
      text: '',
      locale: widget.conversationModel.voiceLocale,
      rate: widget.conversationModel.voiceRate ?? 1.0,
      voiceStyle: widget.conversationModel.voiceStyle,
    )));
  }

  /// 为持久化就地收尾块状态：把仍处于活跃态（pending/processing/streaming）的
  /// thinking / mainText 块改成 success，并丢弃从未变身的占位块。
  /// 返回新列表，不改动 [ChatBlockStore]（避免销毁中 notify）。
  List<MessageBlock> _finalizeBlocksForPersist(List<MessageBlock> blocks) {
    final out = <MessageBlock>[];
    for (final b in blocks) {
      if (b is PlaceholderBlock) continue; // 空块不落库
      if (!b.isActive) {
        out.add(b);
      } else if (b is MainTextBlock) {
        out.add(b.copyWith(status: MessageBlockStatus.success));
      } else if (b is ThinkingBlock) {
        out.add(b.copyWith(status: MessageBlockStatus.success));
      } else if (b is CodeBlock) {
        out.add(b.copyWith(status: MessageBlockStatus.success));
      } else if (b is ToolBlock) {
        out.add(b.copyWith(status: MessageBlockStatus.success));
      } else {
        out.add(b);
      }
    }
    return out;
  }

  /// 把异常转成对用户友好的简短文案。
  String _friendlyError(Object e) {
    if (e is AttachmentBatchLimitException) return e.toString();
    final diagnosis = ChatFailureDiagnosis.from(e);
    return '${diagnosis.message}\n${diagnosis.suggestion}';
  }

  ///通知聊天列表页更新当前会话
  _notifyConversationListUpdate() {
    if (!_hadUpdate && _pendingUpdate && widget.conversationUpdate != null) {
      _hadUpdate = true;
      _updateConversation();
      widget.conversationUpdate!(widget.conversationModel);
    }
  }

  void _markUsageRound({
    required String prompt,
    required AISettings settings,
  }) {
    _usagePromptText = prompt;
    _usageSettings = settings.clone();
  }

  void _clearUsageRound() {
    _usagePromptText = null;
    _usageSettings = null;
    _streamPromptTokens = 0;
    _streamCachedPromptTokens = 0;
    _streamCompletionTokens = 0;
    _hasStreamUsage = false;
  }

  void _captureStreamUsage(StreamEvent event) {
    final prompt = event.promptTokens;
    final cachedPrompt = event.cachedPromptTokens;
    final completion = event.completionTokens;
    if (prompt == null && cachedPrompt == null && completion == null) return;
    _hasStreamUsage = true;
    _streamPromptTokens += prompt ?? 0;
    _streamCachedPromptTokens += cachedPrompt ?? 0;
    _streamCompletionTokens += completion ?? 0;
  }

  Future<void> _recordUsageFromCompletion({
    required String completionText,
    CompletionResult? completionResult,
    required int createdAt,
  }) async {
    await _recordUsage(
      completionText: completionText,
      completionResult: completionResult,
      createdAt: createdAt,
    );
  }

  Future<void> _recordUsageFromStream({
    required String completionText,
    required int createdAt,
  }) async {
    await _recordUsage(
      completionText: completionText,
      completionResult: _hasStreamUsage
          ? CompletionResult(
              promptTokens: _streamPromptTokens,
              cachedPromptTokens: _streamCachedPromptTokens,
              completionTokens: _streamCompletionTokens,
              estimated: false,
            )
          : null,
      createdAt: createdAt,
    );
  }

  Future<void> _recordUsage({
    required String completionText,
    CompletionResult? completionResult,
    required int createdAt,
  }) async {
    final settings = _usageSettings;
    final promptText = _usagePromptText;
    if (settings == null || promptText == null) return;

    final modelId = settings.effectiveModel;
    if (modelId.trim().isEmpty) return;

    final providerId = settings.mode == AIMode.local
        ? settings.activeProviderId
        : widget.conversationModel.modelProviderId;

    try {
      await usageRecordService.recordTurn(
        modelId: modelId,
        providerId: providerId,
        projectId: widget.conversationModel.projectId,
        cid: widget.conversationModel.cid,
        prompt: promptText,
        completion: completionText,
        promptTokens: completionResult?.promptTokens,
        cachedPromptTokens: completionResult?.cachedPromptTokens,
        completionTokens: completionResult?.completionTokens,
        estimated: completionResult?.estimated ?? false,
        cost: completionResult?.cost ?? 0,
        costConfig: settings.usageCostConfig,
        createdAt: createdAt,
      );
    } catch (e) {
      AILogger.log('record usage failed: $e');
    }
  }

  @override
  void setState(VoidCallback fn) {
    //页面关闭后不再处理消息更新
    if (!mounted) {
      return;
    }
    super.setState(fn);
  }

  ///上一条消息的 createdAt，用于保证本会话内严格递增、毫秒唯一。
  int _lastCreatedAt = 0;

  MessageModel _genMessageModel({
    required OwnerType ownerType,
    required String message,
    List<String>? imagePaths,
    List<String>? imageUrlsOrB64,
  }) {
    String avatar, ownerName;
    if (ownerType == OwnerType.sender) {
      avatar = (userInfo['avatar'] as String?)?.isNotEmpty == true
          ? userInfo['avatar']
          : '';
      ownerName = userInfo['userName'];
    } else {
      avatar =
          AssistantConversationAvatarResolver.nextMessageAvatar(_assistant) ??
              '';
      ownerName = _aiName;
    }
    // createdAt 同时充当消息身份 + 块仓库/持久化的 key（chatMessageKey）。
    // 同一毫秒内连发（用户消息紧接 assistant 占位、快速多轮）会撞 key，
    // 导致块挂到错误气泡或重载丢块。这里钳到「严格大于上一条」，
    // 保证本会话内唯一且单调（1ms 偏移对时间展示无影响）。
    final now = DateTime.now().millisecondsSinceEpoch;
    final createdAt = now > _lastCreatedAt ? now : _lastCreatedAt + 1;
    _lastCreatedAt = createdAt;
    return MessageModel(
        ownerType: ownerType,
        content: message,
        createdAt: createdAt,
        avatar: avatar,
        ownerName: ownerName,
        imagePaths: imagePaths,
        imageUrlsOrB64: imageUrlsOrB64);
  }

  void _doInit() async {
    chatController = ChatController(
        initialMessageList: [],
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        timePellet: 60,
        messageContentBuilder: _buildBlockContent);
    // 列表项可见性变化 -> 分页加载更多 + 刷新置顶/置底按钮可见性。
    _itemPositionsListener.itemPositions.addListener(_onPositionsChanged);
    if (!_accountCurrent) return;
    final profile = LoginDao.getUserInfo();
    if (profile == null) return;
    userInfo = profile;
    final settings = context.read<AISettingsProvider>().settings;
    _currentSettings = settings;
    _aiName = settings.aiDisplayName;
    final dbManager = await HiDBManager.instance(dbName: _pageAccount);
    if (!mounted || !_accountCurrent) return;
    conversationListDao = await ConversationListDao.create(dbManager);
    messageDao =
        await MessageDao.create(dbManager, cid: widget.conversationModel.cid);
    usageDao = await UsageDao.create(dbManager);
    usageRecordService = UsageRecordService(usageDao);
    favoriteDao = await FavoriteDao.create(dbManager);
    final existingRun = _taskExecutor.lookup(_taskKey);
    final liveRun = existingRun?.busy == true ? existingRun : null;
    if (liveRun != null) {
      _agentTask = liveRun.prepared.session;
      _workspace = liveRun.prepared.workspace;
      _workspaceTools = liveRun.prepared.workspaceTools;
    } else {
      _agentTask = AgentTaskSession(
          cid: widget.conversationModel.cid,
          store: await AgentTaskDao.create(dbManager));
      await _agentTask!.load();
      _workspace = await AgentWorkspaceService.create(dbManager,
          cid: widget.conversationModel.cid);
      _workspaceTools = await AgentWorkspaceTools.create(dbManager,
          cid: widget.conversationModel.cid,
          workspace: _workspace!,
          confirm: _taskConfirmation);
      await _workspaceTools!.loadLatestReport();
    }
    if (!mounted || !_accountCurrent) return;
    _taskExecutor.bindConfirmation(_taskKey, this,
        visible: () =>
            mounted &&
            !_disposed &&
            _accountCurrent &&
            !_applicationInBackground &&
            (ModalRoute.of(context)?.isCurrent ?? false),
        confirm: _confirmToolAction,
        dismiss: _dismissToolConfirmation);
    _skillCatalog = await SkillCatalogService.create(dbManager);
    _summaryDao = await SemanticChatSummaryDao.create(dbManager);
    // 阶段七：加载会话绑定的助手（先于 CompletionDao 构造，使首轮即带
    // 系统提示词与模型覆盖）。助手已删除时回落 null。
    _assistantDao = await AssistantDao.create(dbManager);
    _assistantMemoryDao = await AssistantMemoryDao.create(dbManager);
    _personalMemoryDao =
        await PersonalMemoryDao.create(dbManager, accountHash: _pageAccount);
    final aid = widget.conversationModel.assistantId;
    if (aid != null) {
      _assistant = await _assistantDao!.getAssistant(aid);
    }
    await _loadAssistantMemories();
    if (!mounted || !_accountCurrent) return;
    final list = await _loadData();
    if (!mounted || !_accountCurrent) return;
    chatController.loadMoreData(list);
    _showInitialAssistantOpeningIfNeeded(list);
    // 继续任务会替换旧回复并追加新块，避免同时启动旧消息的滚动动画。
    if (!widget.resumeAgentTask) await _jumpToInitialTargetMessage();
    // 首帧布局完成后算一次按钮可见性（打开长会话时立即出现「回到顶部」）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPositionsChanged());
    _daoAssistant = _assistant;
    _daoSystemPrompt = await _assistantSystemPromptForSafely('');
    _daoModelProviderId = widget.conversationModel.modelProviderId;
    _daoModelId = widget.conversationModel.modelId;
    _daoReasoningEffort = widget.conversationModel.deepSeekReasoningEffort;
    _daoTaskMode = _taskMode;
    // 从持久化块恢复工具调用历史（遗留项 2）+ 附件文本历史（遗留项 6），
    // 使重开会话后工具调用与文件上下文仍跨轮可见。
    final candidates = await messageDao.loadContextCandidates();
    if (!mounted || !_accountCurrent) return;
    _hasEarlierContext = candidates.hasEarlierMessages;
    final blockHistory = await _loadBlockHistory(candidates.messages);
    completionDao = CompletionDao(
        memoryContextResolver: _memoryResolver(),
        chatService: widget.chatService,
        manageContext: true,
        settings: _effective(settings),
        systemPrompt: _daoSystemPrompt,
        messages: candidates.messages,
        toolHistory: blockHistory.$1,
        fileHistory: blockHistory.$2,
        roleContinuationHistory: blockHistory.$3,
        protocolHistory: blockHistory.$4,
        conversationId: widget.conversationModel.cid,
        semanticSummaryService: _summaryServiceFor(_effective(settings)));
    await _restoreDraft();
    if (!mounted || !_accountCurrent) return;
    setState(() => _ready = true);
    if (liveRun != null) _bindAgentRun(liveRun);
    if (_inputController.text.isNotEmpty) _scheduleDraftSave();
    if (widget.resumeAgentTask &&
        liveRun?.busy != true &&
        !_handledInitialResume) {
      _handledInitialResume = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_accountCurrent || _applicationInBackground) return;
        if (_agentTask?.canResume == true &&
            widget.initialTargetCreatedAt == _agentTask?.userCreatedAt &&
            (widget.initialAgentTaskGeneration == null ||
                widget.initialAgentTaskGeneration == _agentTask?.generation)) {
          _resumeTask();
        } else {
          HiDialog.showSnackBar(context, '任务状态已变化，请刷新任务中心后再继续');
        }
      });
    }
  }

  /// 会话内切换助手（阶段七）：弹选择器 + 确认，从下一轮开始使用新助手。
  /// 历史消息的 ownerName/avatar 已经随消息落库，不随当前会话助手变化。
  void _openAssistantProfile() async {
    _invalidatePrediction();
    final assistant = _assistant;
    if (assistant == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantProfilePage(
          assistant: assistant,
          memories: _assistantMemories,
          conversation: widget.conversationModel,
          suggestedRoleState: ConversationRoleStateSuggester.suggest(
            conversation: widget.conversationModel,
            messages: chatController.initialMessageList,
            assistant: assistant,
          ),
          onSaveRoleState: _saveConversationRoleState,
        ),
      ),
    );
    final id = widget.conversationModel.assistantId;
    if (id != null && _assistantDao != null) {
      _assistant = await _assistantDao!.getAssistant(id);
    }
    await _loadAssistantMemories();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _saveConversationRoleState({
    String? roleScene,
    String? roleRelationship,
    String? roleToneNote,
  }) async {
    await conversationListDao.updateRoleState(
      widget.conversationModel,
      roleScene: roleScene,
      roleRelationship: roleRelationship,
      roleToneNote: roleToneNote,
    );
    if (!mounted) return;
    widget.conversationModel.hadChanged = true;
    setState(() {});
    HiDialog.showSnackBar(context, '已更新当前会话状态');
  }

  void _switchAssistant() async {
    _invalidatePrediction();
    final pick = await showAssistantPicker(context,
        selectedId: widget.conversationModel.assistantId);
    if (pick == null || !mounted) return; // 取消
    final assistant = pick.assistant;
    final nextAssistantId = assistant?.id;
    if (nextAssistantId == widget.conversationModel.assistantId) return;
    final confirmed = await _confirmSwitchAssistant(assistant);
    if (!confirmed || !mounted) return;
    setState(() {
      _assistant = assistant;
      AssistantConversationAvatarResolver.applySwitch(
        widget.conversationModel,
        assistant,
      );
    });
    final message = assistant == null ? '已取消助手绑定' : '已切换助手：${assistant.name}';
    await _loadAssistantMemories();
    if (!mounted) return;
    setState(() {});
    widget.conversationModel.hadChanged = true;
    await conversationListDao.saveConversation(widget.conversationModel);
    AppEvents.notifyConversationsChanged();
    if (!mounted) return;
    _prewarmReadAloudIfNeeded();
    HiDialog.showSnackBar(context, message);
  }

  Future<bool> _confirmSwitchAssistant(AssistantModel? assistant) async {
    final currentName = _assistant?.name.trim();
    final nextName = assistant?.name.trim();
    final title = assistant == null ? '取消当前会话助手？' : '切换当前会话助手？';
    final content = assistant == null
        ? '将从下一轮开始不再使用当前助手。历史消息会保留原来的头像和名称，不会被修改。'
        : '当前会话将从下一轮开始使用「${nextName?.isEmpty ?? true ? '新助手' : nextName}」。'
            '${currentName == null || currentName.isEmpty ? '' : '\n当前助手：$currentName'}'
            '\n\n历史消息会保留原助手头像和名称，不会被修改。';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('从下一轮开始'),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _switchModel() async {
    _invalidatePrediction();
    if (!_ready || !_accountCurrent || _isStreaming) return;
    final rawSettings = context.read<AISettingsProvider>().settings;
    final picked = rawSettings.mode == AIMode.backend
        ? await _pickBackendModel(rawSettings)
        : await _pickConfiguredLocalModel(rawSettings);
    if (picked == null || !mounted || !_accountCurrent || _isStreaming) return;
    setState(() {
      widget.conversationModel.modelProviderId = picked.providerId;
      widget.conversationModel.modelId = picked.modelId;
    });
    widget.conversationModel.hadChanged = true;
    await conversationListDao.updateModelOverride(
        widget.conversationModel, picked.providerId, picked.modelId);
    if (!_accountCurrent) return;
    if (picked.providerId != null && picked.modelId != null) {
      await _recordModelUsed(picked.providerId!, picked.modelId!);
    }
    if (!mounted || !_accountCurrent) return;
    final label = picked.modelId == null ? '跟随全局设置' : picked.modelId!;
    HiDialog.showSnackBar(context, '当前会话模型：$label');
  }

  Future<void> _selectReasoningEffort() async {
    _invalidatePrediction();
    if (!_ready || _isStreaming || _savingReasoningEffort || !_accountCurrent) {
      return;
    }
    final picked = await showDialog<DeepSeekReasoningSelection>(
      context: context,
      builder: (_) => DeepSeekReasoningDialog(
          selected: widget.conversationModel.deepSeekReasoningEffort),
    );
    if (picked == null || !mounted || !_accountCurrent || _isStreaming) return;
    setState(() => _savingReasoningEffort = true);
    try {
      await conversationListDao.updateReasoningEffort(
          widget.conversationModel, picked.effort);
      if (!mounted || !_accountCurrent) return;
      widget.conversationModel.hadChanged = true;
      final rawSettings = context.read<AISettingsProvider>().settings;
      final effective = _effective(rawSettings);
      completionDao = CompletionDao(
        memoryContextResolver: _memoryResolver(),
        chatService: widget.chatService,
        manageContext: true,
        settings: effective,
        systemPrompt: _daoSystemPrompt,
        messages: completionDao.currentMessages,
        toolHistory: completionDao.currentToolHistory,
        fileHistory: completionDao.currentFileHistory,
        roleContinuationHistory: completionDao.currentRoleContinuationHistory,
        protocolHistory: completionDao.currentProtocolHistory,
        conversationId: widget.conversationModel.cid,
        semanticSummaryService: _summaryServiceFor(effective),
      );
      _currentSettings = rawSettings;
      _daoReasoningEffort = picked.effort;
      setState(() {
        _contextPlan = completionDao.previewContext(prompt: _inputMessage);
        _contextAttachmentsPrepared = false;
      });
      HiDialog.showSnackBar(
          context, '当前会话思考强度：${picked.effort?.label ?? '跟随默认'}');
    } catch (_) {
      if (mounted && _accountCurrent) {
        HiDialog.showSnackBar(context, '思考强度保存失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _savingReasoningEffort = false);
    }
  }

  void _openVoicePrefs() async {
    final userModelStore = UserSherpaOnnxTtsModelStore();
    final userVoiceModels = await userModelStore.listModels();
    if (!mounted) return;
    var speechInput = widget.conversationModel.speechInputEnabled ?? true;
    var readAloud = widget.conversationModel.readAloudEnabled ?? false;
    var rate = widget.conversationModel.voiceRate ?? 1.0;
    var voiceStyle =
        widget.conversationModel.voiceStyle ?? TtsVoiceStyle.system.id;
    if (UserSherpaOnnxTtsModelStore.isUserVoiceStyle(voiceStyle) &&
        userVoiceModels.every((model) => model.voiceStyleId != voiceStyle)) {
      voiceStyle = TtsVoiceStyle.system.id;
    }
    var triggerMode = _ReadAloudTriggerMode.normalize(
        widget.conversationModel.readAloudTriggerMode);
    var resetToDefault = false;
    final localeCtl =
        TextEditingController(text: widget.conversationModel.voiceLocale ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('语音偏好'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('语音输入'),
                  value: speechInput,
                  onChanged: (v) => setDialogState(() => speechInput = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动朗读'),
                  subtitle: const Text('保存偏好；真实朗读需平台 TTS 插件'),
                  value: readAloud,
                  onChanged: (v) => setDialogState(() => readAloud = v),
                ),
                TextField(
                  controller: localeCtl,
                  decoration: const InputDecoration(
                    labelText: '识别语言',
                    hintText: '跟随系统，或填写 zh_CN / en_US',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: voiceStyle,
                  decoration: const InputDecoration(labelText: '朗读风格'),
                  items: [
                    for (final style in TtsVoiceStyle.all)
                      DropdownMenuItem(
                        value: style.id,
                        child: Text(style.label),
                      ),
                    for (final model in userVoiceModels)
                      DropdownMenuItem(
                        value: model.voiceStyleId,
                        child: Text('用户模型：${model.title}'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => voiceStyle = value);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _voiceStyleDescription(voiceStyle, userVoiceModels),
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: triggerMode,
                  decoration: const InputDecoration(labelText: '朗读入口'),
                  items: [
                    for (final mode in _ReadAloudTriggerMode.all)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(_ReadAloudTriggerMode.labelOf(mode)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => triggerMode = value);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('朗读速率'),
                    Expanded(
                      child: Slider(
                        value: rate,
                        min: 0.5,
                        max: 2.0,
                        divisions: 6,
                        label: rate.toStringAsFixed(1),
                        onChanged: (v) => setDialogState(() => rate = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
              onPressed: () {
                resetToDefault = true;
                Navigator.pop(ctx, true);
              },
              child: const Text('恢复默认'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (!mounted || saved != true) {
      localeCtl.dispose();
      return;
    }
    final locale = localeCtl.text.trim();
    localeCtl.dispose();
    final nextSpeechInput = resetToDefault ? null : speechInput;
    final nextReadAloud = resetToDefault ? null : readAloud;
    final nextLocale = resetToDefault || locale.isEmpty ? null : locale;
    final nextRate = resetToDefault || rate == 1.0 ? null : rate;
    final nextVoiceStyle =
        resetToDefault || voiceStyle == TtsVoiceStyle.system.id
            ? null
            : voiceStyle;
    final nextTriggerMode =
        resetToDefault || triggerMode == _ReadAloudTriggerMode.button
            ? null
            : triggerMode;
    setState(() {
      widget.conversationModel.speechInputEnabled = nextSpeechInput;
      widget.conversationModel.readAloudEnabled = nextReadAloud;
      widget.conversationModel.voiceLocale = nextLocale;
      widget.conversationModel.voiceRate = nextRate;
      widget.conversationModel.voiceStyle = nextVoiceStyle;
      widget.conversationModel.readAloudTriggerMode = nextTriggerMode;
    });
    widget.conversationModel.hadChanged = true;
    await conversationListDao.updateVoicePrefs(
      widget.conversationModel,
      speechInputEnabled: nextSpeechInput,
      readAloudEnabled: nextReadAloud,
      voiceLocale: nextLocale,
      voiceRate: nextRate,
      voiceStyle: nextVoiceStyle,
      readAloudTriggerMode: nextTriggerMode,
    );
    if (!mounted) return;
    _prewarmReadAloudIfNeeded();
    HiDialog.showSnackBar(context, '已保存当前会话语音偏好');
  }

  void _showInitialAssistantOpeningIfNeeded(List<MessageModel> loaded) {
    final opening = widget.initialAssistantOpening.trim();
    if (opening.isEmpty || loaded.isNotEmpty) return;
    final assistant = _assistant;
    chatController.addMessage(MessageModel(
      ownerType: OwnerType.receiver,
      content: opening,
      createdAt: -widget.conversationModel.cid,
      avatar:
          AssistantConversationAvatarResolver.nextMessageAvatar(_assistant) ??
              '',
      ownerName: assistant?.name ?? _aiName,
    ));
  }

  String _voiceStyleDescription(
    String voiceStyle,
    List<UserSherpaOnnxTtsModel> userModels,
  ) {
    final id = UserSherpaOnnxTtsModelStore.idFromVoiceStyle(voiceStyle);
    if (id != null) {
      for (final model in userModels) {
        if (model.id != id) continue;
        final manifest = model.manifest;
        return '用户导入的 sherpa-onnx Matcha 模型，'
            '${manifest.locale} / ${manifest.speaker} / ${manifest.sampleRate}Hz';
      }
      return '用户导入的 sherpa-onnx 模型';
    }
    return TtsVoiceStyle.byId(voiceStyle).description;
  }

  Future<void> _testConversationModel(
    AISettings settings, {
    String? providerId,
    required String modelId,
  }) async {
    final model = modelId.trim();
    if (model.isEmpty) {
      throw Exception('请输入模型 ID');
    }
    final next = settings.clone();
    if (next.mode == AIMode.backend) {
      next.backendModel = model;
    } else {
      final id = providerId ?? next.activeProvider.id;
      next.activeProviderId = id;
      final providers = next.providers.where((p) => p.id == id);
      if (providers.isEmpty) {
        throw Exception('服务商不存在或已停用');
      }
      final provider = providers.first;
      provider.selectedModelId = model;
      if (!provider.models.any((m) => m.id == model)) {
        provider.models.insert(0, AiModel(id: model));
      }
    }
    await ChatService.from(next).chat(prompt: 'ping', history: []);
  }

  Future<void> _recordModelUsed(String providerId, String modelId) async {
    final store = context.read<AISettingsProvider>();
    final providers = store.settings.providers.where((p) => p.id == providerId);
    if (providers.isEmpty) return;
    final provider = providers.first;
    final models = provider.models.where((m) => m.id == modelId);
    if (models.isEmpty) return;
    models.first.markUsed();
    await store.updateProvider(provider);
  }

  Future<({String? providerId, String? modelId})?> _pickConfiguredLocalModel(
      AISettings settings) async {
    final providerId =
        widget.conversationModel.modelProviderId ?? settings.activeProvider.id;
    final modelId =
        widget.conversationModel.modelId ?? _effective(settings).effectiveModel;
    final selected = widget.conversationModel.modelId == null
        ? const TranslationModelPreference(
            mode: TranslationModelPreferenceMode.followGlobal,
            reasoningPolicy: ChatReasoningPolicy.providerDefault,
          )
        : TranslationModelPreference(
            mode: TranslationModelPreferenceMode.local,
            providerId: providerId,
            modelId: modelId,
            reasoningPolicy: ChatReasoningPolicy.providerDefault,
          );
    final picked = await showConfiguredAiModelPickerSheet(
      context,
      settings: settings,
      selected: selected,
      onlyMode: TranslationExecutionMode.local,
    );
    if (picked == null) return null;
    return switch (picked.mode) {
      TranslationModelPreferenceMode.followGlobal => (
          providerId: null,
          modelId: null
        ),
      TranslationModelPreferenceMode.local => (
          providerId: picked.providerId,
          modelId: picked.modelId
        ),
      TranslationModelPreferenceMode.backend => null,
    };
  }

  Widget _backendModelTestStatus(
      _ConversationModelTestState state, String? error) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (state == _ConversationModelTestState.idle) {
      return const SizedBox.shrink();
    }
    if (state == _ConversationModelTestState.running) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    final success = state == _ConversationModelTestState.success;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        success ? '模型可用' : '模型不可用：${error ?? ''}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: tt.bodySmall?.copyWith(color: success ? cs.primary : cs.error),
      ),
    );
  }

  Future<({String? providerId, String? modelId})?> _pickBackendModel(
      AISettings settings) async {
    final controller = TextEditingController(
        text: widget.conversationModel.modelId ?? settings.backendModel);
    var testState = _ConversationModelTestState.idle;
    String? testError;
    return showDialog<({String? providerId, String? modelId})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('切换模型'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: '模型 ID'),
                onChanged: (_) {
                  if (testState == _ConversationModelTestState.idle) return;
                  setDialogState(() {
                    testState = _ConversationModelTestState.idle;
                    testError = null;
                  });
                },
              ),
              _backendModelTestStatus(testState, testError),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, (providerId: null, modelId: null)),
                child: const Text('跟随全局')),
            TextButton(
                onPressed: testState == _ConversationModelTestState.running
                    ? null
                    : () async {
                        setDialogState(() {
                          testState = _ConversationModelTestState.running;
                          testError = null;
                        });
                        try {
                          await _testConversationModel(settings,
                              modelId: controller.text);
                          if (!ctx.mounted) return;
                          setDialogState(() =>
                              testState = _ConversationModelTestState.success);
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setDialogState(() {
                            testState = _ConversationModelTestState.failure;
                            testError = '$e';
                          });
                        }
                      },
                child: const Text('测试')),
            FilledButton(
                onPressed: () {
                  final model = controller.text.trim();
                  Navigator.pop(
                      ctx,
                      model.isEmpty
                          ? null
                          : (providerId: null, modelId: model));
                },
                child: const Text('保存')),
          ],
        ),
      ),
    );
  }

  int pageIndex = 1;

  ///从数据库加载历史聊天记录
  Future<List<MessageModel>> _loadData({loadMore = false}) async {
    if (loadMore) {
      pageIndex++;
    } else {
      pageIndex = 1;
    }
    final list = await messageDao.getMessages(pageIndex: pageIndex);
    AILogger.log('loaded ${list.length} history messages');
    // 块化消息系统：从持久化恢复这些消息的块，给 BlockMessageContent 做 seed。
    await _seedBlocks(list);
    if (loadMore) {
      if (list.isNotEmpty) {
        chatController.loadMoreData(list);
      } else {
        //如果没有更多的数据，则pageIndex不增加
        pageIndex--;
      }
    }
    return list;
  }

  /// 从持久化块里抽取这批消息的工具调用块（遗留项 2）与附件降级文本（遗留项 6），
  /// 一次查询同时构成 `createdAt -> List<ToolBlock>` 与 `createdAt -> 附件文本`，
  /// 供 [CompletionDao] 跨轮重建。候选历史与 UI 分页独立，保持重开会话后上下文一致。
  Future<
      (
        Map<int, List<ToolBlock>>,
        Map<int, String>,
        Map<int, String>,
        Map<int, List<Map<String, dynamic>>>
      )> _loadBlockHistory(List<MessageModel> list) async {
    if (list.isEmpty) {
      return (
        <int, List<ToolBlock>>{},
        <int, String>{},
        <int, String>{},
        <int, List<Map<String, dynamic>>>{},
      );
    }
    final blocksMap =
        await messageDao.getBlocksByCreatedAt(list.map((m) => m.createdAt));
    if (blocksMap.isEmpty) {
      return (
        <int, List<ToolBlock>>{},
        <int, String>{},
        <int, String>{},
        <int, List<Map<String, dynamic>>>{},
      );
    }
    final tools = <int, List<ToolBlock>>{};
    final files = <int, String>{};
    final continuations = <int, String>{};
    final protocols = <int, List<Map<String, dynamic>>>{};
    for (final m in list) {
      final json = blocksMap[chatMessageKey(m.createdAt)];
      if (json == null) continue;
      final blocks = MessageBlock.decodeList(json);
      final protocol = blocks
          .whereType<MainTextBlock>()
          .expand((b) => b.protocolMessages)
          .toList();
      if (protocol.isNotEmpty) protocols[m.createdAt] = protocol;
      final tb = blocks.whereType<ToolBlock>().toList();
      if (tb.isNotEmpty) tools[m.createdAt] = tb;
      final text = userMessageExtraText(blocks);
      if (text.isNotEmpty) files[m.createdAt] = text;
      final continuation = blocks
          .whereType<RoleContinuationBlock>()
          .map((b) => b.content.trim())
          .where((content) => content.isNotEmpty)
          .join('\n');
      if (continuation.isNotEmpty) continuations[m.createdAt] = continuation;
    }
    return (tools, files, continuations, protocols);
  }

  /// 从 DB 恢复这批消息的块列表并 seed 进 [ChatBlockStore]。
  Future<void> _seedBlocks(List<MessageModel> list) async {
    if (list.isEmpty) return;
    final blocksMap =
        await messageDao.getBlocksByCreatedAt(list.map((m) => m.createdAt));
    if (blocksMap.isEmpty) return;
    blocksMap.forEach((key, json) {
      _blockStore.seedMessage(key, MessageBlock.decodeList(json));
    });
    for (final message in list) {
      if (message.ownerType == OwnerType.receiver &&
          message.id != null &&
          blocksMap.containsKey(chatMessageKey(message.createdAt))) {
        _cardRows[message.createdAt] = message.id!;
      }
    }
    _blockStore.commitSeed();
  }

  void _updateConversation() {
    //更新会话信息
    final persistedMessages = chatController.initialMessageList
        .where((message) =>
            message.createdAt > 0 && _isUsableConversationText(message.content))
        .toList();
    if (persistedMessages.isNotEmpty) {
      final latest = persistedMessages.first;
      final titleSource = persistedMessages.reversed.firstWhere(
        (message) =>
            message.ownerType == OwnerType.sender &&
            _isUsableConversationText(message.content),
        orElse: () => persistedMessages.last,
      );
      widget.conversationModel.lastMessage = latest.content.trim();
      widget.conversationModel.updateAt = latest.createdAt;
      if (!_isUsableConversationText(widget.conversationModel.title)) {
        widget.conversationModel.title = titleSource.content.trim();
      }
    }
  }

  static bool _isUsableConversationText(String? value) {
    final text = value?.trim() ?? '';
    return text.isNotEmpty && text.toLowerCase() != 'null';
  }

  /// 是否可对该消息「重新生成」：必须是 assistant 回复、当前无流式进行、
  /// 且为会话最新一条（仅支持重生成最后一次回复，保证历史回退正确）。
  bool _canRegenerate(MessageModel message) {
    if (message.createdAt <= 0) return false;
    if (message.ownerType != OwnerType.receiver || _isStreaming) return false;
    final list = chatController.initialMessageList;
    return list.isNotEmpty && list.first.createdAt == message.createdAt;
  }

  List<String> _conversationRoleStatePreview() {
    return widget.conversationModel.roleStatePreviewLines();
  }

  void _onBubbleLongPress(MessageModel message, BuildContext ancestor) {
    final mode = _ReadAloudTriggerMode.normalize(
        widget.conversationModel.readAloudTriggerMode);
    final left = message.ownerType == OwnerType.receiver ? true : false;
    final offsetX = left ? -100.0 : 50.0;
    final readAloudActive = _readAloudActiveMessageAt == message.createdAt;
    final persisted = message.createdAt > 0;
    HiDialog.showPopMenu(ancestor, offsetX: offsetX, items: [
      if (readAloudActive)
        PopupMenuItem(
          onTap: _stopManualReadAloud,
          child: const Text('停止朗读'),
        ),
      if (mode == _ReadAloudTriggerMode.longPress &&
          message.ownerType == OwnerType.receiver &&
          message.content.trim().isNotEmpty &&
          !readAloudActive &&
          _manualReadAloudInFlight == null)
        PopupMenuItem(
          child: const Text('朗读'),
          onTap: () {
            _readAloudAssistantManually(message.content, message.createdAt);
          },
        ),
      if (_canRegenerate(message))
        PopupMenuItem(
          child: const Text('重新生成'),
          onTap: () {
            _regenerate(message);
          },
        ),
      if (persisted)
        PopupMenuItem(
          child: const Text('设为精彩'),
          onTap: () {
            _addFavorite(message);
          },
        ),
      if (persisted && _assistant?.id != null)
        PopupMenuItem(
          child: const Text('记为助手记忆'),
          onTap: () {
            _saveAssistantMemory(message);
          },
        ),
      if (persisted &&
          widget.conversationModel.assistantId == null &&
          !_taskMode &&
          message.ownerType == OwnerType.sender &&
          !_isStreaming)
        PopupMenuItem(
            child: const Text('记为个人记忆'),
            onTap: () => _savePersonalMemory(message)),
      if (persisted &&
          _assistant?.id != null &&
          message.content.trim().isNotEmpty)
        PopupMenuItem(
          child: const Text('加入世界书'),
          onTap: () {
            _saveMessageToWorldBook(message);
          },
        ),
      if (persisted && _assistant != null && message.content.trim().isNotEmpty)
        PopupMenuItem(
          child: const Text('更新会话状态'),
          onTap: () {
            _updateRoleStateFromMessage(message);
          },
        ),
      if (persisted &&
          _assistant?.id != null &&
          message.content.trim().isNotEmpty)
        PopupMenuItem(
          child: const Text('存为示例对话'),
          onTap: () {
            _saveMessageAsExampleDialog(message);
          },
        ),
      if (persisted && _canCopyRoleDebugPackage(message))
        PopupMenuItem(
          child: const Text('复制调试包'),
          onTap: () {
            _copyRoleDebugPackage(message);
          },
        ),
      PopupMenuItem(
        child: const Text('复制'),
        onTap: () {
          _copyMessage(message);
        },
      ),
      if (persisted)
        PopupMenuItem(
          child: const Text('删除'),
          onTap: () => _deleteMessage(message),
        ),
      PopupMenuItem(
        child: const Text('转发'),
        onTap: () => showForwardSheet(context, content: message.content),
      )
    ]);
  }

  bool _canCopyRoleDebugPackage(MessageModel message) {
    if (message.ownerType != OwnerType.sender) return false;
    return _roleContextSnapshotFor(message.createdAt).isNotEmpty ||
        (_roleStateByMessageAt[message.createdAt]?.isNotEmpty ?? false) ||
        _roleMemoryHitsFor(message.createdAt).isNotEmpty ||
        _roleMemoryBudgetFor(message.createdAt)?.affected == true;
  }

  String _roleContextSnapshotFor(int createdAt) {
    final cached = _roleContextByMessageAt[createdAt]?.trim();
    if (cached != null && cached.isNotEmpty) return cached;
    final key = chatMessageKey(createdAt);
    for (final block
        in _blockStore.blocksFor(key).whereType<RoleContextBlock>()) {
      final content = block.content.trim();
      if (content.isNotEmpty) return content;
    }
    return '';
  }

  AssistantMemoryContextBudget? _roleMemoryBudgetFor(int createdAt) {
    final cached = _memoryBudgetByMessageAt[createdAt];
    if (cached != null) return cached;
    final key = chatMessageKey(createdAt);
    for (final block
        in _blockStore.blocksFor(key).whereType<RoleContextBlock>()) {
      final budget = block.memoryBudget;
      if (budget != null) return budget;
    }
    return null;
  }

  List<AssistantMemoryEntryPreview> _roleMemoryHitsFor(int createdAt) {
    final cached = _memoryHitsByMessageAt[createdAt];
    if (cached != null && cached.isNotEmpty) return cached;
    final key = chatMessageKey(createdAt);
    for (final block
        in _blockStore.blocksFor(key).whereType<RoleContextBlock>()) {
      if (block.memoryHits.isNotEmpty) return block.memoryHits;
    }
    return const [];
  }

  Future<void> _copyRoleDebugPackage(MessageModel message) async {
    final text = ConversationRoleDebugExport.build(
      userMessage: message.content,
      assistant: _assistant,
      roleContextSnapshot: _roleContextSnapshotFor(message.createdAt),
      roleStateLines: _roleStateByMessageAt[message.createdAt] ?? const [],
      memoryHits: _roleMemoryHitsFor(message.createdAt),
      memoryBudget: _roleMemoryBudgetFor(message.createdAt),
      memories: _assistantMemories,
    );
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '角色调试包已复制');
  }

  Future<void> _copyConversationRoleDebugPackage() async {
    final text = ConversationRoleDebugExport.buildSession(
      title: widget.conversationModel.title ?? _title,
      assistant: _assistant,
      turns: _conversationRoleDebugTurns(),
      memories: _assistantMemories,
    );
    if (text.isEmpty) {
      HiDialog.showSnackBar(context, '暂无可导出的角色调试信息');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '会话角色调试包已复制');
  }

  List<ConversationRoleDebugTurn> _conversationRoleDebugTurns() {
    final userMessages = chatController.initialMessageList
        .where((message) =>
            message.createdAt > 0 && message.ownerType == OwnerType.sender)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var index = 0;
    return [
      for (final message in userMessages)
        ConversationRoleDebugTurn(
          index: ++index,
          userMessage: message.content,
          roleContextSnapshot: _roleContextSnapshotFor(message.createdAt),
          roleStateLines: _roleStateByMessageAt[message.createdAt] ?? const [],
          memoryHits: _roleMemoryHitsFor(message.createdAt),
          memoryBudget: _roleMemoryBudgetFor(message.createdAt),
        ),
    ];
  }

  void _saveAssistantMemory(MessageModel message) async {
    await _saveAssistantMemoryText(
      initialText: message.content.trim(),
      source: message.ownerType == OwnerType.sender ? 'user_message' : 'reply',
      sourceType: message.ownerType == OwnerType.sender
          ? 'user_message'
          : 'assistant_reply',
      sourceMessageId: message.createdAt.toString(),
    );
  }

  Future<void> _saveMessageToWorldBook(MessageModel message) async {
    final assistant = _assistant;
    final dao = _assistantDao;
    if (assistant?.id == null || dao == null) return;
    final result = await showDialog<_WorldBookQuickSaveResult>(
      context: context,
      builder: (_) => _WorldBookQuickSaveDialog(
        initialContent: message.content.trim(),
      ),
    );
    if (result == null || result.content.trim().isEmpty) return;
    if (AssistantRoleCardService.hasDuplicateMemoryContent(
      assistant!.memoryBook,
      result.content,
    )) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '这条世界书设定已存在');
      return;
    }
    assistant.memoryBook = AssistantRoleCardService.appendMemoryBookEntry(
      assistant.memoryBook,
      keywords: result.keywords,
      content: result.content,
      enabled: result.enabled,
      priority: result.priority,
    );
    try {
      await dao.saveAssistant(assistant);
      if (!mounted) return;
      setState(() {});
      HiDialog.showSnackBar(context, '已加入「${assistant.name}」的世界书');
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '保存世界书失败：$e');
    }
  }

  Future<void> _updateRoleStateFromMessage(MessageModel message) async {
    final draft = ConversationRoleStateSuggester.fromMessage(
      conversation: widget.conversationModel,
      message: message,
      assistant: _assistant,
    );
    final result = await showDialog<ConversationRoleStateDraft>(
      context: context,
      builder: (_) => _RoleStateQuickEditDialog(draft: draft),
    );
    if (result == null) return;
    await _saveConversationRoleState(
      roleScene: result.scene.trim().isEmpty ? null : result.scene.trim(),
      roleRelationship: result.relationship.trim().isEmpty
          ? null
          : result.relationship.trim(),
      roleToneNote:
          result.toneNote.trim().isEmpty ? null : result.toneNote.trim(),
    );
  }

  Future<void> _saveMessageAsExampleDialog(MessageModel message) async {
    final assistant = _assistant;
    final dao = _assistantDao;
    if (assistant?.id == null || dao == null) return;
    final snippet = _exampleDialogSnippetFor(message).trim();
    if (snippet.isEmpty) return;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ExampleDialogQuickSaveDialog(initialText: snippet),
    );
    if (result == null || result.trim().isEmpty) return;
    if (AssistantRoleCardService.hasDuplicateExampleDialog(
      assistant!.exampleDialogs,
      result,
    )) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '这段示例对话已存在');
      return;
    }
    assistant.exampleDialogs = AssistantRoleCardService.appendExampleDialog(
      assistant.exampleDialogs,
      result,
    );
    try {
      await dao.saveAssistant(assistant);
      if (!mounted) return;
      setState(() {});
      HiDialog.showSnackBar(context, '已保存为「${assistant.name}」的示例对话');
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '保存示例对话失败：$e');
    }
  }

  String _exampleDialogSnippetFor(MessageModel message) {
    final messages = chatController.initialMessageList
        .where((item) => item.createdAt > 0 && item.content.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final index =
        messages.indexWhere((item) => item.createdAt == message.createdAt);
    if (index < 0) {
      return _singleExampleDialogLine(message);
    }
    if (message.ownerType == OwnerType.receiver) {
      final previousUser = messages.take(index).toList().reversed.firstWhere(
            (item) => item.ownerType == OwnerType.sender,
            orElse: () => MessageModel(
              ownerType: OwnerType.sender,
              content: '',
              createdAt: 0,
              avatar: '',
              ownerName: '',
            ),
          );
      return AssistantRoleCardService.formatExampleDialogTurn(
        userMessage: previousUser.content,
        assistantMessage: message.content,
      );
    }
    final nextAssistant = messages.skip(index + 1).firstWhere(
          (item) => item.ownerType == OwnerType.receiver,
          orElse: () => MessageModel(
            ownerType: OwnerType.receiver,
            content: '',
            createdAt: 0,
            avatar: '',
            ownerName: '',
          ),
        );
    return AssistantRoleCardService.formatExampleDialogTurn(
      userMessage: message.content,
      assistantMessage: nextAssistant.content,
    );
  }

  String _singleExampleDialogLine(MessageModel message) {
    return message.ownerType == OwnerType.receiver
        ? AssistantRoleCardService.formatExampleDialogTurn(
            userMessage: '',
            assistantMessage: message.content,
          )
        : AssistantRoleCardService.formatExampleDialogTurn(
            userMessage: message.content,
            assistantMessage: '',
          );
  }

  Future<void> _confirmMemorySuggestion(
      int createdAt, String suggestion) async {
    final saved = await _saveAssistantMemoryText(
      initialText: suggestion,
      source: 'suggestion',
      sourceType: 'ai_suggestion',
      sourceMessageId: createdAt.toString(),
    );
    if (!saved || !mounted) return;
    setState(() {
      _dismissedMemorySuggestions.add(createdAt);
      _memorySuggestionsByMessageAt.remove(createdAt);
    });
  }

  Future<void> _savePersonalMemory(MessageModel message) async {
    final dao = _personalMemoryDao;
    final cid = widget.conversationModel.cid;
    if (dao == null ||
        !_accountCurrent ||
        _taskMode ||
        widget.conversationModel.assistantId != null ||
        message.ownerType != OwnerType.sender) {
      return;
    }
    try {
      final prefs = await dao.preferences();
      final source = await dao.sourceForMessage(cid, message.createdAt);
      if (!mounted ||
          !_accountCurrent ||
          cid != widget.conversationModel.cid ||
          source == null) {
        return;
      }
      final text = await showPersonalMemoryEditor(context,
          initialText: message.content, title: '记为个人记忆');
      if (text == null ||
          !mounted ||
          !_accountCurrent ||
          cid != widget.conversationModel.cid ||
          _taskMode ||
          widget.conversationModel.assistantId != null) {
        return;
      }
      await dao.save(text, source: source, expectedEpoch: prefs.epoch);
      if (mounted && _accountCurrent) HiDialog.showSnackBar(context, '个人记忆已保存');
    } catch (e) {
      if (mounted && _accountCurrent) {
        HiDialog.showSnackBar(context, '保存个人记忆失败：$e');
      }
    }
  }

  Future<bool> _saveAssistantMemoryText({
    required String initialText,
    required String source,
    required String sourceType,
    required String sourceMessageId,
  }) async {
    final assistantId = _assistant?.id;
    if (assistantId == null || _assistantMemoryDao == null) return false;
    final account = _pageAccount;
    final cid = widget.conversationModel.cid;
    final tick = BackupService.restoreTick.value;
    final dao = _assistantMemoryDao!;
    bool current() =>
        mounted &&
        _accountCurrent &&
        widget.conversationModel.cid == cid &&
        _assistant?.id == assistantId &&
        BackupService.restoreTick.value == tick;
    final content = await showDialog<String>(
      context: context,
      builder: (_) => _AssistantMemorySaveDialog(initialText: initialText),
    );
    if (content == null || content.trim().isEmpty || !current()) return false;
    if (AssistantMemoryDao.hasDuplicateContent(_assistantMemories, content)) {
      if (mounted) HiDialog.showSnackBar(context, '这条长期记忆已存在');
      return false;
    }
    int? id;
    try {
      id = await LoginDao.runWithStableAccount(
          expectedAccountHash: account,
          action: () async {
            if (!current()) throw StateError('原会话已变化');
            final rows = await messageDao.storage.db.query(
                'tb_conversation_list',
                where: 'cid=? and assistantId=?',
                whereArgs: [cid, assistantId]);
            final assistants = await messageDao.storage.db
                .query('tb_assistant', where: 'id=?', whereArgs: [assistantId]);
            if (rows.length != 1 || assistants.length != 1 || !current()) {
              throw StateError('原助手或会话已删除');
            }
            return dao.saveMemory(
              AssistantMemoryModel.confirmedFromConversation(
                assistantId: assistantId,
                content: content,
                source: source,
                sourceType: sourceType,
                conversationId: widget.conversationModel.cid.toString(),
                messageId: sourceMessageId,
              ),
            );
          });
    } catch (e) {
      if (mounted && current()) HiDialog.showSnackBar(context, '保存助手记忆失败：$e');
      return false;
    }
    if (!current()) return false;
    if (id == null) {
      if (mounted) HiDialog.showSnackBar(context, '保存记忆失败');
      return false;
    }
    await _loadAssistantMemories();
    if (!mounted) return true;
    HiDialog.showSnackBar(context, '已保存到「${_assistant?.name ?? '助手'}」的长期记忆');
    return true;
  }

  void _addFavorite(MessageModel message) async {
    final result = await favoriteDao.addFavorite(FavoriteModel(
        ownerName: message.ownerName,
        createdAt: message.createdAt,
        content: message.content));
    var showText = '';
    if (result != null && result > 0) {
      showText = '收藏成功';
    } else {
      showText = '收藏失败';
    }
    if (!mounted) return;
    HiDialog.showSnackBar(context, showText);
  }

  void _copyMessage(MessageModel message) async {
    HiUtils.copyMessage(message.content, context);
  }

  /// 重新生成最后一条 assistant 回复：删除旧回复，回退该轮历史，用对应的用户
  /// 提问重新发起一次请求。仅支持最新一条回复（见 [_canRegenerate]）。
  Future<void> _regenerate(MessageModel assistantMessage) async {
    if (!_canRegenerate(assistantMessage) ||
        !_accountCurrent ||
        !_canStartAIRequest(showPrompt: true)) {
      return;
    }
    final list = chatController.initialMessageList;
    final idx =
        list.indexWhere((m) => m.createdAt == assistantMessage.createdAt);
    MessageModel? userMessage;
    for (var i = idx + 1; i >= 0 && i < list.length; i++) {
      if (list[i].ownerType == OwnerType.sender) {
        userMessage = list[i];
        break;
      }
    }
    if (userMessage == null) {
      HiDialog.showSnackBar(context, '找不到对应的提问，无法重新生成');
      return;
    }
    await _retryUserMessage(userMessage, oldReply: assistantMessage);
  }

  Future<void> _retryUserMessage(MessageModel userMessage,
      {MessageModel? oldReply, bool resumeTask = false}) async {
    if (!_ready ||
        !_accountCurrent ||
        _isStreaming ||
        _savingReasoningEffort ||
        !_canStartAIRequest(showPrompt: true)) {
      return;
    }
    final resumeGeneration = resumeTask ? _agentTask?.generation : null;
    // 重生成/重试不采集旧轮次，不在重开或续跑时补扫。
    _personalMemoryTurn = null;
    var handedOff = false;
    _userStopped = false;
    _streamAbortCompleter = Completer<void>();
    final settled = Completer<void>();
    _sendRoundSettled = settled;
    _taskCheckpointFailed = false;
    _backgroundNotice = null;
    _invalidatePrediction();
    setState(() {
      _isStreaming = true;
      _sendProgress = const ChatSendProgress('准备重试');
    });
    try {
      final rawSettings = context.read<AISettingsProvider>().settings;
      final systemPrompt = await _assistantSystemPromptForSafely(
          userMessage.content,
          resumeTask: resumeTask,
          workspaceInputs: completionDao
                  .currentFileHistory[userMessage.createdAt]?.isNotEmpty ??
              false);
      if (_sendCancelled) return;
      final settings = _effective(rawSettings);
      final candidate = CompletionDao(
        memoryContextResolver: _memoryResolver(),
        chatService: widget.chatService,
        manageContext: true,
        settings: settings,
        systemPrompt: systemPrompt,
        messages: oldReply == null
            ? completionDao.currentMessages
                .where((m) => m.createdAt != userMessage.createdAt)
                .toList()
            : completionDao.currentMessages,
        toolHistory: completionDao.currentToolHistory,
        fileHistory: completionDao.currentFileHistory,
        roleContinuationHistory: completionDao.currentRoleContinuationHistory,
        protocolHistory: completionDao.currentProtocolHistory,
        conversationId: widget.conversationModel.cid,
        semanticSummaryService: _summaryServiceFor(settings),
      );
      final persistedAttachments =
          candidate.attachmentsForUserMessage(userMessage);
      // 未完成的孤立提问可能来自旧版或异常退出；只从请求副本剔除，不修改原记录。
      if (oldReply != null) {
        candidate.dropLastTurn();
      }
      final caps = ChatService.capabilitiesFor(settings);
      var blocks = _blockStore.blocksFor(chatMessageKey(userMessage.createdAt));
      if (blocks.isEmpty) {
        final stored =
            await messageDao.getBlocksByCreatedAt([userMessage.createdAt]);
        blocks = MessageBlock.decodeList(
            stored[chatMessageKey(userMessage.createdAt)]);
      }
      if (_sendCancelled) return;
      final officialDeepSeek = (settings.mode == AIMode.backend &&
              ModelCapabilities.isDeepSeekVisionModel(
                  settings.effectiveModel)) ||
          (settings.mode == AIMode.local &&
              Uri.tryParse(settings.activeLocal.baseUrl)?.host.toLowerCase() ==
                  'api.deepseek.com');
      final fileMetas =
          blocks.whereType<FileBlock>().map((b) => b.file).toList();
      final inputIds = <int>[];
      final workspaceTexts = <String>[];
      final legacyMetas = <FileMetadata>[];
      for (final meta in fileMetas) {
        final id = meta.workspaceFileId;
        if (id == null) {
          legacyMetas.add(meta);
          continue;
        }
        final file = await _workspace!.getFile(id);
        if (file == null) {
          throw const RetryAttachmentException('工作区附件已失效，请重新选择文件；原提问和回复已保留');
        }
        inputIds.add(id);
        if (_taskMode) {
          workspaceTexts
              .add(WorkspaceAttachmentProcessor.describe(file.toJson()));
        } else {
          final revision = await _workspace!.getRevision(id);
          final limit =
              settings.attachmentProcessingLimits.normalized.maxTextChars;
          final text = revision.content.length > limit
              ? '${revision.content.substring(0, limit)}\n[附件文字已截断，启用任务模式可按需读取全文]'
              : revision.content;
          workspaceTexts
              .add('[附件「${file.name}」内容开始]\n$text\n[附件「${file.name}」内容结束]');
        }
      }
      final persistedForRetry = fileMetas.any((m) => m.workspaceFileId != null)
          ? ChatAttachments(
              images: persistedAttachments.images,
              nativeFiles: persistedAttachments.nativeFiles,
              extraText: [
                ...legacyMetas.map((m) => m.extractedText).whereType<String>(),
                ...workspaceTexts,
                historyReferencesExtraText(
                    blocks.whereType<ReferenceBlock>().map((b) => b.reference)),
              ].where((text) => text.isNotEmpty).join('\n\n'))
          : persistedAttachments;
      final restored = await const RetryAttachmentRestorer().restore(
        persisted: persistedForRetry,
        files: legacyMetas,
        capabilities: officialDeepSeek ? caps.copyWith(pdf: false) : caps,
        limits: settings.attachmentProcessingLimits,
        onProgress: _onSendProgress,
        abortTrigger: _streamAbortCompleter?.future,
        isCancelled: () => _sendCancelled,
      );
      if (restored.hasWarnings &&
          !await _confirmAttachmentWarnings(restored.diagnostics)) {
        return;
      }
      if (_sendCancelled) return;
      final attachments = restored.attachments;
      if (blocks.any((block) => block is ReferenceBlock)) {
        // 引用重放仍遵守当前整轮文字预算，且在删除旧回复前拒绝超限。
        AttachmentBatchBudget(limits: settings.attachmentProcessingLimits)
            .consumeText(attachments.extraText);
      }
      final webSearch =
          settings.webSearchEnabled && settings.webSearchConfigured;
      final tools = await _toolsForSend(settings, caps, webSearch);
      if (_sendCancelled) return;
      final plan = candidate.previewContext(
          prompt: userMessage.content, attachments: attachments, tools: tools);
      _plannedPrompt = userMessage.content;
      _plannedAttachmentInfo =
          '${attachments.images.length} 张图片，${attachments.nativeFiles.length} 份原生文件';
      _plannedFileText = attachments.extraText;
      _onContextPlan(plan);
      if (!plan.canSend) throw ChatContextBudgetException(plan);
      if (resumeTask) {
        // 附件准备可能等待较久；在替换旧回复前重新核对持久化断点。
        final service = await AgentTaskDetailService.create(messageDao.storage,
            accountHash: _pageAccount, executor: _taskExecutor);
        final current = resumeGeneration == null
            ? null
            : await service.conversationForResume(widget.conversationModel.cid,
                userCreatedAt: userMessage.createdAt,
                generation: resumeGeneration);
        if (!mounted ||
            _sendCancelled ||
            _applicationInBackground ||
            !(ModalRoute.of(context)?.isCurrent ?? false)) {
          return;
        }
        if (current == null ||
            _agentTask?.generation != resumeGeneration ||
            _agentTask?.userCreatedAt != userMessage.createdAt ||
            _taskExecutor.lookup(_taskKey)?.busy == true) {
          HiDialog.showSnackBar(context, '任务状态已变化，原回复已保留，请查看最新详情');
          return;
        }
      }
      // 检查成功后才替换旧回复；提问行始终沿用，重试不会复制提问。
      if (oldReply != null) {
        await messageDao.deleteMessageByCreatedAt(oldReply.createdAt);
        if (!_accountCurrent) return;
        chatController.deleteMessage(oldReply);
        _blockStore.removeMessage(chatMessageKey(oldReply.createdAt));
      }
      completionDao = candidate;
      _currentSettings = rawSettings;
      _daoSystemPrompt = systemPrompt;
      _daoAssistant = _assistant;
      _daoModelProviderId = widget.conversationModel.modelProviderId;
      _daoModelId = widget.conversationModel.modelId;
      _daoReasoningEffort = widget.conversationModel.deepSeekReasoningEffort;
      _daoTaskMode = _taskMode;
      _lastUserModel = userMessage;
      _lastUserFileText = attachments.extraText;
      if (_taskMode) {
        await _agentTask!.begin(
            userAt: userMessage.createdAt,
            input: userMessage.content,
            resume: resumeTask);
        await _workspaceTools!
            .beginTurn(userMessage.createdAt, inputIds, resume: resumeTask);
      }
      _markUsageRound(prompt: userMessage.content, settings: settings);
      if (_taskMode) {
        await _enqueueAgentRun(userMessage, settings, attachments,
            webSearch: webSearch && tools == null, tools: tools);
        handedOff = true;
        return;
      }
      await _startBackgroundExecution();
      if (_sendCancelled) {
        if (_accountCurrent) await _saveFailedReply('已停止发送，可重试此条提问');
        return;
      }
      if (settings.streamEnabled) {
        await _onSendStream(userMessage.content, attachments,
            webSearch: webSearch && tools == null, tools: tools);
      } else {
        await _onSendNonStream(userMessage.content, attachments,
            webSearch: webSearch);
      }
    } catch (e) {
      if (mounted && _accountCurrent) {
        if (_lastUserModel != null) {
          await _saveFailedReply(_friendlyError(e));
        } else if (!_userStopped) {
          HiDialog.showSnackBar(context, '重试前检查失败：${_friendlyError(e)}');
        }
      }
    } finally {
      _abortStreamRequest();
      _streamAbortCompleter = null;
      _clearUsageRound();
      if (!handedOff) await _finishTaskCheckpoint(accepted: true);
      _settleSendRound(settled);
      await _releaseBackgroundExecution(
          success: _agentTask?.status == 'complete');
      if (!handedOff && mounted && _accountCurrent) {
        setState(() {
          _isStreaming = false;
          _sendProgress = null;
        });
        _requestPredictionAfterReply();
      }
    }
  }

  _deleteMessage(MessageModel message) async {
    _invalidatePrediction();
    try {
      // 本次会话内新消息的内存模型可能没有数据库 id（id 为 null），
      // 此时按 createdAt 删除，避免 message.id! 空断言抛异常导致删除「不生效」。
      final result = message.id != null
          ? await messageDao.deleteMessage(message.id!)
          : await messageDao.deleteMessageByCreatedAt(message.createdAt);
      if (result > 0) {
        chatController.deleteMessage(message);
        _blockStore.removeMessage(chatMessageKey(message.createdAt));
        _notifyConversationListUpdate();
        AILogger.log('message deleted');
      }
    } catch (e) {
      AILogger.log('delete message error: $e');
    }
  }
}

class _RoleContextPreviewSheet extends StatefulWidget {
  final AssistantModel? assistant;
  final ConversationModel conversation;
  final List<AssistantMemoryModel> memories;
  final List<String> recentMessages;

  const _RoleContextPreviewSheet({
    required this.assistant,
    required this.conversation,
    required this.memories,
    this.recentMessages = const [],
  });

  @override
  State<_RoleContextPreviewSheet> createState() =>
      _RoleContextPreviewSheetState();
}

class _RoleContextPreviewSheetState extends State<_RoleContextPreviewSheet> {
  late final TextEditingController _inputCtl;
  int _previewRequest = 0;
  String _preview = '';
  String _summary = '正在匹配世界书…';

  @override
  void initState() {
    super.initState();
    _inputCtl = TextEditingController()..addListener(_onInputChanged);
    _onInputChanged();
  }

  @override
  void dispose() {
    _inputCtl
      ..removeListener(_onInputChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _onInputChanged() async {
    final request = ++_previewRequest;
    setState(() {
      _preview = '';
      _summary = '正在匹配世界书…';
    });
    final scanText = ConversationRoleContextPreview.scanText(
      userInput: _inputCtl.text,
      recentMessages: widget.recentMessages,
    );
    final preview = await ConversationRoleContextPreview.buildSafely(
      assistant: widget.assistant,
      userInput: scanText,
      conversation: widget.conversation,
      memories: widget.memories,
    );
    final summary = await ConversationRoleContextPreview.summarySafely(
      assistant: widget.assistant,
      userInput: scanText,
      conversation: widget.conversation,
      memories: widget.memories,
    );
    if (!mounted || request != _previewRequest) return;
    setState(() {
      _preview = preview;
      _summary = summary;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final summary = _summary;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '下一轮上下文',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '复制上下文',
                  onPressed: preview.trim().isEmpty
                      ? null
                      : () => _copyPreview(context, preview),
                  icon: const Icon(Icons.copy_outlined),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _inputCtl,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: '模拟下一条用户消息',
                border: visual.isAnime ? null : const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              summary,
              style: TextStyle(
                fontSize: 13,
                color:
                    visual.isAnime ? scheme.onSurfaceVariant : Colors.black54,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.58,
              ),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(visual.isAnime ? 12 : 0),
                decoration: visual.isAnime
                    ? BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: scheme.outlineVariant),
                      )
                    : null,
                child: SingleChildScrollView(
                  child: SelectableText(
                    preview.trim().isEmpty ? '暂无可注入上下文' : preview,
                    style: const TextStyle(fontSize: 13, height: 1.35),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyPreview(BuildContext context, String preview) async {
    final text = preview.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    HiDialog.showSnackBar(context, '下一轮上下文已复制');
  }
}

class _AssistantMemorySaveDialog extends StatefulWidget {
  final String initialText;

  const _AssistantMemorySaveDialog({required this.initialText});

  @override
  State<_AssistantMemorySaveDialog> createState() =>
      _AssistantMemorySaveDialogState();
}

class _AssistantMemorySaveDialogState
    extends State<_AssistantMemorySaveDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保存长期记忆'),
      content: TextField(
        controller: _controller,
        minLines: 3,
        maxLines: 6,
        decoration: const InputDecoration(
          hintText: '写成之后希望助手长期记住的事实或偏好',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text.trim()),
            child: const Text('保存')),
      ],
    );
  }
}

class _WorldBookQuickSaveResult {
  final String keywords;
  final String content;
  final bool enabled;
  final int priority;

  const _WorldBookQuickSaveResult({
    required this.keywords,
    required this.content,
    this.enabled = true,
    this.priority = 0,
  });
}

class _WorldBookQuickSaveDialog extends StatefulWidget {
  final String initialContent;

  const _WorldBookQuickSaveDialog({required this.initialContent});

  @override
  State<_WorldBookQuickSaveDialog> createState() =>
      _WorldBookQuickSaveDialogState();
}

class _WorldBookQuickSaveDialogState extends State<_WorldBookQuickSaveDialog> {
  late final TextEditingController _keywordsCtl;
  late final TextEditingController _contentCtl;
  late final TextEditingController _priorityCtl;
  late bool _enabled;
  String? _contentError;

  @override
  void initState() {
    super.initState();
    _keywordsCtl = TextEditingController();
    _contentCtl = TextEditingController(text: widget.initialContent);
    _priorityCtl = TextEditingController(text: '0');
    _enabled = true;
  }

  @override
  void dispose() {
    _keywordsCtl.dispose();
    _contentCtl.dispose();
    _priorityCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('加入世界书'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              title: const Text('启用条目'),
              subtitle: const Text('关闭后保留在世界书中，但不会注入上下文'),
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keywordsCtl,
              decoration: const InputDecoration(
                labelText: '触发关键词',
                hintText: '多个关键词用逗号分隔；留空表示常驻',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _priorityCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '优先级',
                hintText: '默认 0；数值越大越先注入',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentCtl,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '设定内容',
                hintText: '写下命中后要注入给角色的设定',
                border: OutlineInputBorder(),
              ).copyWith(errorText: _contentError),
              onChanged: (_) {
                if (_contentError != null) {
                  setState(() => _contentError = null);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    if (_contentCtl.text.trim().isEmpty) {
      setState(() => _contentError = '请填写设定内容');
      return;
    }
    Navigator.pop(
      context,
      _WorldBookQuickSaveResult(
        keywords: _keywordsCtl.text,
        content: _contentCtl.text,
        enabled: _enabled,
        priority: int.tryParse(_priorityCtl.text.trim()) ?? 0,
      ),
    );
  }
}

class _ExampleDialogQuickSaveDialog extends StatefulWidget {
  final String initialText;

  const _ExampleDialogQuickSaveDialog({required this.initialText});

  @override
  State<_ExampleDialogQuickSaveDialog> createState() =>
      _ExampleDialogQuickSaveDialogState();
}

class _ExampleDialogQuickSaveDialogState
    extends State<_ExampleDialogQuickSaveDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('存为示例对话'),
      content: TextField(
        controller: _controller,
        minLines: 5,
        maxLines: 10,
        decoration: const InputDecoration(
          hintText: '建议保留“用户：... / 助手：...”格式',
          border: OutlineInputBorder(),
        ).copyWith(errorText: _errorText),
        onChanged: (_) {
          if (_errorText != null) setState(() => _errorText = null);
        },
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _errorText = '请填写示例对话');
      return;
    }
    Navigator.pop(context, text);
  }
}

class _RoleStateQuickEditDialog extends StatefulWidget {
  final ConversationRoleStateDraft draft;

  const _RoleStateQuickEditDialog({required this.draft});

  @override
  State<_RoleStateQuickEditDialog> createState() =>
      _RoleStateQuickEditDialogState();
}

class _RoleStateQuickEditDialogState extends State<_RoleStateQuickEditDialog> {
  late final TextEditingController _sceneCtl;
  late final TextEditingController _relationshipCtl;
  late final TextEditingController _toneCtl;

  @override
  void initState() {
    super.initState();
    _sceneCtl = TextEditingController(text: widget.draft.scene);
    _relationshipCtl = TextEditingController(text: widget.draft.relationship);
    _toneCtl = TextEditingController(text: widget.draft.toneNote);
  }

  @override
  void dispose() {
    _sceneCtl.dispose();
    _relationshipCtl.dispose();
    _toneCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('更新会话状态'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _sceneCtl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '当前场景',
                hintText: '例如：雨夜旧书店二楼',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _relationshipCtl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '关系备注',
                hintText: '例如：熟悉但仍保持距离',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _toneCtl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '语气备注',
                hintText: '例如：克制、轻声、不要解释设定',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    Navigator.pop(
      context,
      ConversationRoleStateDraft(
        scene: _sceneCtl.text.trim(),
        relationship: _relationshipCtl.text.trim(),
        toneNote: _toneCtl.text.trim(),
      ),
    );
  }
}
