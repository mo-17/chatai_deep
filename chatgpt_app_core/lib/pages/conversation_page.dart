import 'dart:async';

import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
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
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:chatgpt_app_core/util/scroll_jump.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/widget/forward_sheet.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';
// ItemScrollController / ItemPositionsListener 经 chat_message 的 chat_controller.dart
// 再导出（见该文件顶部 export），无需直接依赖 scrollable_positioned_list。

typedef OnConversationUpdate = void Function(
    ConversationModel conversationModel);

enum _ConversationModelTestState { idle, running, success, failure }

enum _ModelFilter { all, available, image, tool, reasoning }

///聊天对话框页面
class ConversationPage extends StatefulWidget {
  final ConversationModel conversationModel;
  final OnConversationUpdate? conversationUpdate;

  const ConversationPage(
      {Key? key, required this.conversationModel, this.conversationUpdate})
      : super(key: key);

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

  /// 块化消息系统：规范化的块仓库（每页一个，随页面生命周期销毁）。
  final ChatBlockStore _blockStore = ChatBlockStore();

  /// 当前活跃的流式订阅 / 分发器 / 完成信号 / 接收方气泡（供「停止」与销毁时收尾）。
  StreamSubscription<StreamEvent>? _activeEventSub;
  StreamDispatcher? _activeDispatcher;
  Completer<void>? _streamCompleter;
  MessageModel? _activeReceiver;

  ///本轮用户消息，assistant 收尾时与之配对追加进会话历史。
  MessageModel? _lastUserModel;

  ///本轮附件的降级文本，随 [_lastUserModel] 一起追加进历史（遗留项 6）。
  String _lastUserFileText = '';
  bool _userStopped = false;
  bool _disposed = false;

  late AISettings _currentSettings;
  List<String> _pendingImages = [];
  List<String> _pendingFiles = [];

  /// 会话绑定的助手（阶段七）。null = 未绑定 / 已被删除（自然回落无助手）。
  AssistantModel? _assistant;

