import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/data/provider_presets.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';

enum AIMode { local, backend }

/// 「当前生效服务商」解析出的直连配置（DirectChatService 直接消费）。
/// 由 [AISettings.activeLocal] 从激活的 [AiProvider] 派生而来。
class ProviderConfig {
  String apiKey;
  String baseUrl;
  String model;

  ProviderConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });
}

class UsageCostRate {
  final double? cachedInputCostPer1K;
  final double inputCostPer1K;
  final double outputCostPer1K;

  const UsageCostRate({
    this.cachedInputCostPer1K,
    this.inputCostPer1K = 0,
    this.outputCostPer1K = 0,
  });

  double get effectiveCachedInputCostPer1K =>
      cachedInputCostPer1K ?? inputCostPer1K;

  bool get isZero =>
      effectiveCachedInputCostPer1K == 0 &&
      inputCostPer1K == 0 &&
      outputCostPer1K == 0;

  double costFor({
    required int promptTokens,
    int cachedPromptTokens = 0,
    required int completionTokens,
  }) {
    final cached = cachedPromptTokens.clamp(0, promptTokens).toInt();
    final uncached = promptTokens - cached;
    return cached / 1000000 * effectiveCachedInputCostPer1K +
        uncached / 1000000 * inputCostPer1K +
        completionTokens / 1000000 * outputCostPer1K;
  }

