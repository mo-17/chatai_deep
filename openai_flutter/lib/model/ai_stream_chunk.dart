/// SSE 流式增量的类型化片段。
///
/// 旧的 [AIHttp.postStream] 把 `delta.content` 和 `delta.reasoning_content`
/// 都当普通字符串混在一个 `Stream<String>` 里 yield —— 调用方无法区分
/// 「正文」和「思考」。本类型把两者分开，让上层能分别落到 mainText / thinking 块。
enum AIStreamKind {
  /// 正文增量（`delta.content`）
  content,

  /// 推理/思考增量（`delta.reasoning_content`，DeepSeek-R1 等推理模型）
  reasoning,

  /// 工具调用增量（`delta.tool_calls`，阶段六）。
  /// 注意是「分片」：同一次调用的 id/name 先到、arguments 按 JSON 字符串
  /// 分片陆续到达，需按 [toolIndex] 累积（见上层 ToolCallAccumulator）。
  toolCall,
}

class AIStreamChunk {
  final AIStreamKind kind;
  final String text;

  /// 工具调用分片字段（kind == toolCall 时有效）。
  /// [toolIndex] 是同一条回复里多个并行调用的槽位，累积 arguments 用。
  final int? toolIndex;
  final String? toolId;
  final String? toolName;
  final String? toolArgsDelta;

  const AIStreamChunk(this.kind, this.text)
      : toolIndex = null,
        toolId = null,
        toolName = null,
        toolArgsDelta = null;

  const AIStreamChunk.content(this.text)
      : kind = AIStreamKind.content,
        toolIndex = null,
        toolId = null,
        toolName = null,
        toolArgsDelta = null;

  const AIStreamChunk.reasoning(this.text)
      : kind = AIStreamKind.reasoning,
        toolIndex = null,
        toolId = null,
        toolName = null,
        toolArgsDelta = null;

  const AIStreamChunk.toolCall({
    required this.toolIndex,
    this.toolId,
    this.toolName,
    this.toolArgsDelta,
  })  : kind = AIStreamKind.toolCall,
        text = '';
}