  /// 构建当前 completionDao 时所用的助手，用于「切换助手后重建 Dao」的判断。
  AssistantModel? _daoAssistant;
  String? _daoModelProviderId;
  String? _daoModelId;
  AssistantDao? _assistantDao;

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
    final all =
        await McpToolSource.discover(settings, confirm: _confirmToolAction);
    final assistant = _assistant;
    if (assistant == null) return all;
    final bound = {...?assistant.toolIds};
    return all.where((t) => bound.contains(t.name)).toList();
  }

  List<String>? get _effectiveToolIds =>
      widget.conversationModel.toolIds ?? _assistant?.toolIds;

  /// 块上记录的 modelId（覆盖后实际生效的模型）。
  String get _effectiveModelId => _effective(_currentSettings).effectiveModel;

  get _chatList => Expanded(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 10, right: 10),
              child: ChatList(
                chatController: chatController,
                onBubbleLongPress: _onBubbleLongPress,
              ),
            ),
            // 置顶/置底悬浮按钮：叠在对话区右下角，不占输入框空间。
            Positioned(right: 12, bottom: 12, child: _scrollJumpButtons()),
          ],
        ),
      );

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
            padding: const EdgeInsets.all(9),
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
        title: Text(_title),
        actions: [
          // 对话目录：列出本会话的全部提问，点选跳转到该条。
          IconButton(
            icon: const Icon(Icons.format_list_bulleted),
            tooltip: '对话目录',
            onPressed: _openOutline,
          ),
          // 会话内切换助手（阶段七）。
          IconButton(
            icon: const Icon(Icons.support_agent),
            tooltip: '切换助手',
            onPressed: _switchAssistant,
          ),
        ],
      );

  String _aiName = '';

  String get _title {
    if (_isStreaming) return '对方正在输入...';
    if (_aiName.isNotEmpty) return '与$_aiName的会话';
    return 'ChatGPT';
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
      onStop: _isStreaming ? _stopStream : null,
      onChanged: (text) => _inputMessage = text,
      onSend: () => _onSend(_inputMessage),
      // 联网搜索开关（阶段五）：当前所选服务商配置了 key 才展示；独立于
      // caps.tool，搜索结果以上下文回填，任何模型都可用（与 Cherry 一致）。
      showWebSearch: settings.webSearchConfigured,
      webSearchEnabled: settings.webSearchEnabled,
      onToggleWebSearch: _toggleWebSearch,
      modelLabel: _modelLabel(settings),
      onModelTap: _switchModel,
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
    if (!_blockStore.hasBlocks(key)) return null;
    // 仅 assistant 回复显示生成字数（流式中实时累加）。
    return BlockMessageContent(
      messageKey: key,
      showCharCount: message.ownerType == OwnerType.receiver,
    );
  }

  ///不用_inputMessage是因为在结果回来之前_inputMessage可能会变
  void _onSend(final String inputMessage) async {
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
    final modelChanged =
        _daoModelProviderId != widget.conversationModel.modelProviderId ||
            _daoModelId != widget.conversationModel.modelId;
    if (rawSettings != _currentSettings ||
        !identical(_assistant, _daoAssistant) ||
        modelChanged) {
      _currentSettings = rawSettings;
      _daoAssistant = _assistant;
      _daoModelProviderId = widget.conversationModel.modelProviderId;
      _daoModelId = widget.conversationModel.modelId;
      completionDao = CompletionDao(
          settings: _effective(rawSettings),
          systemPrompt: _assistant?.prompt,
          messages: completionDao.currentMessages,
          toolHistory: completionDao.currentToolHistory,
          fileHistory: completionDao.currentFileHistory);
    }
    final settings = _effective(rawSettings);
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
    // 附件降级文本随本轮用户消息记入历史（遗留项 6：后续轮从 _fileHistory 重建）。
    _lastUserFileText = processed.extraText;
    if (processed.metas.isNotEmpty) {
      // 带文件的用户消息：建 FileBlock/ImageBlock（块化展示 + 随消息落库）。
      _addUserMessageWithBlocks(userModel, pendingPaths, processed.metas);
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
  void _addUserMessageWithBlocks(MessageModel userModel,
      List<String>? imagePaths, List<FileMetadata> metas) {
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
    try {
      final result = await completionDao.createCompletionsWithSearch(
          prompt: inputMessage,
          attachments: attachments.isEmpty ? null : attachments,
          webSearch: webSearch);
      response = result.content;
      webResults = result.webResults;
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
    final blocks = _finalizeBlocksForPersist(_blockStore.blocksFor(messageKey));
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
    }
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
      avatar = '';
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
    var dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    conversationListDao = await ConversationListDao.create(dbManager);
    messageDao =
        await MessageDao.create(dbManager, cid: widget.conversationModel.cid);
    favoriteDao = await FavoriteDao.create(dbManager);
    // 阶段七：加载会话绑定的助手（先于 CompletionDao 构造，使首轮即带
    // 系统提示词与模型覆盖）。助手已删除时回落 null。
    _assistantDao = await AssistantDao.create(dbManager);
    final aid = widget.conversationModel.assistantId;
    if (aid != null) {
      _assistant = await _assistantDao!.getAssistant(aid);
    }
    var list = await _loadData();
    chatController.loadMoreData(list);
    // 首帧布局完成后算一次按钮可见性（打开长会话时立即出现「回到顶部」）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPositionsChanged());
    _daoAssistant = _assistant;
    _daoModelProviderId = widget.conversationModel.modelProviderId;
    _daoModelId = widget.conversationModel.modelId;
    // 从持久化块恢复工具调用历史（遗留项 2）+ 附件文本历史（遗留项 6），
    // 使重开会话后工具调用与文件上下文仍跨轮可见。
    final blockHistory = await _loadBlockHistory(list);
    completionDao = CompletionDao(
        settings: _effective(settings),
        systemPrompt: _assistant?.prompt,
        messages: list,
        toolHistory: blockHistory.$1,
        fileHistory: blockHistory.$2);
    // 刷新标题/能力位（助手是异步加载的，首帧可能还没就位）。
    setState(() {});
  }

  /// 会话内切换助手（阶段七）：弹选择器，更新绑定并在下次发送时生效
  /// （_onSend 检测到助手变化会重建 CompletionDao）。绑定随会话模型
  /// 在返回列表页时一起落库（见 ConversationListPage._doUpdate）。
  void _switchAssistant() async {
    final pick = await showAssistantPicker(context,
        selectedId: widget.conversationModel.assistantId);
    if (pick == null || !mounted) return; // 取消
    setState(() {
      _assistant = pick.assistant;
      widget.conversationModel.assistantId = pick.assistant?.id;
    });
    widget.conversationModel.hadChanged = true;
    HiDialog.showSnackBar(context,
        pick.assistant == null ? '已取消助手绑定' : '已切换助手：${pick.assistant!.name}');
  }

  void _switchModel() async {
    final rawSettings = context.read<AISettingsProvider>().settings;
    final picked = rawSettings.mode == AIMode.backend
        ? await _pickBackendModel(rawSettings)
        : await _pickLocalModel(rawSettings);
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

  void _recordConversationModelTestResult(
    String providerId,
    String modelId, {
    required bool success,
    String? error,
  }) {
    final store = context.read<AISettingsProvider>();
    final providers = store.settings.providers.where((p) => p.id == providerId);
    if (providers.isEmpty) return;
    final provider = providers.first;
    final models = provider.models.where((m) => m.id == modelId);
    if (models.isEmpty) return;
    models.first.markTestResult(success: success, error: error);
    if (success) {
      final caps = ModelCapabilities.heuristic(models.first.id,
          providerCode: provider.providerCode);
      models.first.applyCapabilityHints(
        vision: caps.image,
        tool: caps.tool,
        reasoning: caps.reasoning,
      );
    }
    store.updateProvider(provider);
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

  String _modelTestTimeLabel(int? millis) {
    if (millis == null || millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<({String? providerId, String? modelId})?> _pickLocalModel(
      AISettings settings) async {
    final currentProviderId =
        widget.conversationModel.modelProviderId ?? settings.activeProvider.id;
    final currentModelId =
        widget.conversationModel.modelId ?? _effective(settings).effectiveModel;
    final testStates = <String, _ConversationModelTestState>{};
    final testErrors = <String, String>{};
    final searchController = TextEditingController();
    var filter = _ModelFilter.all;
    final picked =
        await showModalBottomSheet<({String? providerId, String? modelId})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cs = Theme.of(ctx).colorScheme;
          final tt = Theme.of(ctx).textTheme;
          final query = searchController.text.trim().toLowerCase();
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.72),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: '搜索模型或服务商',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setSheetState(() {}),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _modelFilterChip(ctx, '全部', _ModelFilter.all, filter,
                            (v) => setSheetState(() => filter = v)),
                        _modelFilterChip(ctx, '可用', _ModelFilter.available,
                            filter, (v) => setSheetState(() => filter = v)),
                        _modelFilterChip(ctx, '图片', _ModelFilter.image, filter,
                            (v) => setSheetState(() => filter = v)),
                        _modelFilterChip(ctx, '工具', _ModelFilter.tool, filter,
                            (v) => setSheetState(() => filter = v)),
                        _modelFilterChip(ctx, '推理', _ModelFilter.reasoning,
                            filter, (v) => setSheetState(() => filter = v)),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.public),
                    title: const Text('跟随全局设置'),
                    subtitle: Text(settings.effectiveModel),
                    trailing: widget.conversationModel.modelId == null
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () =>
                        Navigator.pop(ctx, (providerId: null, modelId: null)),
                  ),
                  const Divider(height: 1),
                  for (final provider in settings.enabledProviders)
                    if (_visibleModels(provider, query, filter).isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                        child: Text(provider.name, style: tt.labelLarge),
                      ),
                      for (final model
                          in _visibleModels(provider, query, filter))
                        _modelPickTile(
                          ctx,
                          cs,
                          tt,
                          provider: provider,
                          model: model,
                          selected: currentProviderId == provider.id &&
                              currentModelId == model.id,
                          stateKey: '${provider.id}:${model.id}',
                          testStates: testStates,
                          testErrors: testErrors,
                          setSheetState: setSheetState,
                          settings: settings,
                        ),
                    ],
                  if (settings.enabledProviders
                      .every((p) => _visibleModels(p, query, filter).isEmpty))
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text('没有匹配的模型',
                            style: tt.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    searchController.dispose();
    return picked;
  }

  Widget _modelFilterChip(
    BuildContext context,
    String label,
    _ModelFilter value,
    _ModelFilter selected,
    ValueChanged<_ModelFilter> onSelected,
  ) =>
      FilterChip(
        label: Text(label),
        selected: selected == value,
        onSelected: (_) => onSelected(value),
        visualDensity: VisualDensity.compact,
      );

  List<AiModel> _visibleModels(
      AiProvider provider, String query, _ModelFilter filter) {
    final models = [
      for (final model in provider.models)
        if (_modelMatches(provider, model, query, filter)) model,
    ];
    models.sort((a, b) => (b.lastUsedAt ?? 0).compareTo(a.lastUsedAt ?? 0));
    return models;
  }

  bool _modelMatches(
      AiProvider provider, AiModel model, String query, _ModelFilter filter) {
    if (query.isNotEmpty) {
      final text = '${provider.name} ${provider.id} ${model.name} ${model.id}'
          .toLowerCase();
      if (!text.contains(query)) return false;
    }
    final caps = _modelCaps(provider, model);
    return switch (filter) {
      _ModelFilter.all => true,
      _ModelFilter.available => model.lastTestStatus == 'success',
      _ModelFilter.image => caps.image,
      _ModelFilter.tool => caps.tool,
      _ModelFilter.reasoning => caps.reasoning,
    };
  }

  ModelCapabilities _modelCaps(AiProvider provider, AiModel model) {
    final base = ModelCapabilities.heuristic(model.id,
        providerCode: provider.providerCode);
    return base.copyWith(
      image: base.image || model.vision,
      tool: base.tool || model.tool,
      reasoning: base.reasoning || model.reasoning,
    );
  }

  Widget _modelPickTile(
    BuildContext ctx,
    ColorScheme cs,
    TextTheme tt, {
    required AiProvider provider,
    required AiModel model,
    required bool selected,
    required String stateKey,
    required Map<String, _ConversationModelTestState> testStates,
    required Map<String, String> testErrors,
    required StateSetter setSheetState,
    required AISettings settings,
  }) {
    final persistedState = switch (model.lastTestStatus) {
      'success' => _ConversationModelTestState.success,
      'failure' => _ConversationModelTestState.failure,
      _ => _ConversationModelTestState.idle,
    };
    final state = testStates[stateKey] ?? persistedState;
    final error = testErrors[stateKey] ?? model.lastTestError;
    final testTime = _modelTestTimeLabel(model.lastTestAt);
    final usedTime = _modelTestTimeLabel(model.lastUsedAt);
    final caps = _modelCaps(provider, model);
    return ListTile(
      dense: true,
      title: Text(model.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.id != model.name) Text(model.id),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              if (caps.image) _miniModelChip(cs, '图片'),
              if (caps.tool) _miniModelChip(cs, '工具'),
              if (caps.reasoning) _miniModelChip(cs, '推理'),
              if (caps.pdf) _miniModelChip(cs, 'PDF'),
            ],
          ),
          if (state == _ConversationModelTestState.success)
            Text('可用', style: tt.bodySmall?.copyWith(color: cs.primary)),
          if (state == _ConversationModelTestState.failure && error != null)
            Text(
              '不可用：$error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.error),
            ),
          if (testTime.isNotEmpty)
            Text('上次测试：$testTime',
                style: tt.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
          if (usedTime.isNotEmpty)
            Text('最近使用：$usedTime',
                style: tt.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant, fontSize: 11)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) const Icon(Icons.check),
          IconButton(
            tooltip: '测试模型',
            icon: state == _ConversationModelTestState.running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check_rounded),
            onPressed: state == _ConversationModelTestState.running
                ? null
                : () async {
                    setSheetState(() {
                      testStates[stateKey] =
                          _ConversationModelTestState.running;
                      testErrors.remove(stateKey);
                    });
                    try {
                      await _testConversationModel(settings,
                          providerId: provider.id, modelId: model.id);
                      if (!ctx.mounted) return;
                      _recordConversationModelTestResult(provider.id, model.id,
                          success: true);
                      setSheetState(() {
                        testStates[stateKey] =
                            _ConversationModelTestState.success;
                      });
                    } catch (e) {
                      if (!ctx.mounted) return;
                      _recordConversationModelTestResult(provider.id, model.id,
                          success: false, error: '$e');
                      setSheetState(() {
                        testStates[stateKey] =
                            _ConversationModelTestState.failure;
                        testErrors[stateKey] = '$e';
                      });
                    }
                  },
          ),
        ],
      ),
      onTap: () =>
          Navigator.pop(ctx, (providerId: provider.id, modelId: model.id)),
    );
  }

  Widget _miniModelChip(ColorScheme cs, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, height: 1, color: cs.onSecondaryContainer)),
      );

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
    var list = await messageDao.getMessages(pageIndex: pageIndex);
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
  Future<(Map<int, List<ToolBlock>>, Map<int, String>)> _loadBlockHistory(
      List<MessageModel> list) async {
    if (list.isEmpty) return (<int, List<ToolBlock>>{}, <int, String>{});
    final blocksMap =
        await messageDao.getBlocksByCreatedAt(list.map((m) => m.createdAt));
    if (blocksMap.isEmpty) return (<int, List<ToolBlock>>{}, <int, String>{});
    final tools = <int, List<ToolBlock>>{};
    final files = <int, String>{};
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
    }
    return (tools, files);
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
    if (chatController.initialMessageList.isNotEmpty) {
      var model = chatController.initialMessageList.first;
      widget.conversationModel.lastMessage = model.content;
      widget.conversationModel.updateAt = model.createdAt;
      widget.conversationModel.title ??=
          chatController.initialMessageList.last.content;
    }
  }

  /// 是否可对该消息「重新生成」：必须是 assistant 回复、当前无流式进行、
  /// 且为会话最新一条（仅支持重生成最后一次回复，保证历史回退正确）。
  bool _canRegenerate(MessageModel message) {
    if (message.ownerType != OwnerType.receiver || _isStreaming) return false;
    final list = chatController.initialMessageList;
    return list.isNotEmpty && list.first.createdAt == message.createdAt;
  }

  void _onBubbleLongPress(MessageModel message, BuildContext ancestor) {
    bool left = message.ownerType == OwnerType.receiver ? true : false;
    double offsetX = left ? -100 : 50;
    HiDialog.showPopMenu(ancestor, offsetX: offsetX, items: [
      if (_canRegenerate(message))
        PopupMenuItem(
          child: const Text('重新生成'),
          onTap: () {
            _regenerate(message);
          },
        ),
      PopupMenuItem(
        child: const Text('设为精彩'),
        onTap: () {
          _addFavorite(message);
        },
      ),
      PopupMenuItem(
        child: const Text('复制'),
        onTap: () {
          _copyMessage(message);
        },
      ),
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

  void _addFavorite(MessageModel message) async {
    var result = await favoriteDao.addFavorite(FavoriteModel(
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
      var result = message.id != null
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
