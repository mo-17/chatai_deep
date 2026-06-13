/// 模型能力标志。对应源项目 `prepareParams/modelCapabilities.ts` 的
/// 「能力探测(capabilities)」——把「这个模型能不能发图片 / PDF / 调工具 /
/// 输出思考」收敛成一组布尔位，用来驱动 UI 入口开关与请求构造的差异化逻辑。
///
/// 关键意义（阶段三地基）：上层（UI / 分发层）只问 capabilities，不关心
/// 具体是 OpenAI / DeepSeek / Anthropic。切换模型或厂商时，只要 capabilities
/// 算对，图片 / PDF / 工具入口就自动跟着开关，无需改 UI 与 StreamDispatcher。
///
/// 纯 Dart、无 Flutter / 网络依赖，便于单测。数据源（远程清单的 supportsVision
/// 等）在 [ModelCatalog.capabilitiesFor] 里与本启发式合并。
class ModelCapabilities {
  /// 能否把图片当多模态输入发（vision）。
  final bool image;

  /// 能否原生发 PDF（否则阶段四降级为「抽文本拼进 prompt」）。
  final bool pdf;

  /// 能否启用工具调用 / 函数调用（阶段五联网搜索、阶段六工具调用的前提）。
  final bool tool;

  /// 会不会输出推理 / 思考过程（驱动思考块展示；阶段二已接 reasoning 流）。
  final bool reasoning;

  /// 是否支持大文件上传（File API），用于阶段四超限 PDF 的上传降级路径。
  final bool largeFileUpload;

  /// 按文件类型（如 'pdf' / 'image'）的字节上限映射；null / 缺省 = 未知 / 不限制。
  /// 用纯数据（而非闭包）建模，保持 const 可构造、可比较；阶段四接入文件时填充。
  final Map<String, int>? fileSizeLimits;

  const ModelCapabilities({
    this.image = false,
    this.pdf = false,
    this.tool = false,
    this.reasoning = false,
    this.largeFileUpload = false,
    this.fileSizeLimits,
  });

  /// 全部不支持（未知模型 / 兜底）。
  const ModelCapabilities.none() : this();

  /// 查某文件类型的字节上限，未配置返回 null。
  int? fileSizeLimitFor(String fileType) => fileSizeLimits?[fileType];

  ModelCapabilities copyWith({
    bool? image,
    bool? pdf,
    bool? tool,
    bool? reasoning,
    bool? largeFileUpload,
    Map<String, int>? fileSizeLimits,
  }) =>
      ModelCapabilities(
        image: image ?? this.image,
        pdf: pdf ?? this.pdf,
        tool: tool ?? this.tool,
        reasoning: reasoning ?? this.reasoning,
        largeFileUpload: largeFileUpload ?? this.largeFileUpload,
        fileSizeLimits: fileSizeLimits ?? this.fileSizeLimits,
      );

