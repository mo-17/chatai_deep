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

  AISettings({
    required this.mode,
    required this.localProvider,
    required this.openai,
    required this.deepseek,
    required this.backendModel,
    required this.streamEnabled,
    required this.resetOnLogout,
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
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'localProvider': localProvider.name,
        'openai': openai.toJson(),
        'deepseek': deepseek.toJson(),
        'backendModel': backendModel,
        'streamEnabled': streamEnabled,
        'resetOnLogout': resetOnLogout,
      };

  /// 当前生效的 provider 配置（仅 mode=local 时调用方应使用）
  ProviderConfig get activeLocal =>
      localProvider == LocalProvider.openai ? openai : deepseek;

  /// 当前实际要发给上游的模型名
  String get effectiveModel =>
      mode == AIMode.backend ? backendModel : activeLocal.model;

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
