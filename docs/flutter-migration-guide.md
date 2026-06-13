# Cherry Studio → Flutter 功能迁移规格（可执行）

> 本文件是写给 **Flutter 项目的 AI 编码会话** 的执行规格 + 提示词。
> 源项目：Cherry Studio App（React Native / Expo / Redux Toolkit / Drizzle ORM / SQLite）。
> 目标项目：一个目前只有「普通流式对话」的 Flutter App。
> 目标技术栈建议：**Flutter 3.x + Riverpod（状态管理）+ Drift 或 sqflite（持久化）+ dio（网络/SSE）**。

---

## ⏱️ 进度总览（2026-06-12 更新）

> 本节由实施会话维护，记录每个阶段的真实落地情况。**全部八个阶段已完成**，后续只剩遗留项（见 next-session-prompt.md §6）。
> 续作提示词见 [`docs/next-session-prompt.md`](./next-session-prompt.md)。

| 阶段 | 状态 | 落地说明 |
|---|---|---|
| 阶段一 · 块化消息系统 | ✅ **已完成** | 见 §2 文末「✅ 实施记录」。块模型 / 规范化仓库 / 流式分发器 / 按块渲染 / 持久化全部落地，28 个测试通过。 |
| 阶段二 · 思考/推理展示 | ✅ **已完成** | 见 §3 文末「✅ 实施记录」。可折叠思考块 + 实时计时；正文与思考从 SSE 源头分流。 |
| 阶段三 · 多 Provider 抽象 + 能力探测 | ✅ **已完成** | 见 §4 文末「✅ 实施记录」。`ModelCapabilities` + 统一 `ModelCatalog.capabilitiesFor` 单一来源；`ChatService.capabilities` 暴露；UI 的 `_checkVision` 点状判断替换为统一 `_capabilities`，43 个测试通过。 |
| 阶段四 · 文件解析 + 图片多模态 | ✅ **已完成** | 见 §5 文末「✅ 实施记录」。`FileProcessor`（原生喂 / 降级抽文本）+ `ChatAttachments`（当前轮多模态 content）+ 文件入口 UI + 用户消息 FileBlock/ImageBlock + `StreamDispatcher.onImage`；阶段三复审遗留 1/2 一并修复，61 个测试通过。 |
| 阶段五 · 智能联网搜索 | ✅ **已完成** | 见 §6 文末「✅ 实施记录」。`SearchOrchestrator`（意图识别 JSON + fallback）+ `WebSearchProvider`/Tavily + 并行聚合去重 + extraText 回填 + `StreamEvent.citation`→`CitationBlock` 可点来源 + 会话页联网开关，83 个测试通过。 |
| 阶段六 · 工具调用 | ✅ **已完成** | 见 §7 文末「✅ 实施记录」。SSE `tool_calls` 分片累积 + `ToolRegistry`（联网搜索为首个工具）+ `ToolLoopRunner` 调用→执行→回灌→续写（上限 5 轮）+ 可折叠 ToolBlock；按 `caps.tool` 与阶段五意图编排互斥选路，99 个测试通过。 |
| 阶段七 · 助手系统 | ✅ **已完成** | 见 §8 文末「✅ 实施记录」。`AssistantModel`（系统提示词 + 模型覆盖 + 工具开关）+ `AssistantDao`/`tb_assistant` + 会话绑定（`tb_conversation_list.assistantId` 列 ALTER 升级）+ system 注入（意图识别不带）+ 覆盖后能力位联动 + 管理/选择 UI，112 个测试通过。 |
| 阶段八 · 备份恢复 | ✅ **已完成** | 见 §8 文末「✅ 实施记录 · 阶段八」。`BackupService`（zip：manifest + 每表 JSON + settings；覆盖式恢复 + 外键修复 + API key 默认脱敏）+ 备份恢复页 + restoreTick 页面刷新，118 个测试通过。 |

**⚠️ 与指南的关键偏差（务必沿用）**：本仓库 CLAUDE.md 强制 `provider` + sqflite + `http`，**不引入 Riverpod / Drift / dio**。
指南里的 Riverpod `Notifier` → 用 `ChangeNotifier`（`ChatBlockStore`）；Drift → sqflite（`tb_messages.blocks` 列）；dio SSE → 现有 `http` 流式。
块模型、流式分发、类型化事件、按块渲染等**架构精髓全部忠实保留**。

**阶段一/二 新增的关键文件**（位于分支 `worktree-block-message-system`，**尚未合并 main**）：
- `chatgpt_app_core/lib/chat/domain/message_block.dart` — sealed 块层级 + JSON 往返
- `chatgpt_app_core/lib/chat/domain/stream_event.dart` — 类型化流事件（text/reasoning/toolCall…）
- `chatgpt_app_core/lib/chat/application/chat_block_store.dart` — 规范化块仓库（ChangeNotifier）
- `chatgpt_app_core/lib/chat/application/stream_dispatcher.dart` — 占位块变身/块切换收尾/思考计时
- `chatgpt_app_core/lib/chat/ui/block_message_content.dart` — 按块分发渲染（Selector 精确订阅）
- `chatgpt_app_core/lib/chat/ui/thinking_block_view.dart` — 可折叠思考块 + 实时计时
- 改造：`dao/chat/*`、`dao/completion_dao.dart`、`db/message_dao.dart`、`pages/conversation_page.dart`、`widget/message_input_widget.dart`、`openai_flutter/lib/http/ai_http.dart`、`openai_flutter/lib/core/ai_completions.dart`、`chat_message/lib/...`

---

## 0. 给 Flutter 会话的执行提示词（直接照此工作）

```
你正在把一个 React Native AI 客户端（Cherry Studio）的核心能力迁移到一个 Flutter App。
该 Flutter App 当前只有"普通流式对话"（一条消息 = 一段纯文本流）。

请严格按本文件的"阶段"顺序实施，一次只做一个阶段，每个阶段做完：
1) 自检：跑通编译 + 该阶段的"验收标准"全部满足；
2) 用一句话报告本阶段产出与下一步。

最重要的约束：
- 阶段一（块化消息系统）是所有后续功能的地基，必须先做、做扎实。
- 不要把消息当成一段纯文本。一条 assistant 消息是"有序的块(Block)列表"，
  块类型包括：主文本/思考/代码/图片/工具调用/引用/文件/错误。
- 状态管理用 Riverpod；消息与块"规范化存储"（见 §2.1）。
- 沿用源项目的"流式回调分发 + 活跃块 + 节流更新"模型（见 §2.4 / §2.5）。
- 多模型差异通过"能力探测(capabilities)"抽象，不要写死单一 provider（见 §4）。

如果某个阶段需要源项目的真实实现细节，去读对应的"源文件对照表"里列出的文件。
```

---

## 1. 源项目能力地图 & 迁移优先级

| 优先级 | 能力 | 价值 | 工作量 | 阶段 |
|---|---|---|---|---|
| 🟢 P0 | **块化消息系统**（地基） | 极高 | 中 | 阶段一 ✅ |
| 🟢 P0 | 思考/推理过程展示 + 耗时 | 高 | 低 | 阶段二 ✅ |
| 🟢 P0 | 多 Provider 抽象 + 能力探测 | 高 | 中 | 阶段三 ✅ |
| 🟡 P1 | 文件解析 + 图片多模态 | 高 | 中 | 阶段四 ⬅️ 下一步 |
| 🟡 P1 | 智能联网搜索（意图编排 + 多 Provider） | 高 | 中高 | 阶段五 |
| 🟡 P1 | 工具调用（Tool Calling） | 中高 | 中 | 阶段六 |
| 🟠 P2 | 助手系统（Assistants / 提示词 / 绑定模型） | 中 | 中 | 阶段七 |
| 🟠 P2 | 数据备份/恢复（zip 导出导入） | 中 | 低 | 阶段八 |
| 🔵 P3 | 知识库 / RAG（embedding + 向量检索） | 高 | 高 | 远期 |
| ⚫ 不建议 | MCP 协议、局域网 P2P 传输、模型健康检查 | 低（移动端） | 高 | — |

