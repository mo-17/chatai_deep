/// 服务商 / 模型数据模型（迁移自 Cherry Studio 的 `Provider` / `Model`）。
///
/// 源项目把「服务商」建模成一个**可增删的列表**：每家有 id / type / name /
/// apiKey / apiHost / models[] / enabled，而不是我们旧版写死的 openai+deepseek
/// 两家。本文件把这套灵活结构落到 Dart，并补上「派生完整 completions URL」
/// 「派生能力探测 providerCode」等本项目聊天链路需要的桥接逻辑。
///
/// 传输约束：本项目 [DirectChatService] 只会发 OpenAI 兼容的
/// `/chat/completions` 请求，故预设目录里收录的都是 OpenAI 兼容服务商
/// （type 多为 'openai'）。type 字段保留 Cherry 的取值仅用于能力探测与展示，
/// 暂不接 anthropic / gemini 原生协议（那需要移植源项目的 aiCore 多 SDK 层）。
library;

/// 单个模型的能力位（仅用于详情页展示能力标签；真正的能力探测仍由
/// [ModelCapabilities.heuristic] 按 modelId 前缀 + providerCode 推导，
/// 见 model_capabilities.dart）。
class AiModel {
  String id;
  String name;

  /// 分组名（如 'GPT-4o' / 'Reasoning'），UI 分组展示用，可空。
  String group;

  String? description;

  // 能力标签（详情页展示用，默认 false）
  bool vision;
  bool reasoning;
  bool tool;
  bool web;

  /// 最近一次连通性测试结果。null/unknown = 未测试或配置变更后已过期。
  int? lastTestAt;
  String lastTestStatus;
  String? lastTestError;

  /// 最近一次被用户选为当前模型的时间。用于会话模型选择器优先展示常用模型。
  int? lastUsedAt;

  AiModel({
    required this.id,
    String? name,
    this.group = '',
    this.description,
    this.vision = false,
    this.reasoning = false,
    this.tool = false,
    this.web = false,
    this.lastTestAt,
    this.lastTestStatus = 'unknown',
    this.lastTestError,
    this.lastUsedAt,
  }) : name = (name == null || name.isEmpty) ? id : name;

  factory AiModel.fromJson(Map<String, dynamic> j) => AiModel(
        id: j['id'] as String? ?? '',
        name: j['name'] as String?,
        group: j['group'] as String? ?? '',
        description: j['description'] as String?,
        vision: j['vision'] as bool? ?? false,
        reasoning: j['reasoning'] as bool? ?? false,
        tool: j['tool'] as bool? ?? false,
        web: j['web'] as bool? ?? false,
        lastTestAt: j['lastTestAt'] as int?,
        lastTestStatus: j['lastTestStatus'] as String? ?? 'unknown',
        lastTestError: j['lastTestError'] as String?,
        lastUsedAt: j['lastUsedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        if (description != null) 'description': description,
        'vision': vision,
        'reasoning': reasoning,
        'tool': tool,
        'web': web,
        if (lastTestAt != null) 'lastTestAt': lastTestAt,
        'lastTestStatus': lastTestStatus,
        if (lastTestError != null) 'lastTestError': lastTestError,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
      };

  AiModel copy() => AiModel.fromJson(toJson());

  /// 是否带任意能力标签（决定详情页是否渲染标签行）。
  bool get hasAnyCapability => vision || reasoning || tool || web;

  void markTestResult({required bool success, String? error}) {
    lastTestAt = DateTime.now().millisecondsSinceEpoch;
    lastTestStatus = success ? 'success' : 'failure';
    lastTestError = success ? null : error;
  }

  void clearTestResult() {
    lastTestAt = null;
    lastTestStatus = 'unknown';
    lastTestError = null;
  }

  void markUsed() {
    lastUsedAt = DateTime.now().millisecondsSinceEpoch;
  }

  void applyCapabilityHints({
    bool vision = false,
    bool reasoning = false,
    bool tool = false,
    bool web = false,
  }) {
    this.vision = this.vision || vision;
    this.reasoning = this.reasoning || reasoning;
    this.tool = this.tool || tool;
    this.web = this.web || web;
  }
}

class AiProvider {
  /// 唯一 id：预设用固定字符串（'openai' / 'deepseek' …），自定义用 'custom_<时间戳>'。
  final String id;

