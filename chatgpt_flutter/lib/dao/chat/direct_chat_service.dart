import 'package:chatgpt_flutter/dao/chat/chat_service.dart';
import 'package:chatgpt_flutter/model/ai_settings.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';

class DirectChatService implements ChatService {
  final ProviderConfig _cfg;

  DirectChatService(this._cfg);

  void _ensureApiKey() {
    if (_cfg.apiKey.trim().isEmpty) {
      throw Exception('请先在「我的 → AI 服务设置」中填写 API Key');
    }
  }

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, String>> history,
  }) async {
    _ensureApiKey();
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = [
      ...history,
      {'role': 'user', 'content': prompt},
    ];
    final response = await completion.createChat(
      model: _cfg.model,
      messages: messages,
      maxTokens: 1000,
    );
    final choices = response.choices?.first;
    return choices?.message?.content;
  }

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, String>> history,
  }) async* {
    _ensureApiKey();
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = [
      ...history,
      {'role': 'user', 'content': prompt},
    ];
    yield* completion.createChatStream(
      model: _cfg.model,
      messages: messages,
      maxTokens: 1000,
    );
  }
}