**落地路线**：阶段一 → 二 → 三 是地基，做完 App 就从「聊天框」变成「AI 客户端」。

---

## 2. 阶段一：块化消息系统（核心地基）

### 2.1 设计原则（忠实于源项目）

源项目 `src/types/message.ts` 的关键设计：

1. **规范化存储**：`Message` 不直接持有块对象，而是持有 `blocks: blockId[]`（有序 id 列表）；
   块对象单独存在一张表/一个 Map 里，按 id 引用。
   - 好处：流式高频更新单个块时，不必整条消息重建；多块并存（先思考、再正文、中间插工具调用）天然支持。
2. **判别联合类型(discriminated union)**：所有块继承 `BaseMessageBlock`，用 `type` 字段判别。
   Dart 里用 **sealed class**（Dart 3）或 freezed 的 union 实现。
3. **块有自己的状态机**：`pending → processing → streaming → success/error/paused`。
4. **消息状态由块状态聚合推导**（见源项目 `BlockManager.handleBlockTransition`）。

### 2.2 块类型清单（从源项目 `MessageBlockType` 直译）

| 块类型 | 用途 | 关键字段 |
|---|---|---|
| `unknown` | 占位块（流式开始前先建，再"变身"成首个真实块） | — |
| `mainText` | 主文本 | `content`, `citationReferences?` |
| `thinking` | 推理过程 | `content`, `thinkingMillsec` |
| `translation` | 翻译 | `content`, `sourceBlockId?` |
| `code` | 代码块 | `content`, `language` |
| `image` | 图片（用户上传 / 模型生成） | `url?`, `file?`, `metadata.prompt?` |
| `tool` | 工具调用 | `toolId`, `toolName?`, `arguments?`, `content?` |
| `citation` | 引用（网络搜索 / 知识库 grounding） | `webSearchResponse?`, `knowledge?` |
| `file` | 文件 | `file` (FileMetadata) |
| `error` | 错误 | `error` |

### 2.3 Dart 数据模型（示例代码）

> 用 Dart 3 `sealed class`。生产可改用 `freezed` 自动生成 copyWith/序列化。

```dart
// lib/features/chat/domain/message_block.dart

enum MessageBlockStatus { pending, processing, streaming, success, error, paused }

/// 所有块的基类。用 sealed 让 switch 能穷尽匹配。
sealed class MessageBlock {
  final String id;
  final String messageId;
  final int createdAt;
  final int? updatedAt;
  final MessageBlockStatus status;
  final String? modelId;

  const MessageBlock({
    required this.id,
    required this.messageId,
    required this.createdAt,
    required this.status,
    this.updatedAt,
    this.modelId,
  });
}

/// 占位块：流式开始前先创建，收到首个事件后"变身"为真实块。
class PlaceholderBlock extends MessageBlock {
  const PlaceholderBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
  });
}

class MainTextBlock extends MessageBlock {
  final String content;
  final List<CitationRef> citationReferences;
  const MainTextBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, this.content = '', this.citationReferences = const [],
  });

  MainTextBlock copyWith({String? content, MessageBlockStatus? status,
      List<CitationRef>? citationReferences}) =>
      MainTextBlock(id: id, messageId: messageId, createdAt: createdAt,
          status: status ?? this.status, content: content ?? this.content,
          citationReferences: citationReferences ?? this.citationReferences);
}

class ThinkingBlock extends MessageBlock {
  final String content;
  final int thinkingMillsec;
  const ThinkingBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, this.content = '', this.thinkingMillsec = 0,
  });

  ThinkingBlock copyWith({String? content, MessageBlockStatus? status, int? thinkingMillsec}) =>
      ThinkingBlock(id: id, messageId: messageId, createdAt: createdAt,
          status: status ?? this.status, content: content ?? this.content,
          thinkingMillsec: thinkingMillsec ?? this.thinkingMillsec);
}

class CodeBlock extends MessageBlock {
  final String content;
  final String language;
  const CodeBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, this.content = '', this.language = '',
  });
}

class ImageBlock extends MessageBlock {
  final String? url;       // 模型生成或直链
  final String? filePath;  // 用户上传本地图片
  final String? prompt;
  const ImageBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, this.url, this.filePath, this.prompt,
  });
}

class ToolBlock extends MessageBlock {
  final String toolId;
  final String? toolName;
  final Map<String, dynamic>? arguments;
  final Object? content; // 工具返回（string 或 json）
  const ToolBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, required this.toolId, this.toolName,
    this.arguments, this.content,
  });
}

class CitationBlock extends MessageBlock {
  final List<WebSearchResult> webResults;
  const CitationBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, this.webResults = const [],
  });
}

class FileBlock extends MessageBlock {
  final FileMetadata file;
  const FileBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, required this.file,
  });
}

class ErrorBlock extends MessageBlock {
  final String message;
  const ErrorBlock({
    required super.id, required super.messageId, required super.createdAt,
    required super.status, this.message = '',
  });
}

class CitationRef { final String citationBlockId; const CitationRef(this.citationBlockId); }
```

```dart
// lib/features/chat/domain/message.dart

enum MessageRole { user, assistant, system }
enum AssistantMessageStatus { pending, processing, searching, success, paused, error }

class Message {
  final String id;
  final MessageRole role;
  final String topicId;
  final String assistantId;
  final int createdAt;
  final AssistantMessageStatus status;
  final String? modelId;
  /// 关键：只存块 id 的有序列表（规范化）
  final List<String> blockIds;

  const Message({
    required this.id, required this.role, required this.topicId,
    required this.assistantId, required this.createdAt, required this.status,
    this.modelId, this.blockIds = const [],
  });

  Message copyWith({AssistantMessageStatus? status, List<String>? blockIds}) =>
      Message(id: id, role: role, topicId: topicId, assistantId: assistantId,
          createdAt: createdAt, status: status ?? this.status, modelId: modelId,
          blockIds: blockIds ?? this.blockIds);
}
```

### 2.4 Riverpod 状态层（规范化的块仓库）

对应源项目的 Redux「messages slice + messageBlocks slice」+ `BlockManager`。

```dart
// lib/features/chat/application/chat_state.dart

class ChatState {
  /// messageId -> Message
  final Map<String, Message> messages;
  /// 当前 topic 的消息顺序
  final List<String> messageOrder;
  /// blockId -> MessageBlock（规范化的块仓库）
  final Map<String, MessageBlock> blocks;

  const ChatState({this.messages = const {}, this.messageOrder = const [],
      this.blocks = const {}});

  ChatState copyWith({Map<String, Message>? messages, List<String>? messageOrder,
      Map<String, MessageBlock>? blocks}) =>
      ChatState(messages: messages ?? this.messages,
          messageOrder: messageOrder ?? this.messageOrder,
          blocks: blocks ?? this.blocks);
}

class ChatController extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  void upsertBlock(MessageBlock block) {
    state = state.copyWith(blocks: {...state.blocks, block.id: block});
  }

  void upsertMessage(Message m) {
    state = state.copyWith(
      messages: {...state.messages, m.id: m},
      messageOrder: state.messageOrder.contains(m.id)
          ? state.messageOrder : [...state.messageOrder, m.id],
    );
  }

  /// 把 block 追加到某条消息的块列表（如果还没在）
  void attachBlockToMessage(String messageId, String blockId) {
    final msg = state.messages[messageId];
    if (msg == null || msg.blockIds.contains(blockId)) return;
    upsertMessage(msg.copyWith(blockIds: [...msg.blockIds, blockId]));
  }

  MessageBlock? block(String id) => state.blocks[id];
}

final chatProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);
```