  /// 协议类型（Cherry 取值：openai / anthropic / gemini / azure-openai …）。
  /// 本项目当前仅按 OpenAI 兼容方式调用，type 主要用于能力探测与展示。
  String type;

  String name;
  String apiKey;

  /// API 主机（Cherry 语义：基础地址，不含 `/chat/completions`）。
  /// 完整 completions URL 由 [chatCompletionsUrl] 派生。
  String apiHost;

  List<AiModel> models;

  /// 当前选中的模型 id（空则取 models 首个）。
  String selectedModelId;

  /// 是否启用（列表页开关；只有启用的才会出现在「可切换服务商」里）。
  bool enabled;

  /// 是否系统预设（预设不可删除，但可改 key/host/模型、可禁用）。
  final bool isSystem;

  AiProvider({
    required this.id,
    required this.type,
    required this.name,
    this.apiKey = '',
    this.apiHost = '',
    List<AiModel>? models,
    this.selectedModelId = '',
    this.enabled = false,
    this.isSystem = false,
  }) : models = models ?? [];

  factory AiProvider.fromJson(Map<String, dynamic> j) => AiProvider(
        id: j['id'] as String? ?? '',
        type: j['type'] as String? ?? 'openai',
        name: j['name'] as String? ?? '',
        apiKey: j['apiKey'] as String? ?? '',
        apiHost: j['apiHost'] as String? ?? '',
        models: (j['models'] as List?)
                ?.map((e) => AiModel.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        selectedModelId: j['selectedModelId'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? false,
        isSystem: j['isSystem'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'apiKey': apiKey,
        'apiHost': apiHost,
        'models': models.map((m) => m.toJson()).toList(),
        'selectedModelId': selectedModelId,
        'enabled': enabled,
        'isSystem': isSystem,
      };

  AiProvider copy() => AiProvider.fromJson(toJson());

  /// 显式引用失效时仍保留；仅真正未选择且唯一的配置可以兼容。
  String get effectiveModelId {
    if (selectedModelId.isNotEmpty) return selectedModelId;
    return models.length == 1 ? models.single.id : '';
  }

  /// 能力探测用的 providerCode（对照 [ModelCapabilities.heuristic] 关注的取值）。
  /// 聚合类服务商（openrouter / 硅基流动等）统一归 'openai'，
  /// 由 modelId 前缀（claude-/gemini-/deepseek-）兜住厂商差异。
  String get providerCode {
    switch (type) {
      case 'anthropic':
        return 'anthropic';
      case 'gemini':
        return 'gemini';
    }
    if (id == 'deepseek') return 'deepseek';
    return 'openai';
  }

  /// 由 [apiHost] 派生完整的 OpenAI 兼容 completions URL，供 DirectChatService 用。
  ///
  /// 规则（兼容用户自定义与各家路径差异）：
  /// - 已含 `/chat/completions`：原样使用（用户填了完整端点）。
  /// - 末尾 `#`：去掉 `#` 后直接拼 `chat/completions`，不再补版本段
  ///   （沿用 Cherry「强制用这个地址」的约定）。
  /// - 已含版本段（/v1 /v2 /v3 /v4 /…）或以 `/api` 结尾：补 `/chat/completions`。
  /// - 其余（裸主机）：补 `/v1/chat/completions`。
  String get chatCompletionsUrl => buildChatCompletionsUrl(apiHost);

  static String buildChatCompletionsUrl(String host) {
    var h = host.trim();
    if (h.isEmpty) return h;
    if (h.contains('/chat/completions')) return h;
    if (h.endsWith('#')) {
      final base = h.substring(0, h.length - 1).replaceAll(RegExp(r'/+$'), '');
      return '$base/chat/completions';
    }
    h = h.replaceAll(RegExp(r'/+$'), '');
    if (RegExp(r'/v\d+(/|$)').hasMatch(h) || h.endsWith('/api')) {
      return '$h/chat/completions';
    }
    return '$h/v1/chat/completions';
  }
}
