import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';

/// 块化消息系统的核心领域模型。
///
/// 忠实迁移自 Cherry Studio（`src/types/message.ts`）：
/// 一条 assistant 消息不是一段纯文本，而是「有序的块(Block)列表」。
/// 块用 Dart 3 `sealed class` 表达判别联合类型(discriminated union)，
/// 配合 `switch` 做穷尽匹配（见 `chat/ui/block_message_content.dart`）。
///
/// 设计要点（对照源项目）：
/// - 规范化存储：消息只持有 blockId 的有序列表，块对象单独存在
///   [ChatBlockStore] 里，按 id 引用 —— 流式高频更新单个块时不必重建整条消息。
/// - 每个块有自己的状态机：pending → processing → streaming → success/error/paused。

/// 块状态机。直译自源项目 `MessageBlockStatus`。
enum MessageBlockStatus {
  pending, // 等待处理
  processing, // 处理中（占位块创建后、收到首个事件前）
  streaming, // 正在接收增量
  success, // 完成
  error, // 出错
  paused, // 暂停（用户主动停止）
}

/// 块类型判别字段。直译自源项目 `MessageBlockType`。
enum MessageBlockType {
  unknown, // 占位块：流式开始前先建，收到首个事件后「变身」成真实块
  mainText, // 主文本
  thinking, // 推理过程
  translation, // 翻译
  code, // 代码块
  image, // 图片（用户上传 / 模型生成）
  tool, // 工具调用
  citation, // 引用（网络搜索 / 知识库 grounding）
  file, // 文件
  roleContext, // 角色上下文快照（调试/追溯用）
  roleContinuation, // 未完成回复的角色状态承接
  error, // 错误
}

MessageBlockStatus _statusFromName(String? name) {
  return MessageBlockStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => MessageBlockStatus.success,
  );
}

/// 所有块的基类。`sealed` 让 UI 层 `switch` 能穷尽匹配每种块。
sealed class MessageBlock {
  final String id;

  /// 所属消息的稳定 key（见 [ChatBlockStore]）。
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

  MessageBlockType get type;

  /// 该块是否处于「活跃中」（占位/处理/流式），用于推导消息整体状态。
  bool get isActive =>
      status == MessageBlockStatus.pending ||
      status == MessageBlockStatus.processing ||
      status == MessageBlockStatus.streaming;

  Map<String, dynamic> _baseJson() => {
        'type': type.name,
        'id': id,
        'messageId': messageId,
        'createdAt': createdAt,
        if (updatedAt != null) 'updatedAt': updatedAt,
        'status': status.name,
        if (modelId != null) 'modelId': modelId,
      };

  Map<String, dynamic> toJson();

  /// 按 `type` 字段反序列化成具体块。未知类型降级为 [PlaceholderBlock]。
  static MessageBlock fromJson(Map<String, dynamic> j) {
    final type = MessageBlockType.values.firstWhere(
      (t) => t.name == j['type'],
      orElse: () => MessageBlockType.unknown,
    );
    final id = j['id'] as String;
    final messageId = j['messageId'] as String? ?? '';
    final createdAt = j['createdAt'] as int? ?? 0;
    final updatedAt = j['updatedAt'] as int?;
    final status = _statusFromName(j['status'] as String?);
    final modelId = j['modelId'] as String?;
    switch (type) {
      case MessageBlockType.mainText:
        return MainTextBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          content: j['content'] as String? ?? '',
          protocolMessages: [
            for (final m in (j['protocolMessages'] as List? ?? const []))
              (m as Map).cast<String, dynamic>()
          ],
        );
      case MessageBlockType.thinking:
        return ThinkingBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          content: j['content'] as String? ?? '',
          thinkingMillsec: j['thinkingMillsec'] as int? ?? 0,
        );
      case MessageBlockType.code:
        return CodeBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          content: j['content'] as String? ?? '',
          language: j['language'] as String? ?? '',
        );
      case MessageBlockType.image:
        return ImageBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          url: j['url'] as String?,
          filePath: j['filePath'] as String?,
          prompt: j['prompt'] as String?,
        );
      case MessageBlockType.tool:
        return ToolBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          toolId: j['toolId'] as String? ?? '',
          toolName: j['toolName'] as String?,
          arguments: (j['arguments'] as Map?)?.cast<String, dynamic>(),
          content: j['content'],
        );
      case MessageBlockType.citation:
        final raw = (j['webResults'] as List?) ?? const [];
        return CitationBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          webResults: raw
              .map((e) =>
                  WebSearchResult.fromJson((e as Map).cast<String, dynamic>()))
              .toList(),
          localSources: [
            for (final item in (j['localSources'] is List
                ? j['localSources'] as List
                : const []))
              if (LocalSourceCitation.tryFromJson(item) case final source?)
                source,
          ],
        );
      case MessageBlockType.file:
        return FileBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          file: FileMetadata.fromJson(
              ((j['file'] as Map?) ?? const {}).cast<String, dynamic>()),
        );
      case MessageBlockType.roleContext:
        final rawMemoryBudget = j['memoryBudget'];
        final rawMemoryHits = j['memoryHits'];
        return RoleContextBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          content: j['content'] as String? ?? '',
          memoryBudget: rawMemoryBudget is Map
              ? AssistantMemoryContextBudget.fromJson(
                  rawMemoryBudget.cast<String, dynamic>(),
                )
              : null,
          memoryHits: [
            for (final item in (rawMemoryHits as List? ?? const []))
              if (item is Map)
                AssistantMemoryEntryPreview.fromJson(
                  item.cast<String, dynamic>(),
                ),
          ],
        );
      case MessageBlockType.roleContinuation:
        return RoleContinuationBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          content: j['content'] as String? ?? '',
        );
      case MessageBlockType.error:
        return ErrorBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          message: j['message'] as String? ?? '',
        );
      case MessageBlockType.translation:
        return TranslationBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: status,
          modelId: modelId,
          content: j['content'] as String? ?? '',
          sourceBlockId: j['sourceBlockId'] as String?,
        );
      case MessageBlockType.unknown:
        // 从持久化恢复的占位块（或更新版本写入的未知类型）一律视为已完成 —
        // 历史不可能处于流式中，避免重启后渲染出永不消失的加载圈。
        return PlaceholderBlock(
          id: id,
          messageId: messageId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          status: MessageBlockStatus.success,
        );
    }
  }

  /// 序列化一条消息的块列表为 JSON 字符串（落库用）。
  static String encodeList(List<MessageBlock> blocks) =>
      jsonEncode(blocks.map((b) => b.toJson()).toList());

  /// 反序列化块列表。解析失败返回空列表（容错，不抛）。
  static List<MessageBlock> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => MessageBlock.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// 占位块：流式开始前先创建，收到首个事件后「变身」为真实块。
