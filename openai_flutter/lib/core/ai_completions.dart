import 'package:openai_flutter/core/interfaces/ai_create.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_http.dart';
import 'package:openai_flutter/model/ai_response.dart';

class AICompletion implements AICreateInterface {
  final AIConfigBuilder config;

  AICompletion(this.config);

  @override
  Future<AIResponse> createChat({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    int? maxTokens = 200,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
    List<Map<String, String>>? messages,
  }) async {
    final body = <String, dynamic>{
      "model": model,
      if (maxTokens != null) "max_tokens": maxTokens,
      if (temperature != null) "temperature": temperature,
      if (topP != null) "top_p": topP,
      if (n != null) "n": n,
      if (stop != null) "stop": stop,
      if (user != null) "user": user,
    };

    if (messages != null) {
      body["messages"] = messages;
    } else if (prompt != null) {
      body["messages"] = [
        {"role": "user", "content": prompt}
      ];
    }

    return await AIHttp.post(
      config: config,
      url: config.chatUrl,
      onSuccess: (Map<String, dynamic> response) {
        return AIResponse.fromJson(response);
      },
      body: body,
    );
  }

  /// 流式 Chat Completions，逐 token yield
  Stream<String> createChatStream({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    int? maxTokens = 200,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
    List<Map<String, String>>? messages,
  }) async* {
    final body = <String, dynamic>{
      "model": model,
      "stream": true,
      "stream_options": {"include_usage": true},
      if (maxTokens != null) "max_tokens": maxTokens,
      if (temperature != null) "temperature": temperature,
      if (topP != null) "top_p": topP,
      if (n != null) "n": n,
      if (stop != null) "stop": stop,
      if (user != null) "user": user,
    };

    if (messages != null) {
      body["messages"] = messages;
    } else if (prompt != null) {
      body["messages"] = [
        {"role": "user", "content": prompt}
      ];
    }

    yield* AIHttp.postStream(
      config: config,
      url: config.chatUrl,
      body: body,
    );
  }
}