> **节流**：源项目对流式 chunk 做了节流（`throttledBlockUpdate`），避免每个 token 都触发一次重渲染/落库。Flutter 里建议同样处理：UI 更新可直接（Riverpod + `select` 很快），但**落库**要节流——用一个 `Timer`/`rxdart` debounce 每 ~150ms 写一次，块完成时立即 flush。

### 2.5 流式分发：StreamDispatcher（对应 BlockManager + callbacks）

源项目把流式事件拆成 `onTextStart/Chunk/Complete`、`onThinkingStart/...`、`onToolStart/...` 等，每组回调内部维护「当前这种块的 id」。核心规则：

- 流式一开始先建一个 **占位块(unknown)**；
- 首个事件到达时，如果占位块还在，就把它「变身」成对应类型；否则新建一个块并 `attach`；
- 块类型切换时（如从 thinking 切到 mainText），上一个块标记完成。

```dart
// lib/features/chat/application/stream_dispatcher.dart

class StreamDispatcher {
  final ChatController chat;
  final String messageId;
  final String Function() newId; // uuid 生成器

  String? _placeholderId;
  String? _mainTextId;
  String? _thinkingId;
  int _thinkingStartMs = 0;

  StreamDispatcher(this.chat, this.messageId, this.newId);

  void start() {
    final id = newId();
    _placeholderId = id;
    chat.upsertBlock(PlaceholderBlock(
        id: id, messageId: messageId, createdAt: _now(),
        status: MessageBlockStatus.processing));
    chat.attachBlockToMessage(messageId, id);
  }

  // ---- 思考 ----
  void onThinkingChunk(String text, {int? elapsedMs}) {
    _thinkingId ??= _morphOrCreate(
      build: (id) => ThinkingBlock(id: id, messageId: messageId, createdAt: _now(),
          status: MessageBlockStatus.streaming),
    );
    final b = chat.block(_thinkingId!) as ThinkingBlock;
    chat.upsertBlock(b.copyWith(
        content: b.content + text,
        thinkingMillsec: elapsedMs ?? b.thinkingMillsec,
        status: MessageBlockStatus.streaming));
  }

  void onThinkingComplete({int? totalMs}) {
    if (_thinkingId == null) return;
    final b = chat.block(_thinkingId!) as ThinkingBlock;
    chat.upsertBlock(b.copyWith(
        thinkingMillsec: totalMs ?? b.thinkingMillsec,
        status: MessageBlockStatus.success));
    _thinkingId = null; // 块结束，下一种块会新建
  }

  // ---- 正文 ----
  void onTextChunk(String text) {
    _mainTextId ??= _morphOrCreate(
      build: (id) => MainTextBlock(id: id, messageId: messageId, createdAt: _now(),
          status: MessageBlockStatus.streaming),
    );
    final b = chat.block(_mainTextId!) as MainTextBlock;
    chat.upsertBlock(b.copyWith(
        content: b.content + text, status: MessageBlockStatus.streaming));
  }

  void onTextComplete() {
    if (_mainTextId == null) return;
    final b = chat.block(_mainTextId!) as MainTextBlock;
    chat.upsertBlock(b.copyWith(status: MessageBlockStatus.success));
    _mainTextId = null;
  }

  // ---- 工具调用（阶段六接入） ----
  void onToolCall({required String toolId, String? name, Map<String, dynamic>? args}) {
    final id = newId();
    chat.upsertBlock(ToolBlock(id: id, messageId: messageId, createdAt: _now(),
        status: MessageBlockStatus.processing, toolId: toolId, toolName: name, arguments: args));
    chat.attachBlockToMessage(messageId, id);
    // 结果回来时再 upsert content + status=success
  }

  void finish() {
    onTextComplete();
    onThinkingComplete();
    final msg = chat.state.messages[messageId];
    if (msg != null) chat.upsertMessage(msg.copyWith(status: AssistantMessageStatus.success));
  }

  /// 若占位块还在则复用其 id，否则新建并挂到消息上
  String _morphOrCreate({required MessageBlock Function(String id) build}) {
    final id = _placeholderId ?? newId();
    _placeholderId = null;
    final block = build(id);
    chat.upsertBlock(block);
    chat.attachBlockToMessage(messageId, id);
    return id;
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;
}
```

把它接到你现有的 SSE/流式解析处：

```dart
Future<void> sendMessage(String text) async {
  final assistantMsgId = uuid();
  chat.upsertMessage(Message(id: assistantMsgId, role: MessageRole.assistant, /*...*/
      status: AssistantMessageStatus.processing));
  final dispatcher = StreamDispatcher(chat, assistantMsgId, uuid)..start();

  await for (final event in llmProvider.streamChat(...)) {
    switch (event.type) {
      case StreamEventType.reasoning: dispatcher.onThinkingChunk(event.delta); break;
      case StreamEventType.text:      dispatcher.onTextChunk(event.delta);      break;
      case StreamEventType.toolCall:  dispatcher.onToolCall(/*...*/);           break;
      // ...
    }
  }
  dispatcher.finish();
}
```

### 2.6 UI 渲染：按块分发

```dart
// 一条消息 = 遍历它的 blockIds，逐块渲染
class MessageView extends ConsumerWidget {
  final String messageId;
  const MessageView(this.messageId, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final msg = ref.watch(chatProvider.select((s) => s.messages[messageId]));
    if (msg == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final id in msg.blockIds) BlockView(id)],
    );
  }
}

class BlockView extends ConsumerWidget {
  final String blockId;
  const BlockView(this.blockId, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final block = ref.watch(chatProvider.select((s) => s.blocks[blockId]));
    return switch (block) {
      MainTextBlock b  => MarkdownBlock(data: b.content),       // 复用你现有 markdown 渲染
      ThinkingBlock b  => ThinkingBlockView(b),                 // 见阶段二
      CodeBlock b      => CodeBlockView(code: b.content, lang: b.language),
      ImageBlock b     => ImageBlockView(b),
      ToolBlock b      => ToolBlockView(b),
      CitationBlock b  => CitationBlockView(b),
      FileBlock b      => FileBlockView(b.file),
      ErrorBlock b     => ErrorBlockView(b.message),
      PlaceholderBlock _ => const ThreeDotsLoading(),
      null => const SizedBox.shrink(),
    };
  }
}
```

### 2.7 持久化（Drift）

两张表对应源项目的 `messages` / `message_blocks`：
- `messages(id, topic_id, role, status, model_id, created_at, block_ids TEXT)` — `block_ids` 存 JSON 数组。
- `message_blocks(id, message_id, type, status, payload TEXT, created_at)` — `payload` 存块的 JSON。
- 落库节流：流式中按 ~150ms debounce 写当前块；`*Complete` 时立即 flush。

### 2.8 源文件对照表（要细节就读这些）

| Flutter 产物 | 源项目参考文件 |
|---|---|
| 块类型/消息模型 | `src/types/message.ts` |
| BlockManager（活跃块/转换/节流） | `src/services/messageStreaming/BlockManager.ts` |
| 流式回调分发 | `src/services/messageStreaming/callbacks/{text,thinking,tool,citation,image}Callbacks.ts` |
| 块创建工具 | `src/utils/messageUtils/create.ts` |
| 块 UI 渲染 | `src/screens/home/messages/blocks/*.tsx` |

### 2.9 验收标准（阶段一 Done 的定义）