class PlaceholderBlock extends MessageBlock {
  const PlaceholderBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
  });

  @override
  MessageBlockType get type => MessageBlockType.unknown;

  @override
  Map<String, dynamic> toJson() => _baseJson();
}

class MainTextBlock extends MessageBlock {
  final String content;

  /// 精确工具轮次及推理协议历史，独立于显示文本；旧块缺省为空。
  final List<Map<String, dynamic>> protocolMessages;

  const MainTextBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.content = '',
    this.protocolMessages = const [],
  });

  @override
  MessageBlockType get type => MessageBlockType.mainText;

  MainTextBlock copyWith({
    String? content,
    MessageBlockStatus? status,
    int? updatedAt,
    List<Map<String, dynamic>>? protocolMessages,
  }) =>
      MainTextBlock(
        id: id,
        messageId: messageId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        modelId: modelId,
        status: status ?? this.status,
        content: content ?? this.content,
        protocolMessages: protocolMessages ?? this.protocolMessages,
      );

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['content'] = content
    ..addAll(protocolMessages.isEmpty
        ? const {}
        : {'protocolMessages': protocolMessages});
}

class ThinkingBlock extends MessageBlock {
  final String content;

  /// 思考耗时（毫秒）。流式中按 now-start 实时更新，complete 时落最终值。
  final int thinkingMillsec;

  const ThinkingBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.content = '',
    this.thinkingMillsec = 0,
  });

  @override
  MessageBlockType get type => MessageBlockType.thinking;

  ThinkingBlock copyWith({
    String? content,
    MessageBlockStatus? status,
    int? thinkingMillsec,
    int? updatedAt,
  }) =>
      ThinkingBlock(
        id: id,
        messageId: messageId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        modelId: modelId,
        status: status ?? this.status,
        content: content ?? this.content,
        thinkingMillsec: thinkingMillsec ?? this.thinkingMillsec,
      );

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['content'] = content
    ..['thinkingMillsec'] = thinkingMillsec;
}

class TranslationBlock extends MessageBlock {
  final String content;
  final String? sourceBlockId;

  const TranslationBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.content = '',
    this.sourceBlockId,
  });

  @override
  MessageBlockType get type => MessageBlockType.translation;

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['content'] = content
    ..['sourceBlockId'] = sourceBlockId;
}

class CodeBlock extends MessageBlock {
  final String content;
  final String language;

  const CodeBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.content = '',
    this.language = '',
  });

  @override
  MessageBlockType get type => MessageBlockType.code;

  CodeBlock copyWith({
    String? content,
    String? language,
    MessageBlockStatus? status,
  }) =>
      CodeBlock(
        id: id,
        messageId: messageId,
        createdAt: createdAt,
        updatedAt: updatedAt,
        modelId: modelId,
        status: status ?? this.status,
        content: content ?? this.content,
        language: language ?? this.language,
      );

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['content'] = content
    ..['language'] = language;
}

class ImageBlock extends MessageBlock {
  final String? url; // 模型生成或直链
  final String? filePath; // 用户上传本地图片
  final String? prompt;

  const ImageBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.url,
    this.filePath,
    this.prompt,
  });

  @override
  MessageBlockType get type => MessageBlockType.image;

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['url'] = url
    ..['filePath'] = filePath
    ..['prompt'] = prompt;
}