  /// 按 modelId 前缀 + providerCode 查表得到「基线」能力。
  ///
  /// 这是启发式**下限**：后端 catalog 现已下发 image/tool/reasoning/pdf 四个能力位
  /// （见 `ModelCatalog.capabilitiesFor` 的加法覆盖），但仅能往上「加位」；
  /// 本启发式负责未标注 / 本地直连模型的兜底基线。
  /// 不在表里的模型一律返回保守的 [ModelCapabilities.none]（String 直传上游，
  /// 不会被拒绝，只是相关入口默认关闭）。
  factory ModelCapabilities.heuristic(String modelId, {String? providerCode}) {
    final id = modelId.toLowerCase().trim();
    final code = (providerCode ?? '').toLowerCase().trim();

    // Anthropic Claude：多模态 + 工具 + 原生 PDF（上限 32MB）；3.7 / 4 系带扩展思考。
    if (id.startsWith('claude') || code == 'anthropic') {
      return ModelCapabilities(
        image: true,
        pdf: true,
        tool: true,
        largeFileUpload: true,
        fileSizeLimits: const {'pdf': 32 * 1024 * 1024},
        reasoning: id.contains('claude-3-7') ||
            id.contains('claude-3.7') ||
            id.contains('sonnet-4') ||
            id.contains('opus-4') ||
            id.contains('haiku-4') ||
            id.contains('claude-4'),
      );
    }

    // Google Gemini：多模态 + 工具 + PDF（内联上限约 50MB）；2.5 / thinking 系带思考。
    if (id.startsWith('gemini') || code == 'google' || code == 'gemini') {
      return ModelCapabilities(
        image: true,
        pdf: true,
        tool: true,
        largeFileUpload: true,
        fileSizeLimits: const {'pdf': 50 * 1024 * 1024},
        reasoning: id.contains('2.5') || id.contains('thinking'),
      );
    }

    // OpenAI o 系列（o1 / o3 / o4）：推理模型。vision 与工具需分别判断，
    // 不能用单一「mini」标志（否则 o3-mini / o4-mini 会被误判）：
    // - o1-mini：既无 vision 也无工具；
    // - o3-mini：支持工具，但无 vision（纯文本推理）；
    // - o1 / o3 / o4 / o4-mini：vision + 工具都支持。
    if (id.startsWith('o1') || id.startsWith('o3') || id.startsWith('o4')) {
      final noVision = id.startsWith('o1-mini') || id.startsWith('o3-mini');
      final noTool = id.startsWith('o1-mini');
      return ModelCapabilities(
        reasoning: true,
        tool: !noTool,
        image: !noVision,
      );
    }

    // OpenAI 多模态主力（gpt-4o / 4.1）：图片 + 工具 + 原生 PDF
    // （Chat Completions 的 file content part，单文件上限 32MB）。
    if (id.startsWith('gpt-4o') ||
        id.startsWith('chatgpt-4o') ||
        id.startsWith('gpt-4.1')) {
      return const ModelCapabilities(
        image: true,
        tool: true,
        pdf: true,
        fileSizeLimits: {'pdf': 32 * 1024 * 1024},
      );
    }

    // 上一代 OpenAI vision（gpt-4-turbo / 4-vision）：图片 + 工具，无原生 PDF。
    if (id.startsWith('gpt-4-turbo') || id.startsWith('gpt-4-vision')) {
      return const ModelCapabilities(image: true, tool: true);
    }

    // 其余 GPT（gpt-4 / gpt-3.5）：支持工具，无 vision。
    if (id.startsWith('gpt-4') || id.startsWith('gpt-3.5')) {
      return const ModelCapabilities(tool: true);
    }

    // DeepSeek-R1 推理模型（deepseek-reasoner / *-r1）：输出思考，暂不支持工具 / vision。
    if (id.contains('reasoner') || id.contains('-r1') || id.endsWith('r1')) {
      return const ModelCapabilities(reasoning: true);
    }

    // DeepSeek-V3 对话模型：支持工具。
    if (id.startsWith('deepseek') || code == 'deepseek') {
      return const ModelCapabilities(tool: true);
    }

    return const ModelCapabilities.none();
  }

  /// 纯数据值相等：供「ChatService.from(s).capabilities ==
  /// ChatService.capabilitiesFor(s)」这类同源校验直接断言。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelCapabilities &&
          image == other.image &&
          pdf == other.pdf &&
          tool == other.tool &&
          reasoning == other.reasoning &&
          largeFileUpload == other.largeFileUpload &&
          _mapEquals(fileSizeLimits, other.fileSizeLimits);

  @override
  int get hashCode => Object.hash(image, pdf, tool, reasoning, largeFileUpload,
      fileSizeLimits?.length ?? -1);

  static bool _mapEquals(Map<String, int>? a, Map<String, int>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'ModelCapabilities(image: $image, pdf: $pdf, tool: $tool, '
      'reasoning: $reasoning, largeFileUpload: $largeFileUpload)';
}
