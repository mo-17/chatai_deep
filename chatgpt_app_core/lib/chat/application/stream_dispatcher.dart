import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';

/// 流式分发器。对应源项目 `BlockManager` + 各 `*Callbacks`。
///
/// 核心规则（忠实于源项目）：
/// - 流式一开始先建一个「占位块(unknown)」；
/// - 首个事件到达时，如果占位块还在，就把它「变身」成对应类型；
///   否则新建一个块并 attach；
/// - 块类型切换时（如从 thinking 切到 mainText），上一个块标记完成；
/// - 思考块自带计时：首个 thinking chunk 记 startMs，每次 chunk 用
///   now-start 刷新 thinkingMillsec，complete 时落最终值。
///
/// 一个 [StreamDispatcher] 对应「一条 assistant 消息」的整段流式过程。
class StreamDispatcher {
  final ChatBlockStore store;

  /// 该消息在 [ChatBlockStore] 里的稳定 key。
  final String messageKey;

  /// 当前消息的模型 id（落到块上，便于多模型混排时区分来源）。
  final String? modelId;

  String? _placeholderId;
  String? _mainTextId;
  String? _thinkingId;
  String? _citationId;
  int _thinkingStartMs = 0;
  int _seq = 0;
  bool _hasError = false;

  StreamDispatcher(this.store, this.messageKey, {this.modelId});

  bool get hasError => _hasError;

  /// 主文本全文（用于落库 content + 历史上下文；不含思考内容）。
  /// 聚合该消息的所有 mainText 块 —— 交错流（think→text→think→text）会产生
  /// 多个正文块，按到达顺序拼接；与 _mainTextId 是否已收尾无关。
  String get mainText {
    final buf = StringBuffer();
    for (final b in store.blocksFor(messageKey)) {
      if (b is MainTextBlock) buf.write(b.content);
    }
    return buf.toString();
  }

  String _newId(String kind) => 'blk_${messageKey}_${kind}_${_seq++}';

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 流式开始：建占位块。
  void start() {
    final id = _newId('ph');
    _placeholderId = id;
    store.upsertBlock(PlaceholderBlock(
      id: id,
      messageId: messageKey,
      createdAt: _now(),
      status: MessageBlockStatus.processing,
    ));
    store.attachBlockToMessage(messageKey, id);
  }

  // ---- 思考 / 推理 ----

  void onThinkingChunk(String text) {
    if (text.isEmpty) return;
    // 块类型切换：思考（再次）开始 => 上一个正文块标记完成。
    // 与 onTextChunk 对称，支持 think→text→think→text 交错流按到达顺序成块。
    if (_mainTextId != null) onTextComplete();
    if (_thinkingId == null) {
      _thinkingStartMs = _now();
      _thinkingId = _morphOrCreate(
        kind: 'think',
        build: (id) => ThinkingBlock(
          id: id,
          messageId: messageKey,
          createdAt: _now(),
          status: MessageBlockStatus.streaming,
          modelId: modelId,
        ),
      );
    }
    final b = store.block(_thinkingId!) as ThinkingBlock;
    store.upsertBlock(b.copyWith(
      content: b.content + text,
      thinkingMillsec: _now() - _thinkingStartMs,
      status: MessageBlockStatus.streaming,
      updatedAt: _now(),
    ));
  }

  void onThinkingComplete() {
    final id = _thinkingId;
    if (id == null) return;
    final b = store.block(id);
    if (b is ThinkingBlock) {
      store.upsertBlock(b.copyWith(
        thinkingMillsec: _now() - _thinkingStartMs,
        status: MessageBlockStatus.success,
        updatedAt: _now(),
      ));
    }
    _thinkingId = null; // 块结束，下一种块会新建
  }

  // ---- 正文 ----

  void onTextChunk(String text) {
    if (text.isEmpty) return;
    // 块类型切换：正文开始 => 上一个思考块标记完成。
    if (_thinkingId != null) onThinkingComplete();
    _mainTextId ??= _morphOrCreate(
      kind: 'text',
      build: (id) => MainTextBlock(
        id: id,
        messageId: messageKey,
        createdAt: _now(),
        status: MessageBlockStatus.streaming,
        modelId: modelId,
      ),
    );
    final b = store.block(_mainTextId!) as MainTextBlock;
    store.upsertBlock(b.copyWith(
      content: b.content + text,
      status: MessageBlockStatus.streaming,
      updatedAt: _now(),
    ));
  }

  void onTextComplete() {
    final id = _mainTextId;
    if (id == null) return;
    final b = store.block(id);
    if (b is MainTextBlock) {
      store.upsertBlock(
          b.copyWith(status: MessageBlockStatus.success, updatedAt: _now()));
    }
    _mainTextId = null; // 块结束，下一段正文会新建（交错流时）
  }

  // ---- 图片（阶段四：模型生成图片） ----

  /// 图片事件到达即完整（无增量）：占位块变身或新建一个 success 态 ImageBlock。
  /// 不收尾正在流式的正文/思考块 —— 图片块按到达顺序插入，正文可继续。
  void onImage(String url) {
    if (url.isEmpty) return;
    _morphOrCreate(
      kind: 'img',
      build: (id) => ImageBlock(
        id: id,
        messageId: messageKey,
        createdAt: _now(),
        status: MessageBlockStatus.success,
        modelId: modelId,
        url: url,
      ),
    );
  }

  // ---- 引用来源（阶段五：联网搜索） ----

