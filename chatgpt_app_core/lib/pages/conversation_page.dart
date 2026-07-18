import 'dart:async';

import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_send_guard.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
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
import 'package:chatgpt_app_core/pages/ai_health_check_page.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:chatgpt_app_core/util/scroll_jump.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/ai_readiness_card.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/widget/configured_ai_model_picker_sheet.dart';
import 'package:chatgpt_app_core/widget/forward_sheet.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
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
  final ReadAloudService? readAloudService;

  const ConversationPage({
    super.key,
    required this.conversationModel,
    this.conversationUpdate,
    this.initialPrompt = '',
    this.initialAssistantOpening = '',
    this.initialTargetCreatedAt,
    this.readAloudService,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  ///若为新建的对话框，则_pendingUpdate为true
  bool get _pendingUpdate => widget.conversationModel.title == null;

  ///是否有通知聊天列表页更新当前会话
  bool _hadUpdate = false;
  late Map<String, dynamic> userInfo;
  String _inputMessage = "";
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

  /// 块化消息系统：规范化的块仓库（每页一个，随页面生命周期销毁）。
  final ChatBlockStore _blockStore = ChatBlockStore();

  /// 当前活跃的流式订阅 / 分发器 / 完成信号 / 接收方气泡（供「停止」与销毁时收尾）。
  StreamSubscription<StreamEvent>? _activeEventSub;
  StreamDispatcher? _activeDispatcher;
  Completer<void>? _streamCompleter;
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

  /// 会话绑定的助手（阶段七）。null = 未绑定 / 已被删除（自然回落无助手）。
  AssistantModel? _assistant;

  /// 构建当前 completionDao 时所用的助手，用于「切换助手后重建 Dao」的判断。
  AssistantModel? _daoAssistant;
  String? _daoSystemPrompt;
  String? _daoModelProviderId;
  String? _daoModelId;
  AssistantDao? _assistantDao;
  AssistantMemoryDao? _assistantMemoryDao;
  List<AssistantMemoryModel> _assistantMemories = const [];

  /// 应用助手的模型覆盖后的设置 —— 能力位与请求构造都用它，
  /// 保证「助手指定了模型时，capabilitiesFor 用覆盖后的模型算」。
  AISettings _effective(AISettings s) {
    final next = (_assistant?.applyTo(s) ?? s).clone();
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

  String? _assistantSystemPromptFor(String inputMessage) {
    final scanText = _roleMemoryScanText(inputMessage);
    final preview = ConversationRoleContextPreview.build(
      assistant: _assistant,
      userInput: scanText,
      conversation: widget.conversationModel,
      memories: _assistantMemories,
    );
    return preview.trim().isEmpty ? null : preview;
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
  ToolActionContext _toolActions() => ToolActionContext.forCurrentAccount(
        confirm: _confirmToolAction,
        assistantId: _assistant?.id,
        projectId: widget.conversationModel.projectId,
        runJs: JsRuntimeService.isSupported
            ? (code, input) => const JsRuntimeService().run(code, input: input)
            : null,
      );

  /// 发现当前设置下的 MCP 工具（方案 A 直连 + 方案 B 后端 Host）。MCP 工具
  /// 来自外部不可信，执行前经 [_confirmToolAction] 确认（信任源除外）。任何
  /// 来源失败都只返回已成功部分，绝不阻断发送。未配置 MCP 时直接返回空。
  ///
  /// 按助手绑定过滤（item 5）：绑定了助手时，只暴露该助手 toolIds 里勾选的
  /// MCP 工具（与内置工具一致）；无助手的临时会话则暴露全部（受设置开关约束）。
  Future<List<ChatTool>> _discoverMcpTools(AISettings settings) async {
    if (!settings.mcpConfigured) return const [];
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final auditDao = await ToolAuditDao.create(storage);
    final all = await McpToolSource.discover(settings,
        confirm: _confirmToolAction,
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
              receiverBackgroundColor: visualTheme.isAnime
                  ? colorScheme.primaryContainer.withValues(alpha: 0.78)
                  : null,
              senderBackgroundColor: visualTheme.isAnime
                  ? colorScheme.secondaryContainer.withValues(alpha: 0.82)
                  : null,
              receiverAvatarBackgroundColor:
                  visualTheme.isAnime ? colorScheme.primary : null,
              senderAvatarBackgroundColor:
                  visualTheme.isAnime ? colorScheme.secondary : null,
              textColor: visualTheme.isAnime ? colorScheme.onSurface : null,
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
    return MessageInputWidget(
      '请输入',
      enable: !_isStreaming,
      isStreaming: _isStreaming,
      initialText: widget.initialPrompt,
      onStop: _isStreaming ? _stopStream : null,
      onChanged: (text) => _inputMessage = text,
      canSend: () => _canStartAIRequest(showPrompt: true),
      onSend: () => _onSend(_inputMessage),
      // 联网搜索开关（阶段五）：当前所选服务商配置了 key 才展示；独立于
      // caps.tool，搜索结果以上下文回填，任何模型都可用（与 Cherry 一致）。
      showWebSearch: settings.webSearchConfigured,
      webSearchEnabled: settings.webSearchEnabled,
      onToggleWebSearch: _toggleWebSearch,
      modelLabel: _modelLabel(settings),
      onModelTap: _switchModel,
      speechInputEnabled: widget.conversationModel.speechInputEnabled ?? true,
      speechLocale: widget.conversationModel.voiceLocale,
      pendingImages: _pendingImages,
      imagesEnabled: caps.image,
      imagesDisabledReason: caps.image ? '' : '当前模型不支持图片，请切换 gpt-4o 等多模态模型',
      onImagesPicked: (images) => setState(() => _pendingImages = images),
      onRemoveImage: (index) {
        setState(() {
          _pendingImages = List.from(_pendingImages)..removeAt(index);
        });
      },
      // 文件入口不按能力位关闭：不支持原生文件的模型走抽文本降级（阶段四）。
      pendingFiles: _pendingFiles,
      onFilesPicked: (files) => setState(() => _pendingFiles = files),
      onRemoveFile: (index) {
        setState(() {
          _pendingFiles = List.from(_pendingFiles)..removeAt(index);
        });
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _readAloudService = widget.readAloudService ?? HybridReadAloudService();
    _prewarmReadAloudIfNeeded();
    _doInit();
  }

  @override
  void dispose() {
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
    _activeEventSub?.cancel();
    unawaited(_readAloudService.stop());
    _itemPositionsListener.itemPositions.removeListener(_onPositionsChanged);
    _blockStore.dispose();
    _updateConversation();
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
          children: [_chatList, _inputWidget(caps, settings)],
        ),
      ),
    );
  }

  /// 切换联网搜索开关：当前会话优先覆盖，避免改动全局 AI 设置影响其它会话。
  void _toggleWebSearch() async {
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
              trailing:
                  _readAloudBubbleButton(message.content, message.createdAt),
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
          messageKey: key,
          showCharCount: message.ownerType == OwnerType.receiver,
          footerTrailing: message.ownerType == OwnerType.receiver
              ? _readAloudBubbleButton(message.content, message.createdAt)
              : null,
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

  Widget _readAloudBubbleButton(String text, int createdAt) {
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
  void _onSend(final String inputMessage) async {
    if (!_canStartAIRequest(showPrompt: true)) return;
    // 防止并发发送：流式进行中直接忽略（输入框回车键也走这里）。
    // 必须在任何 await 之前同步置位 _isStreaming，否则双击/连按会在
    // 图片编码的 await 间隙挤进第二次发送，覆盖活跃流字段、悬挂前一条流。
    if (_isStreaming) return;
    setState(() {
      _isStreaming = true;
    });
    widget.conversationModel.hadChanged = true;

    // 仅在 settings / 助手变更时重建 CompletionDao，避免每次发送都新建实例。
    // CompletionDao 用「应用助手模型覆盖后」的设置 + 助手系统提示词（阶段七）。
    final rawSettings = context.read<AISettingsProvider>().settings;
    final assistantSystemPrompt = _assistantSystemPromptFor(inputMessage);
    final modelChanged =
        _daoModelProviderId != widget.conversationModel.modelProviderId ||
            _daoModelId != widget.conversationModel.modelId;
    if (rawSettings != _currentSettings ||
        !identical(_assistant, _daoAssistant) ||
        assistantSystemPrompt != _daoSystemPrompt ||
        modelChanged) {
      _currentSettings = rawSettings;
      _daoAssistant = _assistant;
      _daoSystemPrompt = assistantSystemPrompt;
      _daoModelProviderId = widget.conversationModel.modelProviderId;
      _daoModelId = widget.conversationModel.modelId;
      completionDao = CompletionDao(
          settings: _effective(rawSettings),
          systemPrompt: assistantSystemPrompt,
          messages: completionDao.currentMessages,
          toolHistory: completionDao.currentToolHistory,
          fileHistory: completionDao.currentFileHistory,
          roleContinuationHistory:
              completionDao.currentRoleContinuationHistory);
    }
    final settings = _effective(rawSettings);
    _markUsageRound(prompt: inputMessage, settings: settings);
    // 能力探测（与 build 里驱动入口开关的是同一来源）：决定附件走原生还是降级。
    final caps = ChatService.capabilitiesFor(settings);

    // 编码图片为 base64（MIME 修正收敛在 FileProcessor）
    final b64Images = _pendingImages.isNotEmpty
        ? await FileProcessor.encodeImages(_pendingImages)
        : null;
    final pendingPaths =
        _pendingImages.isNotEmpty ? List<String>.from(_pendingImages) : null;
    // 处理文件（阶段四）：能原生喂模型就喂，不能就降级抽文本拼 prompt。
    final processed = _pendingFiles.isNotEmpty
        ? await FileProcessor.process(List<String>.from(_pendingFiles), caps)
        : const ProcessedFiles();

    // 记下本轮用户消息：assistant 收尾时连同它一起追加进会话历史（见 _persistAssistant）。
    // 此刻不直接加入 completionDao 历史，否则会与稍后作为 prompt 单独发送的当前轮重复。
    final userModel = _genMessageModel(
      ownerType: OwnerType.sender,
      message: inputMessage,
      imagePaths: pendingPaths,
      imageUrlsOrB64: b64Images,
    );
    _lastUserModel = userModel;
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
        : AssistantRoleCardService.matchMemoryEntries(
            _assistant!.memoryBook,
            _roleMemoryScanText(inputMessage),
          );
    if (memoryHits.isNotEmpty) {
      _memoryHitsByMessageAt[userModel.createdAt] = memoryHits;
    }
    AssistantMemoryContextBudget? memoryBudget;
    if (_assistant != null) {
      memoryBudget = AssistantMemoryBook.budgetContext(
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
    // 附件降级文本随本轮用户消息记入历史（遗留项 6：后续轮从 _fileHistory 重建）。
    _lastUserFileText = processed.extraText;
    if (processed.metas.isNotEmpty || roleContextSnapshot.isNotEmpty) {
      // 带文件或角色上下文快照的用户消息：建块化内容并随消息落库。
      _addUserMessageWithBlocks(
        userModel,
        pendingPaths,
        processed.metas,
        roleContextSnapshot: roleContextSnapshot,
        roleMemoryBudget: memoryBudget?.affected == true ? memoryBudget : null,
        roleMemoryHits: memoryHits,
      );
    } else {
      _addMessage(userModel);
    }
    setState(() {
      _pendingImages = [];
      _pendingFiles = [];
    });

    final attachments = ChatAttachments(
      images: b64Images ?? const [],
      nativeFiles: processed.nativeFiles,
      extraText: processed.extraText,
    );
    // 联网搜索（阶段五）：用户开关 + 当前服务商 key 已配置才启用。
    final webSearch = settings.webSearchEnabled && settings.webSearchConfigured;
    // 选路（阶段六决策）：模型支持工具调用（caps.tool）-> 注册工具、由模型
    // 自主决定是否调用（ToolLoopRunner）；否则回落阶段五的意图编排。两条路
    // 互斥，引用来源（CitationBlock）体验一致。阶段七：助手关了工具开关回落。
    // L1：注册表由所绑助手的 toolIds 拼；会话联网开关经 forceWebSearch 兼容旧行为
    // （助手显式绑定 web_search 时，即使联网开关关着也暴露给模型）。
    final allowTools = _assistant?.useTools ?? true;
    // MCP 工具（方案 A/B）：仅当工具回路可能启用时才去发现，省掉无谓网络往返。
    final mcpTools = (caps.tool && settings.streamEnabled && allowTools)
        ? await _discoverMcpTools(settings)
        : const <ChatTool>[];
    final registry = ToolRegistry.fromAssistant(settings, _effectiveToolIds,
        forceWebSearch: webSearch,
        actions: _toolActions(),
        extraTools: mcpTools);
    final tools =
        caps.tool && settings.streamEnabled && allowTools && !registry.isEmpty
            ? registry
            : null;
    if (settings.streamEnabled) {
      await _onSendStream(inputMessage, attachments,
          webSearch: webSearch && tools == null, tools: tools);
    } else {
      // 非流式保持阶段五意图编排（工具回路仅接流式路径，见指南 §7 实施记录）。
      await _onSendNonStream(inputMessage, attachments, webSearch: webSearch);
    }
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
    if (!mounted) return false;
    final ok = await showDialog<bool>(
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
      ),
    );
    return ok == true;
  }

  /// 带文件的用户消息：把图片/文件/文本组装成块，seed 进块仓库并连块落库。
  /// （纯图片消息沿用默认气泡的九宫格渲染，不走块化 —— 保留点击预览。）
  void _addUserMessageWithBlocks(
    MessageModel userModel,
    List<String>? imagePaths,
    List<FileMetadata> metas, {
    String roleContextSnapshot = '',
    AssistantMemoryContextBudget? roleMemoryBudget,
    List<AssistantMemoryEntryPreview> roleMemoryHits = const [],
  }) {
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
    _blockStore.seedMessage(key, blocks);
    _blockStore.commitSeed();
    chatController.addMessage(userModel);
    messageDao.saveMessageWithBlocks(userModel,
        blocksJson: MessageBlock.encodeList(blocks));
    _notifyConversationListUpdate();
  }

  /// 非流式 + 联网搜索的回复：组装「正文块 + 引用块」，seed 进块仓库并连块落库。
  void _addReceiverMessageWithCitations(
      MessageModel receiverModel, List<WebSearchResult> webResults) {
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
      CitationBlock(
        id: 'blk_${key}_cite_1',
        messageId: key,
        createdAt: receiverModel.createdAt,
        status: MessageBlockStatus.success,
        modelId: _effectiveModelId,
        webResults: webResults,
      ),
    ];
    _blockStore.seedMessage(key, blocks);
    _blockStore.commitSeed();
    chatController.addMessage(receiverModel);
    messageDao.saveMessageWithBlocks(receiverModel,
        blocksJson: MessageBlock.encodeList(blocks));
    _notifyConversationListUpdate();
  }

  void _stopStream() {
    // 用户主动停止：把当前活跃块标记 paused，取消订阅，并放行 await。
    _userStopped = true;
    _activeDispatcher?.onStopped();
    _activeEventSub?.cancel();
    final c = _streamCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _onSendNonStream(
      String inputMessage, ChatAttachments attachments,
      {bool webSearch = false}) async {
    String? response = "";
    var webResults = const <WebSearchResult>[];
    CompletionResult? completionResult;
    try {
      final result = await completionDao.createCompletionsWithSearch(
          prompt: inputMessage,
          attachments: attachments.isEmpty ? null : attachments,
          webSearch: webSearch);
      response = result.content;
      webResults = result.webResults;
      completionResult = result;
    } catch (e) {
      response = e.toString();
      AILogger.log('non-stream error: $e');
    }
    response ??= 'no response';
    final receiverModel =
        _genMessageModel(ownerType: OwnerType.receiver, message: response);
    if (webResults.isNotEmpty) {
      // 带引用来源的回复：正文 + citation 块化落库（消息底部展示可点来源）。
      _addReceiverMessageWithCitations(receiverModel, webResults);
    } else {
      _addMessage(receiverModel);
    }
    // 把本轮追加进历史，使后续轮次携带完整上下文（与流式路径一致）。
    final user = _lastUserModel;
    if (user != null) {
      completionDao.appendTurn(user, receiverModel,
          userFileText: _lastUserFileText);
      _lastUserModel = null;
      _lastUserFileText = '';
      await _recordUsageFromCompletion(
        completionText: response,
        completionResult: completionResult,
        createdAt: receiverModel.createdAt,
      );
      await _readAloudAssistant(receiverModel.content);
      _clearUsageRound();
    }
    setState(() {
      _isStreaming = false;
    });
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

    _userStopped = false;
    final completer = Completer<void>();
    _streamCompleter = completer;
    _activeDispatcher = dispatcher;
    _activeReceiver = receiverModel;

    // 块化分发：把「带类型」事件落到 thinking / mainText / tool 块。
    // token 只更新 _blockStore（ChangeNotifier），不触动消息列表，
    // 因此流式中只有「当前块」重渲染，其它块（如已完成的思考块）不动。
    _activeEventSub = completionDao
        .streamCompletionEvents(
            prompt: inputMessage,
            attachments: attachments.isEmpty ? null : attachments,
            webSearch: webSearch,
            tools: tools)
        .listen(
      (event) {
        if (!mounted || _userStopped) return;
        switch (event.type) {
          case StreamEventType.reasoning:
            dispatcher.onThinkingChunk(event.delta);
            break;
          case StreamEventType.text:
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
            dispatcher.onCitation(event.webResults ?? const []);
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
      _notifyConversationListUpdate();
    } catch (e) {
      if (_disposed) return;
      // 网络/服务错误：插入 error 块并落库。
      AILogger.log('stream exception: $e');
      dispatcher.onError(_friendlyError(e));
      await _persistAssistant(receiverModel, dispatcher);
      _notifyConversationListUpdate();
    } finally {
      _activeEventSub = null;
      _activeDispatcher = null;
      _streamCompleter = null;
      _activeReceiver = null;
      if (mounted) {
        setState(() {
          _isStreaming = false;
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
    await messageDao.saveMessageWithBlocks(finalModel, blocksJson: blocksJson);
    // 把本轮「用户 + assistant」追加进会话历史，使后续轮次携带完整上下文
    // （CompletionDao._messageList 不会自动增长；正文已不含思考内容）。
    // 连块一起传：其中的 ToolBlock 记入工具历史，使工具调用跨轮可见（遗留项 2）。
    final user = _lastUserModel;
    if (user != null) {
      completionDao.appendTurn(user, finalModel,
          assistantBlocks: blocks, userFileText: _lastUserFileText);
      _lastUserModel = null;
      _lastUserFileText = '';
      await _recordUsageFromStream(
        completionText: finalModel.content,
        createdAt: finalModel.createdAt,
      );
      await _readAloudAssistant(finalModel.content);
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
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
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
      avatar = _assistantAvatarForMessage();
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
    userInfo = LoginDao.getUserInfo()!;
    chatController = ChatController(
        initialMessageList: [],
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        timePellet: 60,
        messageContentBuilder: _buildBlockContent);
    // 列表项可见性变化 -> 分页加载更多 + 刷新置顶/置底按钮可见性。
    _itemPositionsListener.itemPositions.addListener(_onPositionsChanged);
    final settings = context.read<AISettingsProvider>().settings;
    _currentSettings = settings;
    _aiName = settings.aiDisplayName;
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    conversationListDao = await ConversationListDao.create(dbManager);
    messageDao =
        await MessageDao.create(dbManager, cid: widget.conversationModel.cid);
    usageDao = await UsageDao.create(dbManager);
    usageRecordService = UsageRecordService(usageDao);
    favoriteDao = await FavoriteDao.create(dbManager);
    // 阶段七：加载会话绑定的助手（先于 CompletionDao 构造，使首轮即带
    // 系统提示词与模型覆盖）。助手已删除时回落 null。
    _assistantDao = await AssistantDao.create(dbManager);
    _assistantMemoryDao = await AssistantMemoryDao.create(dbManager);
    final aid = widget.conversationModel.assistantId;
    if (aid != null) {
      _assistant = await _assistantDao!.getAssistant(aid);
    }
    await _loadAssistantMemories();
    final list = await _loadData();
    chatController.loadMoreData(list);
    _showInitialAssistantOpeningIfNeeded(list);
    await _jumpToInitialTargetMessage();
    // 首帧布局完成后算一次按钮可见性（打开长会话时立即出现「回到顶部」）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPositionsChanged());
    _daoAssistant = _assistant;
    _daoSystemPrompt = _assistantSystemPromptFor('');
    _daoModelProviderId = widget.conversationModel.modelProviderId;
    _daoModelId = widget.conversationModel.modelId;
    // 从持久化块恢复工具调用历史（遗留项 2）+ 附件文本历史（遗留项 6），
    // 使重开会话后工具调用与文件上下文仍跨轮可见。
    final blockHistory = await _loadBlockHistory(list);
    completionDao = CompletionDao(
        settings: _effective(settings),
        systemPrompt: _daoSystemPrompt,
        messages: list,
        toolHistory: blockHistory.$1,
        fileHistory: blockHistory.$2,
        roleContinuationHistory: blockHistory.$3);
    // 刷新标题/能力位（助手是异步加载的，首帧可能还没就位）。
    setState(() {});
  }

  String _assistantAvatarForMessage() {
    final assistant = _assistant;
    if (assistant == null) return '';
    if (assistant.avatarType == AvatarAssetService.imageType) {
      final value = assistant.avatarValue?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    final emoji = assistant.emoji.trim();
    return emoji.isEmpty ? '' : 'emoji:${Uri.encodeComponent(emoji)}';
  }

  /// 会话内切换助手（阶段七）：弹选择器 + 确认，从下一轮开始使用新助手。
  /// 历史消息的 ownerName/avatar 已经随消息落库，不随当前会话助手变化。
  void _openAssistantProfile() async {
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
      widget.conversationModel.assistantId = assistant?.id;
      final avatar = _conversationAvatarForAssistant(assistant);
      widget.conversationModel.avatarType = avatar.$1;
      widget.conversationModel.avatarValue = avatar.$2;
      final assistantVoice = assistant?.defaultVoiceStyle.trim() ?? '';
      if (assistantVoice.isNotEmpty) {
        widget.conversationModel.voiceStyle = assistantVoice;
      }
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

  (String?, String?) _conversationAvatarForAssistant(
      AssistantModel? assistant) {
    if (assistant == null) return (null, null);
    if (assistant.avatarType == AvatarAssetService.imageType &&
        (assistant.avatarValue?.trim().isNotEmpty ?? false)) {
      return (AvatarAssetService.imageType, assistant.avatarValue!.trim());
    }
    final emoji = assistant.emoji.trim();
    if (emoji.isNotEmpty) return ('emoji', emoji);
    return (null, null);
  }

  void _switchModel() async {
    final rawSettings = context.read<AISettingsProvider>().settings;
    final picked = rawSettings.mode == AIMode.backend
        ? await _pickBackendModel(rawSettings)
        : await _pickConfiguredLocalModel(rawSettings);
    if (picked == null || !mounted) return;
    setState(() {
      widget.conversationModel.modelProviderId = picked.providerId;
      widget.conversationModel.modelId = picked.modelId;
    });
    widget.conversationModel.hadChanged = true;
    await conversationListDao.updateModelOverride(
        widget.conversationModel, picked.providerId, picked.modelId);
    if (picked.providerId != null && picked.modelId != null) {
      await _recordModelUsed(picked.providerId!, picked.modelId!);
    }
    if (!mounted) return;
    final label = picked.modelId == null ? '跟随全局设置' : picked.modelId!;
    HiDialog.showSnackBar(context, '当前会话模型：$label');
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
      avatar: _assistantAvatarForMessage(),
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

  void _addMessage(MessageModel model) {
    chatController.addMessage(model);
    messageDao.saveMessage(model);
    _notifyConversationListUpdate();
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
  /// 供 [CompletionDao] 跨轮重建。只读「首页」消息（与 CompletionDao 历史范围一致）。
  Future<(Map<int, List<ToolBlock>>, Map<int, String>, Map<int, String>)>
      _loadBlockHistory(List<MessageModel> list) async {
    if (list.isEmpty) {
      return (
        <int, List<ToolBlock>>{},
        <int, String>{},
        <int, String>{},
      );
    }
    final blocksMap =
        await messageDao.getBlocksByCreatedAt(list.map((m) => m.createdAt));
    if (blocksMap.isEmpty) {
      return (
        <int, List<ToolBlock>>{},
        <int, String>{},
        <int, String>{},
      );
    }
    final tools = <int, List<ToolBlock>>{};
    final files = <int, String>{};
    final continuations = <int, String>{};
    for (final m in list) {
      final json = blocksMap[chatMessageKey(m.createdAt)];
      if (json == null) continue;
      final blocks = MessageBlock.decodeList(json);
      final tb = blocks.whereType<ToolBlock>().toList();
      if (tb.isNotEmpty) tools[m.createdAt] = tb;
      final text = blocks
          .whereType<FileBlock>()
          .map((b) => b.file.extractedText)
          .whereType<String>()
          .join('\n\n');
      if (text.isNotEmpty) files[m.createdAt] = text;
      final continuation = blocks
          .whereType<RoleContinuationBlock>()
          .map((b) => b.content.trim())
          .where((content) => content.isNotEmpty)
          .join('\n');
      if (continuation.isNotEmpty) continuations[m.createdAt] = continuation;
    }
    return (tools, files, continuations);
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
          child: const Text('记住'),
          onTap: () {
            _saveAssistantMemory(message);
          },
        ),
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

  Future<bool> _saveAssistantMemoryText({
    required String initialText,
    required String source,
    required String sourceType,
    required String sourceMessageId,
  }) async {
    final assistantId = _assistant?.id;
    if (assistantId == null || _assistantMemoryDao == null) return false;
    final content = await showDialog<String>(
      context: context,
      builder: (_) => _AssistantMemorySaveDialog(initialText: initialText),
    );
    if (content == null || content.trim().isEmpty) return false;
    if (AssistantMemoryDao.hasDuplicateContent(_assistantMemories, content)) {
      if (mounted) HiDialog.showSnackBar(context, '这条长期记忆已存在');
      return false;
    }
    final id = await _assistantMemoryDao!.saveMemory(
      AssistantMemoryModel.confirmedFromConversation(
        assistantId: assistantId,
        content: content,
        source: source,
        sourceType: sourceType,
        conversationId: widget.conversationModel.cid.toString(),
        messageId: sourceMessageId,
      ),
    );
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
  void _regenerate(MessageModel assistantMessage) async {
    if (!_canRegenerate(assistantMessage)) return;
    // 找到该回复对应的用户提问：列表新→旧，紧邻其后的第一条 sender 消息。
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

    setState(() => _isStreaming = true);

    // 删除旧的 assistant 回复（UI + DB + 块仓库）。
    try {
      if (assistantMessage.id != null) {
        await messageDao.deleteMessage(assistantMessage.id!);
      } else {
        // 刚流式生成的回复还没有数据库 id，按 createdAt 删除旧行，
        // 否则旧回复会残留在 DB，重进会话时出现重复。
        await messageDao.deleteMessageByCreatedAt(assistantMessage.createdAt);
      }
    } catch (e) {
      AILogger.log('regenerate: delete old reply failed: $e');
    }
    chatController.deleteMessage(assistantMessage);
    _blockStore.removeMessage(chatMessageKey(assistantMessage.createdAt));

    // 回退 completionDao 历史里这一轮，避免把同一用户提问既留在历史又作为
    // 当前 prompt 重发；收尾时由 _persistAssistant 再次配对入历史。
    completionDao.dropLastTurn();
    _lastUserModel = userMessage;
    _lastUserFileText = '';

    // 复用当前设置/助手构造请求（与 _onSend 尾部选路一致）。
    final settings = _effective(_currentSettings);
    final caps = ChatService.capabilitiesFor(settings);
    // 复原原提问的图片附件（若有）；文件降级文本不重建（少见，从简）。
    final images = userMessage.imageUrlsOrB64 ?? const <String>[];
    final attachments = ChatAttachments(images: images);
    final webSearch = settings.webSearchEnabled && settings.webSearchConfigured;
    final allowTools = _assistant?.useTools ?? true;
    final mcpTools = (caps.tool && settings.streamEnabled && allowTools)
        ? await _discoverMcpTools(settings)
        : const <ChatTool>[];
    final registry = ToolRegistry.fromAssistant(settings, _effectiveToolIds,
        forceWebSearch: webSearch,
        actions: _toolActions(),
        extraTools: mcpTools);
    final tools =
        caps.tool && settings.streamEnabled && allowTools && !registry.isEmpty
            ? registry
            : null;
    if (settings.streamEnabled) {
      await _onSendStream(userMessage.content, attachments,
          webSearch: webSearch && tools == null, tools: tools);
    } else {
      await _onSendNonStream(userMessage.content, attachments,
          webSearch: webSearch);
    }
  }

  _deleteMessage(MessageModel message) async {
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

  @override
  void initState() {
    super.initState();
    _inputCtl = TextEditingController()..addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _inputCtl
      ..removeListener(_onInputChanged)
      ..dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final scanText = ConversationRoleContextPreview.scanText(
      userInput: _inputCtl.text,
      recentMessages: widget.recentMessages,
    );
    final preview = ConversationRoleContextPreview.build(
      assistant: widget.assistant,
      userInput: scanText,
      conversation: widget.conversation,
      memories: widget.memories,
    );
    final summary = ConversationRoleContextPreview.summary(
      assistant: widget.assistant,
      userInput: scanText,
      conversation: widget.conversation,
      memories: widget.memories,
    );
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
