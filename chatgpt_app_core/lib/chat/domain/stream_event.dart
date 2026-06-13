import 'package:chatgpt_app_core/chat/domain/message_block.dart';

/// 统一的流式事件。对应源项目把流拆成
/// `onTextChunk / onThinkingChunk / onToolCall / ...` 的回调模型。
///
/// 关键作用：把不同 provider 的 SSE 差异（OpenAI 的 `delta.content`、
/// DeepSeek-R1 的 `delta.reasoning_content`、Anthropic 的 reasoning 等）
/// 全部收敛到 provider 适配层，对上只暴露这一种带类型的事件。
/// 这样「思考」和「正文」从源头就被分开，正文用于历史上下文，
/// 思考只在客户端展示、不会被重新发回模型（避免污染上下文）。
enum StreamEventType {
  /// 正文增量（mainText 块）
  text,

  /// 推理/思考增量（thinking 块）
  reasoning,

  /// 工具调用（阶段六）
  toolCall,

  /// 工具结果（阶段六）
  toolResult,

  /// 图片（阶段四：模型生成图片）
  image,

  /// 引用来源（阶段五：联网搜索 grounding）
  citation,
}

class StreamEvent {
  final StreamEventType type;

  /// 文本类事件（text / reasoning）的增量内容。
  final String delta;

  /// 工具调用相关字段（阶段六接入时使用）。
  final String? toolId;
  final String? toolName;
  final Map<String, dynamic>? toolArguments;
  final Object? toolContent;

  /// 图片事件（阶段四）：模型生成图片的 url 或 data URI。
  final String? imageUrl;

  /// 引用事件（阶段五）：联网搜索的来源列表。
  final List<WebSearchResult>? webResults;

  const StreamEvent._(
    this.type, {
    this.delta = '',
    this.toolId,
    this.toolName,
    this.toolArguments,
    this.toolContent,
    this.imageUrl,
    this.webResults,
  });

  factory StreamEvent.text(String delta) =>
      StreamEvent._(StreamEventType.text, delta: delta);

  factory StreamEvent.reasoning(String delta) =>
      StreamEvent._(StreamEventType.reasoning, delta: delta);

  factory StreamEvent.toolCall({
    required String toolId,
    String? name,
    Map<String, dynamic>? arguments,
  }) =>
      StreamEvent._(
        StreamEventType.toolCall,
        toolId: toolId,
        toolName: name,
        toolArguments: arguments,
      );

  factory StreamEvent.toolResult({
    required String toolId,
    Object? content,
  }) =>
      StreamEvent._(
        StreamEventType.toolResult,
        toolId: toolId,
        toolContent: content,
      );

  /// 模型生成图片（阶段四）：[url] 为直链或 data URI，到达即完整、无增量。
  factory StreamEvent.image(String url) =>
      StreamEvent._(StreamEventType.image, imageUrl: url);

  /// 引用来源（阶段五）：联网搜索结果，到达即完整、无增量。
  factory StreamEvent.citation(List<WebSearchResult> results) =>
      StreamEvent._(StreamEventType.citation, webResults: results);
}