  /// 引用事件到达即完整（无增量）：占位块变身或新建一个 success 态 CitationBlock。
  /// 编排器在流式正文结束后才发该事件，因此块自然落在消息底部。
  void onCitation(List<WebSearchResult> results,
      {List<LocalSourceCitation> localSources = const []}) {
    if (results.isEmpty && localSources.isEmpty) return;
    final existing = _citationId == null ? null : store.block(_citationId!);
    final web = <String, WebSearchResult>{
      if (existing is CitationBlock)
        for (final result in existing.webResults) result.url: result,
      for (final result in results) result.url: result,
    };
    // 按 sourceId 保留重映射后的别名；正文中旧标记仍能打开同一个来源。
    final local = <String, LocalSourceCitation>{
      if (existing is CitationBlock)
        for (final source in existing.localSources) source.sourceId: source,
      for (final source in localSources) source.sourceId: source,
    };
    CitationBlock build(String id) => CitationBlock(
          id: id,
          messageId: messageKey,
          createdAt: existing?.createdAt ?? _now(),
          updatedAt: _now(),
          status: MessageBlockStatus.success,
          modelId: modelId,
          webResults: web.values.toList(),
          localSources: local.values.toList(),
        );
    if (_citationId != null) {
      store.upsertBlock(build(_citationId!));
      return;
    }
    _citationId = _morphOrCreate(
      kind: 'cite',
      build: build,
    );
  }

  // ---- 工具调用（阶段六） ----

  /// 工具调用到达：收尾当前思考/正文块（后续正文另起新块，保证
  /// text→tool→text 按到达顺序排布），建 processing 态 ToolBlock。
  void onToolCall({
    required String toolId,
    String? name,
    Map<String, dynamic>? args,
  }) {
    if (_thinkingId != null) onThinkingComplete();
    if (_mainTextId != null) onTextComplete();
    _morphOrCreate(
      kind: 'tool',
      build: (id) => ToolBlock(
        id: id,
        messageId: messageKey,
        createdAt: _now(),
        status: MessageBlockStatus.processing,
        modelId: modelId,
        toolId: toolId,
        toolName: name,
        arguments: args,
      ),
    );
  }

  /// 工具结果到达：按 toolId 找到对应 ToolBlock，填结果并置 success。
  void onToolResult({required String toolId, Object? content}) {
    for (final b in store.blocksFor(messageKey)) {
      if (b is ToolBlock && b.toolId == toolId) {
        store.upsertBlock(b.copyWith(
          status: MessageBlockStatus.success,
          content: content,
        ));
        return;
      }
    }
  }

  // ---- 错误 / 停止 ----

  /// 流式出错：当前活跃块标记 error，并追加一个独立的 error 块。
  void onError(String message) {
    _hasError = true;
    _markActivePaused(MessageBlockStatus.error);
    // 占位块还在（一个字都没收到就报错）：直接把它变成 error 块。
    final id = _placeholderId ?? _newId('err');
    _placeholderId = null;
    store.upsertBlock(ErrorBlock(
      id: id,
      messageId: messageKey,
      createdAt: _now(),
      status: MessageBlockStatus.error,
      modelId: modelId,
      message: message,
    ));
    store.attachBlockToMessage(messageKey, id);
  }

  /// 用户主动停止：把当前未完成的块标记为 paused。
  void onStopped() {
    _markActivePaused(MessageBlockStatus.paused);
    _cleanupPlaceholder();
  }

  /// 流式正常结束：收尾思考块与正文块。
  void finish() {
    onThinkingComplete();
    onTextComplete();
    _cleanupPlaceholder();
  }

  /// 把当前活跃的 thinking / mainText 块改成给定的终止状态。
  void _markActivePaused(MessageBlockStatus status) {
    final tId = _thinkingId;
    if (tId != null) {
      final b = store.block(tId);
      if (b is ThinkingBlock && b.isActive) {
        store.upsertBlock(b.copyWith(
          thinkingMillsec: _now() - _thinkingStartMs,
          status: status,
          updatedAt: _now(),
        ));
      }
      _thinkingId = null;
    }
    final mId = _mainTextId;
    if (mId != null) {
      final b = store.block(mId);
      if (b is MainTextBlock && b.isActive) {
        store.upsertBlock(b.copyWith(status: status, updatedAt: _now()));
      }
    }
  }

  /// 占位块从未变身（没收到任何内容也没报错）：直接移除它。
  /// 移除后该消息块列表为空 -> hasBlocks 回到 false -> 回退平铺渲染，
  /// 由 _persistAssistant 写入「no response」兜底文案，而不是留一个空白气泡。
  void _cleanupPlaceholder() {
    final id = _placeholderId;
    if (id == null) return;
    final b = store.block(id);
    if (b is PlaceholderBlock) {
      store.removeBlock(messageKey, id);
    }
    _placeholderId = null;
  }

  /// 若占位块还在则复用其 id（变身），否则新建并挂到消息上。
  String _morphOrCreate({
    required String kind,
    required MessageBlock Function(String id) build,
  }) {
    final reuse = _placeholderId;
    if (reuse != null) {
      _placeholderId = null;
      store.upsertBlock(build(reuse)); // 同 id 覆盖占位块 => 变身
      return reuse; // 已经 attach 过，无需重复
    }
    final id = _newId(kind);
    store.upsertBlock(build(id));
    store.attachBlockToMessage(messageKey, id);
    return id;
  }
}
