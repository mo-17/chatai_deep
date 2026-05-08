///openai_flutter SDK配置工具类（per-instance，不再使用单例）
class AIConfigBuilder {
  final String apiKey;
  final String chatUrl;
  final String? proxy;
  final String? organization;

  AIConfigBuilder({
    required this.apiKey,
    required this.chatUrl,
    this.proxy,
    this.organization,
  });

  Map<String, String> headers() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Authorization':
          apiKey.startsWith('Bearer ') ? apiKey : 'Bearer $apiKey',
    };
    if (organization != null) {
      h['OpenAI-Organization'] = organization!;
    }
    return h;
  }
}