- [x] 一条 assistant 消息可同时包含多个块，按到达顺序排列。
- [x] 模型先输出思考、再输出正文时，UI 出现两个独立块（思考可折叠）。
- [x] 流式过程中只有"当前块"在增量更新，其它块不重渲染。
- [x] 杀进程重启后，历史消息的所有块完整恢复（持久化生效）。
- [x] 出错时插入 error 块，消息状态变为 error。

### 2.10 ✅ 实施记录（2026-06-10）

**落地映射**（指南 → 本仓库实现）：
- 块模型（§2.3）→ `chat/domain/message_block.dart`：Dart 3 `sealed class MessageBlock` + 9 种子类；`encodeList/decodeList` 做 JSON 往返。
- 规范化块仓库（§2.4 Riverpod）→ `chat/application/chat_block_store.dart`：用 **`ChangeNotifier`**（仓库约定不引入 Riverpod）；`messageKey -> blockIds`、`blockId -> MessageBlock` 两张 Map。
- 流式分发器（§2.5 BlockManager）→ `chat/application/stream_dispatcher.dart`：占位块变身 `_morphOrCreate`、块类型切换**对称收尾**、错误/停止/空流收尾。
- 类型化流事件 → `chat/domain/stream_event.dart`（`text` / `reasoning` / `toolCall` / `toolResult` / `image` / `citation`）。**SSE 源头分流**：`openai_flutter/lib/http/ai_http.dart` 新增 `postStreamEvents`，把 `delta.content` 与 `delta.reasoning_content` 分别 yield；`dao/chat/*` 新增 `chatStreamEvents`。
- 按块渲染（§2.6）→ `chat/ui/block_message_content.dart`：`switch(block)` 穷尽匹配；外层 `Selector` 订阅 blockId 列表、每块 `Selector` 订阅单块 → **每 token 只重绘当前块**。
- 持久化（§2.7 Drift）→ **sqflite**：`tb_messages` 新增 `blocks TEXT` 列（写进 CREATE + ALTER 双保险）；`content` 仍存「主文本」用于历史/预览，`blocks` 存整条块列表 JSON。`MessageDao.saveMessageWithBlocks` / `getBlocksByCreatedAt`。
- 集成 → `pages/conversation_page.dart`：`_onSendStream` 用分发器驱动块；`chat_message` 包新增**向后兼容**的 `contentBuilder` 钩子，只替换气泡内部内容、保留头像/时间/长按菜单。

**节流取舍**：UI 更新走 `Selector` 已足够轻量，未引入 150ms debounce 落库；改为「**收尾时一次性落库**」（含中途退出页面的兜底落库），更简单且无丢数据。

**对抗式审查后修复的关键 Bug**（已带回归测试）：
1. 流式中途退出页面 → 回复不落库（丢数据）+ 可能 notify 已销毁 store（崩溃）→ `dispose()` 同步快照+收尾+兜底落库 + `_disposed` 守卫。
2. 快速连发/回车 → 并发流互相覆盖 → `_onSend` 首行 `if (_isStreaming) return` + 同步置位 + 输入框 submit 加门。
3. `think→text→think→text` 交错流顺序错乱 → 块切换**对称收尾** + `mainText` 聚合所有正文块。
4. `MessageModel.copyWith` 重新生成 `GlobalKey` → 收尾时整气泡重建、思考块被收起 → `copyWith` 复用同一 key。
5. 空回复落空串、回灌成空 assistant 轮次 → 移除遗留占位块 + 「no response」兜底。
6. `createdAt` 同毫秒撞 key → `_genMessageModel` 钳成严格递增。
7. 多轮上下文丢失（`_messageList` 从不追加）→ 每轮收尾 `completionDao.appendTurn`。

**测试**：`chatgpt_app_core/test/block_message_test.dart`（14）+ `chat_message/test`（GlobalKey 等）。4 个包静态分析零错误，共 28 测试通过。

---

## 3. 阶段二：思考 / 推理过程展示

**目标**：`ThinkingBlock` 折叠展示，显示"思考用时 N 秒"；流式中实时跳秒。

- 源参考：`reasoningTimePlugin.ts`（计时）、`blocks/ThinkingBlock.tsx`（UI）、`thinkingCallbacks.ts`（流式）。
- 计时：在 `onThinkingChunk` 首次到达时记 `startMs`，每次 chunk 用 `now - startMs` 更新 `thinkingMillsec`；`onThinkingComplete` 落最终值。
- 不同模型的 reasoning 来源不同（Claude 的 reasoning、DeepSeek-R1 的 `<think>` 标签、OpenAI o 系列）——在 provider 适配层统一成一种 `reasoning` 流事件（见阶段三）。

**验收**：思考块默认折叠、显示用时；点击展开看全文；正文开始后思考块停止计时。✅ 已满足

### ✅ 实施记录（2026-06-10）

- UI → `chat/ui/thinking_block_view.dart`：默认折叠，标题「正在深度思考 · N.N 秒」/「已深度思考 · 用时 N.N 秒」；点击展开全文。
- **实时跳秒**：本地 `Timer.periodic(200ms)` 在两次 chunk 之间持续走表（以最近一次 `thinkingMillsec` 为基线叠加墙钟时间），`status != streaming` 时停表。
- 计时来源：`StreamDispatcher.onThinkingChunk` 首次到达记 `startMs`，每次 chunk 用 `now-start` 刷新 `thinkingMillsec`，`onThinkingComplete` 落最终值（与源项目 `reasoningTimePlugin` 语义一致）。
- 正文开始 → `onTextChunk` 调 `onThinkingComplete` 收尾思考块、停表。
- **关键收益**：思考内容只进 `ThinkingBlock`、不进 `mainText`，因此**不会作为历史重新发回模型**（`completion_dao._buildHistory` 只取主文本）。
- 当前接的 reasoning 源：DeepSeek-R1 的 `reasoning_content`（OpenAI 兼容字段）。Claude `reasoning` / OpenAI o 系列等留待阶段三在 provider 适配层统一。

---

## 4. 阶段三：多 Provider 抽象 + 能力探测

**目标**：把"写死一个 provider"改成可插拔，并用"能力标志"驱动差异化逻辑（决定阶段四/五/六能否启用）。

```dart
abstract class LlmProvider {
  String get id;
  Stream<StreamEvent> streamChat(ChatRequest req); // 统一成 text/reasoning/toolCall/image/citation 事件
}

class ModelCapabilities {
  final bool image, pdf, tool, reasoning, largeFileUpload;
  final int Function(FileType) fileSizeLimit;
  // ...
}

// 用能力探测驱动行为：
// supportsImageInput(model) -> 能否把图片当多模态发
// supportsPdfInput(model)   -> 能否原生发 PDF，否则降级抽文本
// supportsTool(model)       -> 能否启用工具调用 / 搜索编排
```

- 源参考：`src/aiCore/provider/`、`src/aiCore/prepareParams/modelCapabilities.ts`、`getAiSdkProviderId`。
- 关键差异适配：Anthropic 的 `image/jpg → image/jpeg`、各家 reasoning 字段、SSE 格式差异——全部收敛到 provider 适配层，对上只暴露统一 `StreamEvent`。
- 先接 1~2 家（OpenAI 兼容 + Anthropic），把接口跑通，再加其它。

**验收**：切换模型/厂商无需改 UI 与分发层；`capabilities` 能正确开关图片/PDF/工具入口。

### ✅ 实施记录（2026-06-10）

