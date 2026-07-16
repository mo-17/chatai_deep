import 'package:openai_flutter/core/interfaces/ai_create.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_http.dart';
import 'package:openai_flutter/model/ai_response.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

class AICompletion implements AICreateInterface {
  static const _reservedExtraBodyKeys = {
    'model',
    'messages',
    'stream',
    'stream_options',
    'tools',
    'max_tokens',
    'temperature',
    'top_p',
  };

  final AIConfigBuilder config;

  AICompletion(this.config);

  @override
  Future<AIResponse> createChat({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    int? maxTokens,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
    List<Map<String, dynamic>>? messages,
    Duration timeout = const Duration(seconds: 15),
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
      timeout: timeout,
    );
  }

  /// 流式 Chat Completions，逐 token yield
  Stream<String> createChatStream({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    int? maxTokens,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
    List<Map<String, dynamic>>? messages,
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

  /// 流式 Chat Completions，逐增量 yield「带类型」的片段
  /// （区分正文 content / 推理 reasoning_content / 工具调用 tool_calls 分片）。
  /// [tools] 为 OpenAI function declarations（阶段六工具调用）。
  @override
  Stream<AIStreamChunk> createChatStreamEvents({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    int? maxTokens,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
    List<Map<String, dynamic>>? messages,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic> extraBody = const {},
    Future<void>? abortTrigger,
    Duration connectTimeout = const Duration(seconds: 20),
  }) async* {
    for (final key in extraBody.keys) {
      if (_reservedExtraBodyKeys.contains(key)) {
        throw ArgumentError.value(
          key,
          'extraBody',
          'Cannot override canonical request field',
        );
      }
    }

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
      if (tools != null && tools.isNotEmpty) "tools": tools,
    };

    if (messages != null) {
      body["messages"] = messages;
    } else if (prompt != null) {
      body["messages"] = [
        {"role": "user", "content": prompt}
      ];
    }
    body.addAll(extraBody);

    yield* AIHttp.postStreamEvents(
      config: config,
      url: config.chatUrl,
      body: body,
      abortTrigger: abortTrigger,
      connectTimeout: connectTimeout,
    );
  }
}