  factory UsageCostRate.fromJson(Map<String, dynamic>? j) => UsageCostRate(
        cachedInputCostPer1K: (j?['cachedInputCostPer1K'] as num?)?.toDouble(),
        inputCostPer1K: (j?['inputCostPer1K'] as num?)?.toDouble() ?? 0,
        outputCostPer1K: (j?['outputCostPer1K'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'cachedInputCostPer1K': cachedInputCostPer1K,
        'inputCostPer1K': inputCostPer1K,
        'outputCostPer1K': outputCostPer1K,
      };

  bool sameValue(UsageCostRate other) =>
      cachedInputCostPer1K == other.cachedInputCostPer1K &&
      inputCostPer1K == other.inputCostPer1K &&
      outputCostPer1K == other.outputCostPer1K;
}

class UsageCostTimeRule {
  final String key;
  final int startMinute;
  final int endMinute;
  final int timezoneOffsetMinutes;
  final UsageCostRate rate;

  const UsageCostTimeRule({
    required this.key,
    required this.startMinute,
    required this.endMinute,
    required this.rate,
    this.timezoneOffsetMinutes = 480,
  });

  bool matches({
    String? providerId,
    required String modelId,
    required DateTime at,
  }) {
    if (!_matchesKey(providerId: providerId, modelId: modelId)) return false;
    final local = at.toUtc().add(Duration(minutes: timezoneOffsetMinutes));
    final minute = local.hour * 60 + local.minute;
    if (startMinute == endMinute) return true;
    if (startMinute < endMinute) {
      return minute >= startMinute && minute < endMinute;
    }
    return minute >= startMinute || minute < endMinute;
  }

  bool _matchesKey({String? providerId, required String modelId}) {
    final provider = providerId?.trim();
    final model = modelId.trim();
    if (provider == null || provider.isEmpty) return false;
    return key == '$provider/$model' || key == '$provider/*';
  }

  factory UsageCostTimeRule.fromJson(Map<String, dynamic> j) =>
      UsageCostTimeRule(
        key: j['key'] as String? ?? '',
        startMinute: j['startMinute'] as int? ?? 0,
        endMinute: j['endMinute'] as int? ?? 0,
        timezoneOffsetMinutes: j['timezoneOffsetMinutes'] as int? ?? 480,
        rate: UsageCostRate.fromJson(
            (j['rate'] as Map?)?.cast<String, dynamic>()),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'startMinute': startMinute,
        'endMinute': endMinute,
        'timezoneOffsetMinutes': timezoneOffsetMinutes,
        'rate': rate.toJson(),
      };

  bool sameValue(UsageCostTimeRule other) =>
      key == other.key &&
      startMinute == other.startMinute &&
      endMinute == other.endMinute &&
      timezoneOffsetMinutes == other.timezoneOffsetMinutes &&
      rate.sameValue(other.rate);
}

class UsageCostConfig {
  final UsageCostRate defaultRate;
  final Map<String, UsageCostRate> overrides;
  final List<UsageCostTimeRule> timeRules;

  static const Map<String, UsageCostRate> builtinOverrides = {
    // DeepSeek V4 平时价格，单位：元 / 1M tokens。
    'deepseek/deepseek-v4-pro': UsageCostRate(
      cachedInputCostPer1K: 0.025,
      inputCostPer1K: 3,
      outputCostPer1K: 6,
    ),
    'deepseek/deepseek-v4-flash': UsageCostRate(
      cachedInputCostPer1K: 0.02,
      inputCostPer1K: 1,
      outputCostPer1K: 2,
    ),
  };

  static const List<UsageCostTimeRule> builtinTimeRules = [
    UsageCostTimeRule(
      key: 'deepseek/deepseek-v4-pro',
      startMinute: 9 * 60,
      endMinute: 12 * 60,
      rate: UsageCostRate(
        cachedInputCostPer1K: 0.05,
        inputCostPer1K: 6,
        outputCostPer1K: 12,
      ),
    ),
    UsageCostTimeRule(
      key: 'deepseek/deepseek-v4-pro',
      startMinute: 14 * 60,
      endMinute: 18 * 60,
      rate: UsageCostRate(
        cachedInputCostPer1K: 0.05,
        inputCostPer1K: 6,
        outputCostPer1K: 12,
      ),
    ),
    UsageCostTimeRule(
      key: 'deepseek/deepseek-v4-flash',
      startMinute: 9 * 60,
      endMinute: 12 * 60,
      rate: UsageCostRate(
        cachedInputCostPer1K: 0.04,
        inputCostPer1K: 2,
        outputCostPer1K: 4,
      ),
    ),
    UsageCostTimeRule(
      key: 'deepseek/deepseek-v4-flash',
      startMinute: 14 * 60,
      endMinute: 18 * 60,
      rate: UsageCostRate(
        cachedInputCostPer1K: 0.04,
        inputCostPer1K: 2,
        outputCostPer1K: 4,
      ),
    ),
  ];

  static const UsageCostConfig builtinDefaults =
      UsageCostConfig(overrides: builtinOverrides, timeRules: builtinTimeRules);

  const UsageCostConfig({
    this.defaultRate = const UsageCostRate(),
    this.overrides = const {},
    this.timeRules = const [],
  });

  const UsageCostConfig.zero() : this();

  UsageCostRate rateFor({
    String? providerId,
    required String modelId,
    DateTime? at,
  }) {
    final provider = providerId?.trim();
    final model = modelId.trim();
    if (provider != null && provider.isNotEmpty && model.isNotEmpty) {
      final exact = overrides['$provider/$model'];
      if (exact != null && !_isBuiltinOverride('$provider/$model', exact)) {
        return exact;
      }
    }
    if (provider != null && provider.isNotEmpty) {
      final providerRate = overrides['$provider/*'];
      if (providerRate != null &&
          !_isBuiltinOverride('$provider/*', providerRate)) {
        return providerRate;
      }
    }
    if (at != null) {
      for (final rule in timeRules) {
        if (rule.matches(providerId: providerId, modelId: modelId, at: at)) {
          return rule.rate;
        }
      }
    }
    if (provider != null && provider.isNotEmpty && model.isNotEmpty) {
      final exact = overrides['$provider/$model'];
      if (exact != null) return exact;
    }
    if (provider != null && provider.isNotEmpty) {
      final providerRate = overrides['$provider/*'];
      if (providerRate != null) return providerRate;
    }
    return defaultRate;
  }

  factory UsageCostConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return builtinDefaults;
    final rawOverrides = j['overrides'] as Map?;
    final rawTimeRules = j['timeRules'] as List?;
    final customOverrides = rawOverrides == null
        ? const <String, UsageCostRate>{}
        : rawOverrides.map((key, value) => MapEntry(
              '$key',
              UsageCostRate.fromJson((value as Map?)?.cast<String, dynamic>()),
            ));
    final customTimeRules = rawTimeRules
            ?.map((e) =>
                UsageCostTimeRule.fromJson((e as Map).cast<String, dynamic>()))
            .toList() ??
        const <UsageCostTimeRule>[];
    return UsageCostConfig(
      defaultRate: UsageCostRate.fromJson(
          (j['defaultRate'] as Map?)?.cast<String, dynamic>()),
      overrides: {
        ...builtinOverrides,
        ...customOverrides,
      },
      timeRules: [
        ...builtinTimeRules,
        ...customTimeRules,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'defaultRate': defaultRate.toJson(),
        'overrides': Map.fromEntries(overrides.entries
            .where((entry) => !_isBuiltinOverride(entry.key, entry.value))
            .map((entry) => MapEntry(entry.key, entry.value.toJson()))),
        'timeRules': timeRules
            .where((rule) => !_isBuiltinTimeRule(rule))
            .map((e) => e.toJson())
            .toList(),
      };

  static bool _isBuiltinOverride(String key, UsageCostRate rate) {
    final builtin = builtinOverrides[key];
    return builtin != null && builtin.sameValue(rate);
  }

  static bool _isBuiltinTimeRule(UsageCostTimeRule rule) =>
      builtinTimeRules.any((builtin) => builtin.sameValue(rule));
}

class AISettings {
  AIMode mode;

  /// 灵活的服务商列表（迁移自 Cherry Studio）。取代旧版写死的 openai+deepseek。
  List<AiProvider> providers;

  /// 当前激活的本地服务商 id（mode=local 时生效）。
  String activeProviderId;

  String backendModel;
  bool streamEnabled;
  bool resetOnLogout;

  /// 联网搜索（阶段五）：Tavily API Key（空 = 未配置）。
  String tavilyApiKey;

  /// 联网搜索用户开关。独立于模型能力位（caps.tool）——搜索结果以
  /// 上下文方式回填，任何模型都可用（与 Cherry Studio 一致）。
  bool webSearchEnabled;

  /// 当前联网搜索服务商 id：'tavily' | 'exa' | 'bocha' | 'zhipu'
  /// （与源项目 WebSearchProviderFactory 支持的 API 型服务商一致）。
  String webSearchProviderId;

  /// 其余服务商的 API Key（Tavily 沿用历史字段 [tavilyApiKey]）。
  String exaApiKey;
  String bochaApiKey;
  String zhipuApiKey;

  /// 联网搜索通用配置（对照源项目 WebSearchState 的三项）：
  /// 是否在搜索词前附带当前日期（提升时效类查询质量）。
  bool searchWithTime;

  /// 单次搜索返回的结果条数。
  int searchMaxResults;

  /// 每条结果正文的字符上限，0 = 不限制。
  int searchContentLimit;

  /// 最大输出 token 数，0 = 不限制（请求体不带 max_tokens，用上游默认）。
  int maxOutputTokens;

  /// 采样温度（temperature）。null = 不发送该参数，用上游默认；否则按
  /// [0.0, 2.0] 随请求发送（OpenAI / 各兼容服务商通用）。0.0 是有效值
  /// （更确定），故用 null 而非 0 作「未设置」哨兵。
  double? temperature;

  /// 核采样阈值（top_p）。null = 不发送，用上游默认；有效范围 [0, 1]。
  double? topP;

  /// MCP 直连 server 列表（方案 A）：客户端直连远程 Streamable HTTP 型 server，
  /// 其工具与内置工具一并装配进工具回路。
  List<McpServerConfig> mcpServers;

  /// 是否启用「后端 MCP Host」（方案 B）：开启后拉取后端聚合的 MCP 工具，
  /// 工具执行经 /uapi/mcp/call 由后端代理（可用上 stdio 型 server）。
  bool mcpBackendEnabled;

  /// 后端 MCP 工具是否信任（信任则调用免确认）。默认 false。
  bool mcpBackendTrusted;

  /// 用户侧用量成本估算口径。旧配置缺省时全为 0，只统计 token。
  UsageCostConfig usageCostConfig;

  AISettings({
    required this.mode,
    required this.providers,
    required this.activeProviderId,
    required this.backendModel,
    required this.streamEnabled,
    required this.resetOnLogout,
    this.tavilyApiKey = '',
    this.webSearchEnabled = false,
    this.webSearchProviderId = 'tavily',
    this.exaApiKey = '',
    this.bochaApiKey = '',
    this.zhipuApiKey = '',
    this.searchWithTime = true,
    this.searchMaxResults = 5,
    this.searchContentLimit = 2000,
    this.maxOutputTokens = 0,
    this.temperature,
    this.topP,
    List<McpServerConfig>? mcpServers,
    this.mcpBackendEnabled = false,
    this.mcpBackendTrusted = false,
    UsageCostConfig? usageCostConfig,
  })  : mcpServers = mcpServers ?? [],
        usageCostConfig = usageCostConfig ?? UsageCostConfig.builtinDefaults;

  factory AISettings.defaults() => AISettings(
        mode: AIMode.local,
        providers: ProviderPresets.all(),
        activeProviderId: ProviderPresets.defaultActiveId,
        backendModel: 'deepseek-chat',
        streamEnabled: true,
        resetOnLogout: true,
      );

  factory AISettings.fromJson(Map<String, dynamic> j) {
    final List<AiProvider> providers;
    final String activeId;

    if (j['providers'] is List) {
      // 新格式：直读，并把缺失的新预设补进来（app 升级后能看到新服务商）。
      providers = (j['providers'] as List)
          .map((e) => AiProvider.fromJson(e as Map<String, dynamic>))
          .toList();
      final existing = providers.map((p) => p.id).toSet();
      for (final preset in ProviderPresets.all()) {
        if (!existing.contains(preset.id)) providers.add(preset);
      }
      activeId =
          j['activeProviderId'] as String? ?? ProviderPresets.defaultActiveId;
    } else {
      // 旧格式迁移：从预设起步，把旧 openai/deepseek 的 key/model/baseUrl 注入。
      providers = ProviderPresets.all();
      _migrateLegacyProvider(
          providers, 'openai', j['openai'] as Map<String, dynamic>?);
      _migrateLegacyProvider(
          providers, 'deepseek', j['deepseek'] as Map<String, dynamic>?);
      activeId =
          (j['localProvider'] as String?) == 'openai' ? 'openai' : 'deepseek';
    }

    return AISettings(
      mode: _parseMode(j['mode'] as String?),
      providers: providers,
      activeProviderId: activeId,
      backendModel: j['backendModel'] as String? ?? 'deepseek-chat',
      streamEnabled: j['streamEnabled'] as bool? ?? true,
      resetOnLogout: j['resetOnLogout'] as bool? ?? true,
      tavilyApiKey: j['tavilyApiKey'] as String? ?? '',
      webSearchEnabled: j['webSearchEnabled'] as bool? ?? false,
      webSearchProviderId: j['webSearchProviderId'] as String? ?? 'tavily',
      exaApiKey: j['exaApiKey'] as String? ?? '',
      bochaApiKey: j['bochaApiKey'] as String? ?? '',
      zhipuApiKey: j['zhipuApiKey'] as String? ?? '',
      searchWithTime: j['searchWithTime'] as bool? ?? true,
      searchMaxResults: j['searchMaxResults'] as int? ?? 5,
      searchContentLimit: j['searchContentLimit'] as int? ?? 2000,
      maxOutputTokens: j['maxOutputTokens'] as int? ?? 0,
      temperature: _parseTemperature(j['temperature']),
      topP: _parseTopP(j['topP']),
      mcpServers: (j['mcpServers'] as List?)
              ?.map((e) =>
                  McpServerConfig.fromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          [],
      mcpBackendEnabled: j['mcpBackendEnabled'] as bool? ?? false,
      mcpBackendTrusted: j['mcpBackendTrusted'] as bool? ?? false,
      usageCostConfig: UsageCostConfig.fromJson(
          (j['usageCostConfig'] as Map?)?.cast<String, dynamic>()),
    );
  }

  /// 把旧版 `ProviderConfig{apiKey,baseUrl,model}` 注入预设里同名服务商。
  static void _migrateLegacyProvider(
      List<AiProvider> providers, String id, Map<String, dynamic>? legacy) {
    if (legacy == null) return;
    final idx = providers.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    final p = providers[idx];
    final apiKey = legacy['apiKey'] as String? ?? '';
    final model = legacy['model'] as String? ?? '';
    final baseUrl = legacy['baseUrl'] as String? ?? '';
    if (apiKey.isNotEmpty) p.apiKey = apiKey;
    if (model.isNotEmpty) {
      // 旧模型若不在预设清单里，补进去，保证用户原选项不丢。
      if (!p.models.any((m) => m.id == model)) {
        p.models.insert(0, AiModel(id: model));
      }
      p.selectedModelId = model;
    }
    if (baseUrl.isNotEmpty) {
      // 旧版把「完整 completions URL」逐字 POST（DirectChatService 直接用
      // baseUrl）。这里必须原样保留，否则自定义代理（如
      // https://myproxy.com/chat/completions，无 /v1）会被 chatCompletionsUrl
      // 强插 /v1/chat/completions 而改成另一个端点。含 `/chat/completions` 的串
      // 会被 chatCompletionsUrl 原样透传，故精确还原用户原端点。
      p.apiHost = baseUrl;
    }
    p.enabled = true;
  }

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'providers': providers.map((p) => p.toJson()).toList(),
        'activeProviderId': activeProviderId,
        'backendModel': backendModel,
        'streamEnabled': streamEnabled,
        'resetOnLogout': resetOnLogout,
        'tavilyApiKey': tavilyApiKey,
        'webSearchEnabled': webSearchEnabled,
        'webSearchProviderId': webSearchProviderId,
        'exaApiKey': exaApiKey,
        'bochaApiKey': bochaApiKey,
        'zhipuApiKey': zhipuApiKey,
        'searchWithTime': searchWithTime,
        'searchMaxResults': searchMaxResults,
        'searchContentLimit': searchContentLimit,
        'maxOutputTokens': maxOutputTokens,
        'temperature': temperature,
        'topP': topP,
        'mcpServers': mcpServers.map((e) => e.toJson()).toList(),
        'mcpBackendEnabled': mcpBackendEnabled,
        'mcpBackendTrusted': mcpBackendTrusted,
        'usageCostConfig': usageCostConfig.toJson(),
      };

  /// 深拷贝（JSON 往返）。用于「改一个字段再 update」时产生新实例，
  /// 保证 provider 监听方的 identity 比较能感知变化。
  AISettings clone() => AISettings.fromJson(toJson());

  /// 当前激活的服务商。找不到时回退首个启用 / 首个 / 兜底空壳。
  AiProvider get activeProvider {
    for (final p in providers) {
      if (p.id == activeProviderId) return p;
    }
    for (final p in providers) {
      if (p.enabled) return p;
    }
    if (providers.isNotEmpty) return providers.first;
    return AiProvider(id: 'none', type: 'openai', name: '未配置');
  }

  /// 启用中的服务商（UI「可切换」清单）。
  List<AiProvider> get enabledProviders =>
      providers.where((p) => p.enabled).toList();

  /// 当前生效的直连配置（仅 mode=local 时调用方应使用）。
  /// host 留空时回落到预设默认地址（兑现详情页「留空用默认」的承诺）。
  ProviderConfig get activeLocal {
    final p = activeProvider;
    final host = p.apiHost.trim().isEmpty
        ? (ProviderPresets.byId(p.id)?.apiHost ?? '')
        : p.apiHost;
    return ProviderConfig(
      apiKey: p.apiKey,
      baseUrl: AiProvider.buildChatCompletionsUrl(host),
      model: p.effectiveModelId,
    );
  }

  /// 能力探测用的 providerCode（mode=local 时取激活服务商）。
  String get activeProviderCode => activeProvider.providerCode;

  /// 把模型覆盖写回当前激活服务商（assistant 模型覆盖路径用）。
  void setActiveModel(String model) {
    final m = model.trim();
    if (m.isEmpty) return;
    final p = activeProvider;
    if (!p.models.any((e) => e.id == m)) {
      p.models.insert(0, AiModel(id: m));
    }
    p.selectedModelId = m;
  }

  /// 当前实际要发给上游的模型名。
  String get effectiveModel =>
      mode == AIMode.backend ? backendModel : activeProvider.effectiveModelId;

  /// 当前所选联网搜索服务商的 API Key。
  String get activeSearchApiKey {
    switch (webSearchProviderId) {
      case 'exa':
        return exaApiKey.trim();
      case 'bocha':
        return bochaApiKey.trim();
      case 'zhipu':
        return zhipuApiKey.trim();
      default:
        return tavilyApiKey.trim();
    }
  }

  /// 联网搜索是否已配置（当前服务商有 key）。会话页据此显隐联网开关。
  bool get webSearchConfigured => activeSearchApiKey.isNotEmpty;

  /// 启用中的 MCP 直连 server（方案 A）。
  List<McpServerConfig> get enabledMcpServers =>
      mcpServers.where((s) => s.enabled && s.url.trim().isNotEmpty).toList();

  /// 是否启用了任一 MCP 来源（直连 server 或后端 Host）。
  bool get mcpConfigured => mcpBackendEnabled || enabledMcpServers.isNotEmpty;

  /// AI 服务商显示名称。
  String get aiDisplayName {
    if (mode == AIMode.local) {
      return activeProvider.name;
    }
    // 后端模式：按模型名前缀判断。
    final m = backendModel.toLowerCase();
    if (m.startsWith('gpt-') ||
        m.startsWith('o1-') ||
        m.startsWith('chatgpt-')) {
      return 'ChatGPT';
    }
    if (m.startsWith('deepseek-')) {
      return 'DeepSeek';
    }
    return 'AI';
  }

  static AIMode _parseMode(String? s) {
    if (s == 'backend') return AIMode.backend;
    return AIMode.local;
  }

  static double? _parseTopP(Object? value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite && parsed >= 0 && parsed <= 1
        ? parsed
        : null;
  }

  static double? _parseTemperature(Object? value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite && parsed >= 0 && parsed <= 2
        ? parsed
        : null;
  }
}