**落地映射**（指南 §4 → 本仓库实现，按「收敛进已有 `ChatService`」而非照搬 `LlmProvider`）：
- **能力模型** → `chat/domain/model_capabilities.dart`：纯 Dart `ModelCapabilities`（`image/pdf/tool/reasoning/largeFileUpload` + 占位 `Map<String,int>? fileSizeLimits` 及 `fileSizeLimitFor(type)`），含 `ModelCapabilities.heuristic(modelId, providerCode)` 按家族前缀查表（Claude / Gemini / OpenAI o 系 / gpt-4o / gpt-4·3.5 / DeepSeek-R1 / DeepSeek-V3），未知模型一律 `none()` 保守关闭。无 Flutter / 网络依赖，可单测。o 系列 vision/tool 分别判断（`o1-mini` 无 vision 无工具、`o3-mini` 有工具无 vision、`o4-mini` 全有）。
- **统一探测入口** → `util/model_catalog.dart` 新增 `capabilitiesFor(modelId, {providerCode})`（+ `optionFor` 跨清单反查）：把启发式与「远程清单的 `supportsVision`」合并（远程标了多模态则强制打开 `image` 位）。**这是唯一来源**，UI 与两个 `ChatService` 实现都只调它。
- **Provider 抽象** → `ChatService` 新增 `ModelCapabilities get capabilities`；`ChatService.from` 把本地服务商 code（`'openai'/'deepseek'`）传给 `DirectChatService`。`DirectChatService` 用 `_cfg.model + providerCode` 算能力；`BackendChatService` 用 `effectiveModel` 让清单反查 providerCode（后端 `/uapi/ai/catalog` 不下发能力位，故 backend 模式靠 modelId 家族 + 远程 vision）。`CompletionDao.capabilities` 转发 `chatService.capabilities`。
- **UI 收敛** → `pages/conversation_page.dart`：删除点状 `_checkVision`，改为 `ModelCapabilities _capabilities`，图片入口 `imagesEnabled: _capabilities.image`。早期 init 走同步的 `_capsFor(settings)`，settings 变更时从重建后的 `completionDao.capabilities`（即 `chatService.capabilities`）读取——两者同源，结果一致。**分发层 `StreamDispatcher` / `StreamEvent` 完全未动**。

**验收逐条**：① 切换模型/厂商无需改 UI 与分发层 —— UI 只调一个 provider-agnostic 的 `capabilitiesFor`，`StreamDispatcher` 零改动 ✅；② `capabilities` 正确开关图片入口 —— `gpt-4o`→开、`gpt-3.5`→关、`deepseek-reasoner`→`reasoning=true/tool=false`，远程 `supportsVision` 可覆盖 ✅；③ `pdf/tool/largeFileUpload/fileSizeLimits` 字段已就位，阶段四/五/六「只需填充数据 + 接流事件」。

**测试**：`chatgpt_app_core/test/model_capabilities_test.dart`（17：家族推断 13 含 o1/o3/o4-mini 边界 + ChatService 暴露/切换 6 含同源校验 + 远程 vision 合并 1）。`chatgpt_app_core` 静态分析零错误，连同阶段一/二共 **45 个测试通过**；`chatgpt_flutter` 壳层全图 analyze 无 error。

**对抗式复审（多 agent）后已修**：① o 系列 `isMini` 只认 `o1-mini` → `o3-mini/o4-mini` 误判 image=true，改为 vision/tool 分别判断（已加边界测试）；② `fileSizeLimit` 从闭包字段改为纯数据 `Map<String,int>? fileSizeLimits` + `fileSizeLimitFor`，保持 const 可构造。

**⚠️ 阶段三复审遗留项（移交下一会话，详见 `next-session-prompt.md` §7）**：
1. **UI 能力非响应式**（major）：`conversation_page._capabilities` 仅在发送时刷新，用户去「AI 服务设置」改模型后返回，图片按钮要到下次发送才更新。建议 `build()` 里 `context.watch<AISettingsProvider>()` 后用 `_capsFor(settings)` 直接算，单一来源、即时生效。
2. **providerCode 派生规则重复**（minor）：`_capsFor` 与 `ChatService.from` 各写一份「local 传 code / backend 不传」规则。建议抽 `static ModelCapabilities ChatService.capabilitiesFor(AISettings)` 统一。
3. **后端能力位缺失**（major，需后端配合）：`/uapi/ai/catalog` 不下发 `supportsVision` 等能力位，故后端模式能力**全靠 modelId 家族启发式**——管理后台新增的非常规命名多模态模型会被判 image=false。彻底解决需后端 `AiModel` 加能力列 + catalog 下发 + 管理端可编辑；当前为有意的启发式兜底（已在 `capabilitiesFor` 注释说明）。

---

## 5. 阶段四：文件解析 + 图片多模态

**策略（直译源项目 `fileProcessor.ts`）**：能原生喂模型就喂，不能就降级抽文本。

| 能力 | Flutter 库 |
|---|---|
| 选文件 | `file_picker` |
| 选图/拍照 | `image_picker` |
| PDF 抽文本 | `syncfusion_flutter_pdf`（纯 Dart，免写原生） |
| 图片转 base64 | `base64Encode(await File(path).readAsBytes())` |
| 存图到相册 | `gal` |

决策流程：
1. 图片 + `caps.image` → 转 base64 作多模态 `FilePart`（注意 MIME 修正）。
2. PDF + `caps.pdf` 且未超 `fileSizeLimit` → base64 原生发；超限且 `caps.largeFileUpload` → File API 上传；否则降级。
3. 降级路径：PDF 用 syncfusion 抽文本（限页，源项目限 20 页）、文本文件直接读、Word/Excel 抽文本，拼进 prompt。
4. 用户上传的文件/图片在消息里建 `FileBlock`/`ImageBlock` 展示。

- 源参考：`src/aiCore/prepareParams/fileProcessor.ts`、`src/services/{FileService,ImageService}.ts`、`src/aiCore/utils/image.ts`、原生模块 `modules/pdf-text-extractor`（Flutter 不必照搬，用 syncfusion 替代）。

**验收**：发 PDF/图片给支持的模型走原生；不支持时自动降级抽文本且对用户透明；生成的图片能存相册。

### ✅ 实施记录（2026-06-12）

**先修阶段三复审遗留项**（见 §4 文末）：
- **遗留 1（UI 能力非响应式）已修**：`conversation_page.build()` 改为 `context.watch<AISettingsProvider>()` 后用 `ChatService.capabilitiesFor(settings)` 即时算能力，传给 `MessageInputWidget`；删除缓存字段 `_capabilities` 及 `_doInit`/`_onSend` 里的赋值。用户改模型返回聊天页，图片入口立即刷新。
- **遗留 2（providerCode 规则重复）已修**：`ChatService` 新增 `static providerCodeFor(AISettings)`（唯一出处）与 `static capabilitiesFor(AISettings)`；`ChatService.from` 与 UI 都委托它。`ModelCapabilities` 补值相等（`==`/`hashCode`），加防回归测试「`ChatService.from(s).capabilities == ChatService.capabilitiesFor(s)`」（5 组 settings）。
- 遗留 3（后端能力位缺失）仍开放，属后端任务，不阻塞（`capabilitiesFor` 注释已标注启发式兜底）。