class ToolBlock extends MessageBlock {
  final String toolId;
  final String? toolName;
  final Map<String, dynamic>? arguments;
  final Object? content; // 工具返回（string 或 json）

  const ToolBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    required this.toolId,
    this.toolName,
    this.arguments,
    this.content,
  });

  @override
  MessageBlockType get type => MessageBlockType.tool;

  ToolBlock copyWith({
    MessageBlockStatus? status,
    Object? content,
    Map<String, dynamic>? arguments,
  }) =>
      ToolBlock(
        id: id,
        messageId: messageId,
        createdAt: createdAt,
        updatedAt: updatedAt,
        modelId: modelId,
        status: status ?? this.status,
        toolId: toolId,
        toolName: toolName,
        arguments: arguments ?? this.arguments,
        content: content ?? this.content,
      );

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['toolId'] = toolId
    ..['toolName'] = toolName
    ..['arguments'] = arguments
    ..['content'] = content;
}

class CitationBlock extends MessageBlock {
  final List<WebSearchResult> webResults;
  final List<LocalSourceCitation> localSources;

  const CitationBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.webResults = const [],
    this.localSources = const [],
  });

  @override
  MessageBlockType get type => MessageBlockType.citation;

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['webResults'] = webResults.map((e) => e.toJson()).toList()
    ..['localSources'] = localSources.map((e) => e.toJson()).toList();
}

class FileBlock extends MessageBlock {
  final FileMetadata file;

  const FileBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    required this.file,
  });

  @override
  MessageBlockType get type => MessageBlockType.file;

  @override
  Map<String, dynamic> toJson() => _baseJson()..['file'] = file.toJson();
}

class RoleContextBlock extends MessageBlock {
  final String content;
  final AssistantMemoryContextBudget? memoryBudget;
  final List<AssistantMemoryEntryPreview> memoryHits;

  const RoleContextBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.content = '',
    this.memoryBudget,
    this.memoryHits = const [],
  });

  @override
  MessageBlockType get type => MessageBlockType.roleContext;

  @override
  Map<String, dynamic> toJson() => _baseJson()
    ..['content'] = content
    ..['memoryBudget'] = memoryBudget?.toJson()
    ..['memoryHits'] = memoryHits.map((hit) => hit.toJson()).toList();
}

class RoleContinuationBlock extends MessageBlock {
  final String content;

  const RoleContinuationBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.content = '',
  });

  @override
  MessageBlockType get type => MessageBlockType.roleContinuation;

  @override
  Map<String, dynamic> toJson() => _baseJson()..['content'] = content;
}

class ErrorBlock extends MessageBlock {
  final String message;

  const ErrorBlock({
    required super.id,
    required super.messageId,
    required super.createdAt,
    required super.status,
    super.updatedAt,
    super.modelId,
    this.message = '',
  });

  @override
  MessageBlockType get type => MessageBlockType.error;

  @override
  Map<String, dynamic> toJson() => _baseJson()..['message'] = message;
}

/// 引用某个 citation 块的轻量引用（主文本块里嵌的来源标记）。
class CitationRef {
  final String citationBlockId;
  const CitationRef(this.citationBlockId);
}

/// 网络搜索结果（阶段五用）。
class WebSearchResult {
  final String title;
  final String url;
  final String content;

  const WebSearchResult({
    this.title = '',
    this.url = '',
    this.content = '',
  });

  factory WebSearchResult.fromJson(Map<String, dynamic> j) => WebSearchResult(
        title: j['title'] as String? ?? '',
        url: j['url'] as String? ?? '',
        content: j['content'] as String? ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'content': content};
}

/// 文件元数据（阶段四用）。
class FileMetadata {
  final String name;
  final String? path;
  final String? mime;
  final int? size;

  /// 降级路径抽取并已包裹好的文件文本（遗留项 6）。随 FileBlock 落库，
  /// 供 [CompletionDao.buildHistory] 把附件文本跨轮重建进历史（重开会话亦可恢复）。
  /// 原生直发（如 PDF base64）或不可解析类型为 null。
  final String? extractedText;

  /// 按需阅读的工作区文件引用。旧附件没有此字段，继续使用原来的文本路径。
  final int? workspaceFileId;

  const FileMetadata({
    this.name = '',
    this.path,
    this.mime,
    this.size,
    this.extractedText,
    this.workspaceFileId,
  });

  factory FileMetadata.fromJson(Map<String, dynamic> j) => FileMetadata(
        name: j['name'] as String? ?? '',
        path: j['path'] as String?,
        mime: j['mime'] as String?,
        size: j['size'] as int?,
        extractedText: j['extractedText'] as String?,
        workspaceFileId: j['workspaceFileId'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'mime': mime,
        'size': size,
        // 仅在有文本时写入，避免给原生/图片类附件徒增空字段。
        if (extractedText != null) 'extractedText': extractedText,
        if (workspaceFileId != null) 'workspaceFileId': workspaceFileId,
      };
}
