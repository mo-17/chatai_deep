enum AIMode { local, backend }

enum LocalProvider { openai, deepseek }

class ProviderConfig {
  String apiKey;
  String baseUrl;
  String model;

  ProviderConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ProviderConfig(
        apiKey: j['apiKey'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        model: j['model'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'model': model,
      };
}

class AISettings {
  AIMode mode;
  LocalProvider localProvider;
  ProviderConfig openai;
  ProviderConfig deepseek;
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
  /// 之前各 ChatService 写死 1000 导致长回复被截断 —— 现在默认不限。
  int maxOutputTokens;

  AISettings({
    required this.mode,
    required this.localProvider,
    required this.openai,
    required this.deepseek,
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
  });

  factory AISettings.defaults() => AISettings(
        mode: AIMode.local,
        localProvider: LocalProvider.deepseek,
        openai: ProviderConfig(
          apiKey: '',
          baseUrl: 'https://api.openai.com/v1/chat/completions',
          model: 'gpt-3.5-turbo',
        ),
        deepseek: ProviderConfig(
          apiKey: '',
          baseUrl: 'https://api.deepseek.com/chat/completions',
          model: 'deepseek-chat',
        ),
        backendModel: 'deepseek-chat',
        streamEnabled: true,
        resetOnLogout: true,
      );

  factory AISettings.fromJson(Map<String, dynamic> j) => AISettings(
        mode: _parseMode(j['mode'] as String?),
        localProvider: _parseLocalProvider(j['localProvider'] as String?),
        openai: j['openai'] != null
            ? ProviderConfig.fromJson(j['openai'] as Map<String, dynamic>)
            : ProviderConfig(
                apiKey: '',
                baseUrl: 'https://api.openai.com/v1/chat/completions',
                model: 'gpt-3.5-turbo'),
        deepseek: j['deepseek'] != null
            ? ProviderConfig.fromJson(j['deepseek'] as Map<String, dynamic>)
            : ProviderConfig(
                apiKey: '',
                baseUrl: 'https://api.deepseek.com/chat/completions',
                model: 'deepseek-chat'),
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
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'localProvider': localProvider.name,
        'openai': openai.toJson(),
        'deepseek': deepseek.toJson(),
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
      };

  /// 深拷贝（JSON 往返）。用于「改一个字段再 update」时产生新实例，
  /// 保证 provider 监听方的 identity 比较能感知变化。
  AISettings clone() => AISettings.fromJson(toJson());

  /// 当前生效的 provider 配置（仅 mode=local 时调用方应使用）
  ProviderConfig get activeLocal =>
      localProvider == LocalProvider.openai ? openai : deepseek;

  /// 当前实际要发给上游的模型名
  String get effectiveModel =>
      mode == AIMode.backend ? backendModel : activeLocal.model;

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

  /// AI 服务商显示名称
  String get aiDisplayName {
    if (mode == AIMode.local) {
      return localProvider == LocalProvider.openai ? 'ChatGPT' : 'DeepSeek';
    }
    // 后端模式：按模型名前缀判断
    final m = backendModel.toLowerCase();
    if (m.startsWith('gpt-') || m.startsWith('o1-') || m.startsWith('chatgpt-')) {
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

  static LocalProvider _parseLocalProvider(String? s) {
    if (s == 'openai') return LocalProvider.openai;
    return LocalProvider.deepseek;
  }
}