**阶段四落地映射**（指南 §5 → 本仓库实现）：
- **附件处理器** → `chat/application/file_processor.dart`：直译 `fileProcessor.ts` 的「能原生喂就喂、不能就降级抽文本」。PDF：`caps.pdf` 且 ≤ `caps.fileSizeLimitFor('pdf')` → base64 原生 file part；否则 `syncfusion_flutter_pdf` 抽文本（限 20 页，与源项目一致）。文本类文件直读（截断 30k 字符）。图片 base64 编码 + **MIME 修正**（`jpg→jpeg` 收敛，对应源项目 Anthropic 适配；本仓库两个 provider 均为 OpenAI 兼容协议，编码处即适配层）。
- **当前轮多模态** → `chat/domain/chat_attachments.dart`：`ChatAttachments`（images / nativeFiles / extraText）+ `buildUserContent(prompt)` 组装 OpenAI content 数组（无附件退化为纯字符串，与旧行为一致）。**修复关键缺口：此前当前轮图片只通过 history 在下一轮才送达模型**；现在 `ChatService.chat/chatStream/chatStreamEvents` 增加可选 `attachments`，当前轮即携带（`CompletionDao` 透传）。
- **能力表补全** → `ModelCapabilities.heuristic`：gpt-4o/chatgpt-4o/gpt-4.1 增加 `pdf: true` + `fileSizeLimits {'pdf': 32MB}`（Chat Completions file part）；claude 32MB / gemini 50MB 同步填充；gpt-4-turbo/4-vision 拆出（有 vision 无原生 PDF）。
- **UI 入口** → `widget/message_input_widget.dart`：新增附件按钮（`file_picker`，扩展名白名单 `FileProcessor.pickerExtensions`，上限 3 个）+ 待发送文件条（图标/文件名/删除）。文件入口**不按能力位关闭**——不支持原生的模型走抽文本降级，任何模型可用；OHOS 同 image_picker 隐藏。
- **用户消息块展示** → `conversation_page._addUserMessageWithBlocks`：带文件的用户消息组装 `ImageBlock(filePath)`/`FileBlock(FileMetadata)`/`MainTextBlock`，seed 进 `ChatBlockStore` 并经 `saveMessageWithBlocks` 连块落库（历史恢复走既有 `_seedBlocks`）。`_buildBlockContent` 放开 sender（有块即块化渲染）；**纯图片消息保留默认九宫格 + 点击预览**（不降级为块渲染）。
- **生成图片流事件** → `StreamEvent.image(url)` + `StreamDispatcher.onImage`（到达即完整、success 态 ImageBlock，不打断正在流式的正文块）；`conversation_page` 已接 `StreamEventType.image` 分发。

**验收逐条**：① 发 PDF/图片给支持的模型走原生 —— 图片 `image_url` part、PDF `file` part（gpt-4o 实测路径） ✅；② 不支持时自动降级抽文本且对用户透明 —— syncfusion 限页抽取 / 文本直读拼 prompt，UI 无差别 ✅；③ 生成的图片能存相册 —— **延后**：当前两个 provider（OpenAI 兼容 chat completions / 后端代理）不产生图片输出，`onImage` 通路已就绪、待有生成图片的 provider 时再接 `gal`。

**测试**：`test/file_attachments_test.dart`（11：MIME 修正 2 + PDF 原生/降级/超限 3 + 文本直读/截断 2 + buildUserContent 2 + onImage 2）+ `model_capabilities_test.dart` 扩充（gpt-4o pdf、gpt-4-turbo 拆分、同源防回归、providerCodeFor）。`chatgpt_app_core` **61 个测试全部通过**、analyze 0 errors；`chatgpt_flutter` 壳层全图 analyze 无 issue。

**已知限制（移交后续阶段/任务）**：
1. 超限 PDF 且 `caps.largeFileUpload` 时源项目走 File API 上传；本仓库两个 provider 无文件上传通道，统一降级抽文本（接入 Anthropic/Gemini 直连时再补）。
2. 附件抽取文本只随当前轮发送，**不进入后续轮次的 history**（用户消息 content 仍只存输入文本，避免污染气泡与预览）；需要跨轮文件上下文时再从 FileBlock 重建。
3. 阶段三遗留 3（后端 catalog 能力位）仍开放，见 §4。

---

## 6. 阶段五：智能联网搜索（意图编排）

**这是体验亮点，不是裸调 API**。源参考：`src/aiCore/plugins/searchOrchestrationPlugin.ts`、`src/services/WebSearchService.ts`、`src/providers/WebSearchProvider/*`。

流程：
1. **意图识别**：发正式请求前，用一次轻量 LLM 调用分析"要不要联网"，并把用户问题**改写/拆解**成多个 query（源项目让模型输出 XML，再解析；用 JSON/tool-call 更稳）。失败有 fallback（直接用原问题搜）。
2. **多 Provider 抽象**：`BaseWebSearchProvider { Future<SearchResponse> search(query, opts) }` + 工厂。先接 **Tavily**（POST `/search` 最简单），再加 Exa/Bocha/Zhipu。
3. **并行 + 聚合**：多 query 用 `Future.wait` 并行，结果合并、按 `contentLimit` 截断。
4. **回填**：把结果作为工具结果交给主 LLM 总结，并建 `CitationBlock` 展示来源。

```dart
abstract class WebSearchProvider {
  Future<List<WebSearchResult>> search(String query, {int maxResults = 5, int contentLimit = 0});
}
class WebSearchResult { final String title, url, content; /*...*/ }
```

**验收**：问"今天的新闻"类问题会自动触发搜索；消息底部出现可点的引用来源；不需要搜的问题不触发。

### ✅ 实施记录（2026-06-12）

**阶段五落地映射**（指南 §6 → 本仓库实现）：
- **意图识别** → `chat/application/search_orchestrator.dart`：发正式请求前用一次非流式 `chatService.chat`（与正式会话同一服务，本地/后端模式都可用）分析「要不要联网」，并改写/拆解成 1~3 个自包含 query。**用 JSON 输出**（比源项目 XML 稳）：`SearchIntent.parse` 容错取首 `{` 到末 `}`（允许围栏/混杂文字）；needSearch=true 但 queries 空 → 回退原问题；解析/调用失败 → `SearchIntent.fallback` 直接用原问题搜。意图 prompt 带今天日期；历史取最近 4 条且压成纯文本（多模态 content 只取 text part，不重发图片）。
- **Provider 抽象 + 工厂** → `chat/application/web_search_provider.dart`：`WebSearchProvider.search(query, {maxResults, contentLimit})` 抽象 + `TavilyWebSearchProvider`（POST /search，Bearer 鉴权，`package:http` 可注入 Client 便于测试）+ `fromSettings` 工厂（未配 key 返回 null；后续 Exa/Bocha 在此分流）。**API key 进「AI 服务设置 → 联网搜索」卡片**（`AISettings.tavilyApiKey`，不写死文件）。
- **并行 + 聚合** → `SearchOrchestrator.searchAll`：多 query `Future.wait` 并行，单 query 失败吞错不拖垮整体；按 URL 去重合并，单条摘要截 2000 字符、总数截 8 条。
- **回填 + 引用** → 搜索上下文经 `SearchOrchestrator.buildSearchContext`（编号 + 来源 URL + 「[编号] 标注」指引）走 `ChatAttachments.withExtraText` 通路拼进当前轮 prompt（与文件降级文本同通路）；`CompletionDao.streamCompletionEvents(webSearch:)` 在正文流结束后补发 `StreamEvent.citation(webResults)`（payload 已补，参照 image 的做法）→ `StreamDispatcher.onCitation` → success 态 `CitationBlock` 自然落在消息底部；`_Citation` 渲染编号来源列表，点击 `url_launcher` 外开。非流式走 `createCompletionsWithSearch`（返回 `CompletionResult{content, webResults}`），会话页组装「正文块 + 引用块」连块落库。**搜索任何环节失败都降级为不搜，绝不阻塞正式会话**。
- **入口开关** → 会话页输入栏地球图标（`MessageInputWidget.showWebSearch/webSearchEnabled/onToggleWebSearch`）。**决策：开关独立于 `caps.tool`、所有模型可用（采纳 Cherry 的做法）**——搜索结果以上下文回填而非 tool calling，不依赖模型工具能力；开关持久化在 `AISettings.webSearchEnabled`（所有会话共享），仅在配置了 Tavily key 时展示。

