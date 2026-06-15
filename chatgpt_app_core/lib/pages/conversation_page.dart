import 'dart:async';

import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

typedef OnConversationUpdate = void Function(
    ConversationModel conversationModel);

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
  late ChatController chatController;
  late CompletionDao completionDao;
  final ScrollController _scrollController = ScrollController();

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
  AssistantDao? _assistantDao;

  /// 应用助手的模型覆盖后的设置 —— 能力位与请求构造都用它，
  /// 保证「助手指定了模型时，capabilitiesFor 用覆盖后的模型算」。
  AISettings _effective(AISettings s) => _assistant?.applyTo(s) ?? s;

  /// 块上记录的 modelId（覆盖后实际生效的模型）。
  String get _effectiveModelId => _effective(_currentSettings).effectiveModel;

  get _chatList => Expanded(
          child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 10),
        child: ChatList(
          chatController: chatController,
          onBubbleLongPress: _onBubbleLongPress,
        ),
      ));

  get _appBar => AppBar(
        title: Text(_title),
        actions: [
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
      pendingImages: _pendingImages,
      imagesEnabled: caps.image,
      imagesDisabledReason: caps.image
          ? ''
          : '当前模型不支持图片，请切换 gpt-4o 等多模态模型',
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

  /// 切换联网搜索开关（持久化到 AI 设置，所有会话共享，与 Cherry 一致）。
  void _toggleWebSearch() {
    final provider = context.read<AISettingsProvider>();
    final next = provider.settings.clone()
      ..webSearchEnabled = !provider.settings.webSearchEnabled;
    provider.update(next);
    HiDialog.showSnackBar(
        context, next.webSearchEnabled ? '已开启联网搜索' : '已关闭联网搜索');
  }

  /// 气泡内部内容构造器（注入给 chat_message 包）：
  /// 已有块的消息 -> 块化渲染（assistant 的流式块、用户的文件/图片块），
  /// 其余（纯文本/纯图片用户消息、旧的无块消息）-> 回退默认渲染。
  Widget? _buildBlockContent(BuildContext context, MessageModel message) {
    final key = chatMessageKey(message.createdAt);
    if (!_blockStore.hasBlocks(key)) return null;
    return BlockMessageContent(messageKey: key);
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
    if (rawSettings != _currentSettings || !identical(_assistant, _daoAssistant)) {
      _currentSettings = rawSettings;
      _daoAssistant = _assistant;
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
    final registry = ToolRegistry.fromAssistant(settings, _assistant?.toolIds,
        forceWebSearch: webSearch,
        actions: ToolActionContext.forCurrentAccount(confirm: _confirmToolAction));
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

  Future<void> _onSendNonStream(String inputMessage, ChatAttachments attachments,
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
    final dispatcher = StreamDispatcher(_blockStore, messageKey,
        modelId: _effectiveModelId)
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
        scrollController: _scrollController,
        timePellet: 60,
        messageContentBuilder: _buildBlockContent);
    //下拉触发加载更多
    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
          _scrollController.position.maxScrollExtent) {
        _loadData(loadMore: true);
      }
    });
    final settings = context.read<AISettingsProvider>().settings;
    _currentSettings = settings;
    _aiName = settings.aiDisplayName;
    var dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    messageDao = await MessageDao.create(dbManager, cid: widget.conversationModel.cid);
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
    _daoAssistant = _assistant;
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
    HiDialog.showSnackBar(
        context,
        pick.assistant == null
            ? '已取消助手绑定'
            : '已切换助手：${pick.assistant!.name}');
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

  void _onBubbleLongPress(MessageModel message, BuildContext ancestor) {
    bool left = message.ownerType == OwnerType.receiver ? true : false;
    double offsetX = left ? -100 : 50;
    HiDialog.showPopMenu(ancestor, offsetX: offsetX, items: [
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
        onTap: () {
          //todo
        },
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

  _deleteMessage(MessageModel message) async {
    try {
      var result = await messageDao.deleteMessage(message.id!);
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