**验收逐条**：① 「今天的新闻」类问题自动触发搜索 —— 意图识别判 needSearch + 改写 query（失败 fallback 仍搜）✅；② 消息底部出现可点的引用来源 —— citation 事件在正文流后到达，`CitationBlock` 落底部、点击外开浏览器，落库恢复后仍可点 ✅；③ 不需要搜的问题不触发 —— needSearch=false 直接跳过 provider（测试断言零调用）✅。

**测试**：`test/web_search_test.dart`（19：意图解析容错 5 + Tavily MockClient 3 + 并行聚合 2 + 编排端到端 4 + 回填/块化 5）+ AISettings 新字段往返。`chatgpt_app_core` **83 个测试全部通过**、analyze 0 errors；`chatgpt_flutter` 壳层全图 analyze 无 issue。

**已知限制（移交后续阶段/任务）**：
1. 意图识别多花一次轻量 LLM 调用（非流式、短输出）；后续阶段六可改为把「联网搜索」注册成工具由模型自主调用，二选一。
2. 引用编号目前只在来源列表展示；正文里的 `[n]` 标注未做点击联动（需 markdown 渲染配合，挪到正文 Markdown 化时一并做）。
3. 仅接入 Tavily；Exa/Bocha/智谱在 `WebSearchProvider.fromSettings` 扩展即可。

---

## 7. 阶段六：工具调用（Tool Calling）

- 在 `StreamEvent` 里支持 `toolCall`/`toolResult`，分发到 `ToolBlock`（§2.5 已留接口）。
- 工具注册表：把"联网搜索""知识库检索"等都注册成工具，由模型决定调用。
- 源参考：`src/aiCore/tools/`、`src/services/messageStreaming/callbacks/toolCallbacks.ts`、`blocks/ToolBlock.tsx`。

**验收**：模型调用工具时出现 ToolBlock（显示工具名/参数/结果折叠），调用完继续正文。

### ✅ 实施记录（2026-06-12）

**阶段六落地映射**（指南 §7 → 本仓库实现）：
- **SSE 分片解析** → `openai_flutter`：`AIStreamChunk` 加 `toolCall` kind（index/id/name/argsDelta 分片字段），`AIHttp.postStreamEvents` 解析 `delta.tool_calls`；`createChatStreamEvents` 加 `tools` 参数进 body。后端代理路径在 `BackendChatService.chatStreamEvents` 自己的 SSE 解析里同步处理（后端中继本就原样透传分片）。
- **分片累积** → `chat/application/tool_call_accumulator.dart`：两个 ChatService 实现共用 —— `tool_calls` 的 arguments 是 JSON 字符串分片按 index 累积，流结束（[DONE]）后 `flush` 出**完整**的 `StreamEvent.toolCall`（坏 JSON 降级空 map、缺 id 补 `tool_<index>`）。`ChatService.chatStreamEvents` 接口加 `tools` + `extraMessages`（回灌消息追加在当前轮 user 之后）。
- **工具注册表** → `chat/application/tool_registry.dart`：`ChatTool`（name/description/JSON Schema 参数/execute）→ OpenAI function declarations；`ToolRegistry.execute` 把「未注册 / 执行抛错」都转成文本回灌给模型（**工具失败绝不中断会话流**）。首个工具 `web_search` 复用阶段五 `WebSearchProvider`，结果以编号 JSON 回灌、同时带出 `webResults`；「知识库检索」在 `fromSettings` 处留扩展点。
- **执行回路** → `chat/application/tool_loop_runner.dart`：调用→执行→`assistant(tool_calls)` + `role:tool` 回灌→续写正文，循环上限 5 轮 —— **收尾轮不带 tools 强制模型直接作答**（+ 硬性 break 保护，绝不无限循环）；各轮 `web_search` 来源按 URL 去重，收尾发一次 `StreamEvent.citation`，与阶段五的可点来源体验一致。`CompletionDao.streamCompletionEvents` 加 `tools` 参数走该回路。
- **块化展示** → `StreamDispatcher.onToolCall` 改为收尾活跃思考/正文块再 `_morphOrCreate`（text→tool→text 按到达顺序成块，占位块可直接变身）；新增 `onToolResult` 按 toolId 找到 ToolBlock 填 content 置 success。`_Tool` 改为可折叠：头部「工具名 + 转圈/图标」，展开显示参数与结果（能 pretty 成 JSON 就 pretty，限高滚动）。
- **入口选路（决策）**：联网开关仍是阶段五的单一用户开关；发送时 **`caps.tool` 为 true（且流式开启）→ 把联网搜索注册成工具、由模型自主决定调用（ToolLoopRunner）；否则回落阶段五意图编排**。两条路互斥（避免双重搜索 + 多余的意图 LLM 调用），引用来源 UX 一致。非流式保持阶段五路径（工具回路仅接流式）。
- **后端配合** → `chatgpt_backend` `CompletionBodyDto` / `CompletionBody` 加可选 `tools`（ValidationPipe 开了 whitelist，不声明会被剥掉）；SSE 中继与非流式 body 展开本就透传，无其它改动。

**验收逐条**：模型调用工具时出现 ToolBlock（工具名/参数/结果可折叠）✅（`_Tool` 折叠 UI + dispatcher 测试）；调用完继续正文 ✅（回灌后续轮正文落新 MainTextBlock，`mainText` 聚合两段，端到端测试断言事件序列 text→toolCall→toolResult→text→citation）。

**测试**：`test/tool_calling_test.dart`（16：accumulator 4 + registry 6 + loop 端到端 3 + dispatcher 3）。`chatgpt_app_core` **99 个测试全部通过**、analyze 0 errors；`openai_flutter` analyze 无 issue（其 `openai_flutter_test.dart` 为存量真网演示测试，需真实 key/代理，与本次无关）；`chatgpt_flutter` 壳层全图 analyze 无 issue；后端 `tsc --noEmit` 通过（lint/jest 的失败均为存量：admin-usage 文件 + jest 运行时版本不匹配，所改文件零告警）。

**已知限制（移交后续阶段/任务）**：
1. 工具调用历史不跨轮：assistant(tool_calls)/role:tool 回灌只存在于当轮请求，落库 history 仍是「正文」——下一轮模型看不到上一轮工具细节（与附件文本同策略）。
2. 工具回路仅流式路径；非流式走阶段五意图编排。
3. 后端模式依赖上游模型真的支持 function calling；`caps.tool` 在后端模式仍来自 modelId 启发式（阶段三遗留 3）。

---

## 8. 阶段七 / 八（简）

- **助手系统**：`Assistant{ id, name, prompt, model, tools }`，会话绑定一个助手。源参考：`src/services/AssistantService.ts`、`src/types/assistant.ts`、`src/screens/assistant/`。
- **备份/恢复**：把消息/块/会话/配置打成 zip 导出导入（Flutter 用 `archive` 包）。源参考：`src/services/BackupService.ts`。

### ✅ 实施记录 · 阶段七（2026-06-12）

**阶段七落地映射**（指南 §8 助手系统 → 本仓库实现）：
- **领域模型** → `model/assistant_model.dart`：`AssistantModel{id,name,emoji,prompt,model,useTools}`（对应源项目 Assistant 的精简版，settings/topics/MCP 等不在本阶段范围）。`applyTo(AISettings)` 是模型覆盖的唯一出口 —— clone 设置后替换当前生效路径（后端 → backendModel，本地 → 所选服务商的 model），`ChatService.capabilitiesFor(applyTo(s))` 即得覆盖后能力位（沿用 `AISettings.effectiveModel` 派生路径）。
- **持久化** → `db/assistant_dao.dart`：`IAssistant`/`AssistantDao` + `tb_assistant`（「接口 + 实现同文件」+ `ITable` + 静态 create 工厂，照 `conversation_dao` 模式）。删除助手不级联清会话的 assistantId —— 引用悬空时 `getAssistant` 返回 null，会话自然回落无助手。
- **会话绑定** → `ConversationModel.assistantId` + `tb_conversation_list` 加列（CREATE 带列 + try/catch ALTER 兼容旧表，照 `MessageDao` blocks 列做法）。绑定随会话在返回列表页时一并落库（沿用 `_doUpdate` 既有通路）。
- **system prompt 注入** → `CompletionDao` 加 `systemPrompt` 构造参数 + 静态纯函数 `injectSystemPrompt`（便于单测）：非空时作为 `{'role':'system'}` 插 history 头部；**意图识别的轻量调用（`_runWebSearch`）拿无 system 的 history**，避免人设污染「要不要联网」的判断；ToolLoopRunner / 正式会话路径都带 system。
- **能力位与 Dao 重建** → `ConversationPage`：`_effective(settings)`（应用助手覆盖）统一供 build 的 caps、`_onSend` 的请求构造与块上 modelId（`_effectiveModelId`）；CompletionDao 在「settings 或助手变更」时重建（携带历史）。助手 `useTools=false` 时工具路径回落阶段五意图编排（与 caps.tool=false 同路）。AppBar 标题/气泡 ownerName 显示助手名。
- **UI** → `pages/assistant_list_page.dart`（列表/删除确认）+ `pages/assistant_edit_page.dart`（名称/emoji/提示词/模型覆盖下拉/工具开关；模型选项按当前设置的生效路径给，保证与服务商兼容）+ `widget/assistant_picker.dart`（底部弹窗：不使用助手 / 列表 / 管理入口；**一个助手都没有时新建会话零打扰直接放行**）。入口：「我的 → 助手管理」、新建会话先选助手、会话内 AppBar 切换（下次发送生效）。
- **测试设施** → `HiDBManager.test(Database)`（@visibleForTesting）：让 DAO 单测用 sqflite_common_ffi 内存库走真实 DAO 代码路径（替代以往「raw SQL 复刻 schema」的写法）。

**验收逐条**：助手 CRUD 持久化 ✅（DAO 全链路测试）；会话绑定 + 旧表升级 ✅（ALTER 幂等测试）；system 注入正式会话、不进意图识别 ✅（injectSystemPrompt 测试 + `_runWebSearch` 拿原始 history）；模型覆盖驱动能力位 ✅（gpt-3.5→gpt-4o 后 image/tool 翻转测试）；管理/选择/切换 UI ✅。

**测试**：`test/assistant_test.dart`（13：模型 2 + applyTo 4 + 注入 3 + DAO 2 + 升级 2）。`chatgpt_app_core` **112 个测试全部通过**、analyze 0 errors；`chatgpt_flutter` 壳层全图 analyze 无 issue、widget 测试通过。

**已知限制（移交后续阶段/任务）**：
1. 本地模式的模型覆盖只换模型名、不切服务商（覆盖的模型须与当前服务商兼容；编辑页下拉按当前设置给选项即为此约束的 UI 化）。源项目的 Assistant.model 带 provider，完整形态待多 Provider 配置抽象后再做。
2. 助手切换不重算已发送轮次：system prompt 只影响后续请求（与 Cherry 行为一致）。
3. 内置助手（default/quick/translate）与助手市场未迁移；仅用户自建助手。

### ✅ 实施记录 · 阶段八（2026-06-12）

**阶段八落地映射**（指南 §8 备份/恢复 → 本仓库实现）：
- **核心服务** → `backup/backup_service.dart`：纯 Dart（`archive` 包 ^4，无平台通道，OHOS 可用），文件读写/分享留给 UI 层，因此能用 ffi 内存库做 round-trip 单测。zip 结构：`manifest.json`（formatVersion=1 + exportedAt + accountHash + counts）+ `conversations.json` / `messages.json`（含 blocks 列）/ `assistants.json` / `favorites.json`（每表一个 JSON，sqflite 行原样序列化、保留原始 id/cid）+ `settings.json`。
- **API key 默认脱敏**：导出时 `includeApiKeys=false`（默认）清空 openai/deepseek/tavily key（clone 后改，不动原设置）；导入应用设置时备份 key 为空则**保留本地已配置的 key**（防止脱敏备份清掉自己的 key）。
- **导入策略（决策）**：照源项目 BackupService 的**覆盖式恢复** —— 单事务里清四张表再整批写回（任一步失败整体回滚）；manifest 缺失/zip 非法/版本过新抛 `FormatException`，**不动现有数据**。账号 hash 不一致允许导入但带告警。外键修复照源项目：会话引用了备份中不存在的助手 → 置空回落「无助手」+ 告警。
- **不强求重启** → `BackupService.restoreTick`（ValueNotifier）：导入成功后 +1，`ConversationListPage` / `WonderfulPage`（keepAlive 常驻页）监听它重新加载，替代源项目的 restore 后重启。
- **UI** → `pages/backup_restore_page.dart`：「包含 API Key」开关 + 导出（`FilePicker.saveFile`，移动端插件代写 bytes、桌面端按返回路径自写）+ 导入（`pickFiles` withData + 覆盖确认对话框 + 结果统计/告警对话框）。入口「我的 → 备份与恢复」。OHOS 暂不支持 file_picker，两个按钮给「敬请期待」提示（与附件入口同口径）。
- **新依赖**：`chatgpt_app_core` 加 `archive: ^4.0.9`。

**验收逐条**：导出 zip 含 manifest + 各表 + 设置 ✅；导入完整恢复（blocks、assistantId 绑定、原始 id 均保留）✅；覆盖式（旧数据清空）✅；脱敏与 key 保留 ✅；非法输入不破坏现有数据 ✅（均有测试）。

**测试**：`test/backup_test.dart`（6：round-trip 4 + 外键修复/非法输入 2）。`chatgpt_app_core` **118 个测试全部通过**、analyze 0 errors；`chatgpt_flutter` 壳层全图 analyze 无 issue、widget 测试通过。

**已知限制（遗留项）**：
1. zip 在内存中组装/解析（非流式写盘）——数据量极大（数万条消息）时峰值内存偏高；`archive` 包支持流式接口，需要时再换。
2. OHOS 端 file_picker 无实现，备份/恢复按钮仅提示；待插件支持或改用平台自带文件选择。
3. 备份不含聊天附件原始文件（图片 base64 已在消息行内随行导出；本地文件路径恢复到新设备后可能失效，FileBlock 仅展示元信息）。

---

## 9. 推荐依赖（pubspec）

```yaml
dependencies:
  flutter_riverpod: ^2.5.0
  drift: ^2.x            # 或 sqflite
  dio: ^5.x              # 网络 + SSE 流
  uuid: ^4.x
  file_picker: ^8.x
  image_picker: ^1.x
  syncfusion_flutter_pdf: ^26.x
  gal: ^2.x
  flutter_markdown: ^0.7.x   # 或你现有的 markdown 渲染
dev_dependencies:
  freezed: ^2.x          # 可选：自动生成 union/copyWith
  build_runner: ^2.x
```

---

## 10. 一句话总结

> 先把"消息=有序块列表 + 规范化块仓库 + 流式分发"这套地基（阶段一）做扎实，
> 再叠加思考展示、多 Provider、文件/图片、智能搜索、工具调用。
> 地基对了，后面每个功能都只是"多一种块 + 多一种流事件"。
