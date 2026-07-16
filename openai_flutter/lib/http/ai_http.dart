import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

///HTTP请求工具类
class AIHttp {
  static Future<T> post<T>({
    required AIConfigBuilder config,
    required String url,
    required T Function(Map<String, dynamic>) onSuccess,
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    AILogger.log('starting request');
    final myClient = _createOwnedClient(config);
    final requestAbort = Completer<void>();
    var timedOut = false;
    void abortOnce({bool timeout = false}) {
      if (requestAbort.isCompleted) return;
      timedOut = timeout;
      requestAbort.complete();
    }

    final timeoutTimer = Timer(timeout, () => abortOnce(timeout: true));

    try {
      final request = http.AbortableRequest(
        'POST',
        Uri.parse(url),
        abortTrigger: requestAbort.future,
      )..headers.addAll(config.headers());
      if (body != null) request.body = jsonEncode(body);
      final streamedResponse = await myClient.send(request);
      final response = await http.Response.fromStream(streamedResponse);
      AILogger.log('request finished with status code ${response.statusCode}');
      AILogger.log('starting decoding response body');

      ///防止乱码
      final bodyString = const Utf8Decoder().convert(response.bodyBytes);
      Map<String, dynamic> decodedBody;
      try {
        final decoded = jsonDecode(bodyString);
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        decodedBody = decoded;
      } on FormatException {
        throw AIRequestException(
          'HTTP request failed',
          response.statusCode,
          headers: response.headers,
        );
      }
      AILogger.log("response body decoded successfully");
      if (decodedBody['error'] != null) {
        AILogger.log("an error occurred, throwing exception");
        throw AIRequestException(
          'HTTP request failed',
          response.statusCode,
          headers: response.headers,
        );
      }
      AILogger.log("request finished successfully");
      return onSuccess(decodedBody);
    } on http.RequestAbortedException {
      if (timedOut) throw TimeoutException('Request timed out', timeout);
      throw const AIRequestCancelledException();
    } finally {
      timeoutTimer.cancel();
      abortOnce();
      myClient.close();
    }
  }

  /// SSE 流式 POST 请求，逐 token yield（仅文本，保留向后兼容）。
  ///
  /// 正文与推理增量都会被 yield 成纯字符串、无法区分。需要区分思考/正文时
  /// 改用 [postStreamEvents]。
  static Stream<String> postStream({
    required AIConfigBuilder config,
    required String url,
    Map<String, dynamic>? body,
  }) =>
      postStreamEvents(config: config, url: url, body: body)
          .map((chunk) => chunk.text);

  /// SSE 流式 POST 请求，逐增量 yield 「带类型」的片段
  /// （区分 `delta.content` 正文 与 `delta.reasoning_content` 推理）。
  static Stream<AIStreamChunk> postStreamEvents({
    required AIConfigBuilder config,
    required String url,
    Map<String, dynamic>? body,
    Future<void>? abortTrigger,
    Duration connectTimeout = const Duration(seconds: 20),
  }) async* {
    AILogger.log('starting stream request');

    final myClient = _createOwnedClient(config);
    final requestAbort = Completer<void>();
    var connectTimedOut = false;
    void abortOnce({bool timeout = false}) {
      if (requestAbort.isCompleted) return;
      connectTimedOut = timeout;
      requestAbort.complete();
    }

    abortTrigger?.then<void>(
      (_) => abortOnce(),
      onError: (Object _, StackTrace __) => abortOnce(),
    );
    final connectTimer = Timer(connectTimeout, () => abortOnce(timeout: true));

    try {
      final request = http.AbortableRequest(
        'POST',
        Uri.parse(url),
        abortTrigger: requestAbort.future,
      );
      request.headers.addAll(config.headers());
      if (body != null) {
        request.body = jsonEncode(body);
      }
      final streamedResponse = await myClient.send(request);
      connectTimer.cancel();
      AILogger.log(
          'stream request finished with status ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode != 200) {
        await streamedResponse.stream.drain<void>();
        throw AIRequestException(
          'HTTP request failed',
          streamedResponse.statusCode,
          headers: streamedResponse.headers,
        );
      }

      final lineStream = streamedResponse.stream
          .transform(const Utf8Decoder())
          .transform(const LineSplitter());
      String? eventName;

      await for (final line in lineStream) {
        if (line.isEmpty) {
          eventName = null;
          continue;
        }
        if (line.startsWith('event:')) {
          eventName = line.substring(6).trim();
          continue;
        }
        if (!line.startsWith('data:')) continue;
        var data = line.substring(5);
        if (data.startsWith(' ')) data = data.substring(1);

        if (eventName == 'error') {
          throw AIRequestException(
            'Streaming request failed',
            streamedResponse.statusCode,
            headers: streamedResponse.headers,
          );
        }
        if (data == '[DONE]') break;

        Map<String, dynamic>? json;
        try {
          final value = jsonDecode(data);
          if (value is Map<String, dynamic>) json = value;
        } on FormatException {
          // 忽略无法解析的数据行；事件错误在 catch 外统一抛出。
        }

        if (json == null) continue;
        if (json['error'] != null) {
          throw AIRequestException(
            'Streaming request failed',
            streamedResponse.statusCode,
            headers: streamedResponse.headers,
          );
        }

        final usage = json['usage'];
        if (usage is Map<String, dynamic>) {
          final promptDetails = usage['prompt_tokens_details'];
          yield AIStreamChunk.usage(
            promptTokens: (usage['prompt_tokens'] as num?)?.toInt(),
            cachedPromptTokens: promptDetails is Map
                ? (promptDetails['cached_tokens'] as num?)?.toInt()
                : null,
            completionTokens: (usage['completion_tokens'] as num?)?.toInt(),
          );
        }
        final choices = json['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices[0];
        if (choice is! Map<String, dynamic>) continue;
        final delta = choice['delta'];
        if (delta is! Map<String, dynamic>) continue;
        // 推理内容增量 (DeepSeek reasoning models: deepseek-reasoner)
        // 注意：推理先于正文到达，先 yield 推理再 yield 正文。
        final reasoning = delta['reasoning_content'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield AIStreamChunk.reasoning(reasoning);
        }
        // 常规内容增量 (DeepSeek / OpenAI)
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield AIStreamChunk.content(content);
        }
        // 工具调用增量（阶段六）：id/name 先到、arguments 分片到达，
        // 原样 yield 分片，由上层按 index 累积成完整调用。
        final toolCalls = delta['tool_calls'];
        if (toolCalls is List) {
          for (final tc in toolCalls.whereType<Map>()) {
            final fn = tc['function'];
            yield AIStreamChunk.toolCall(
              toolIndex: tc['index'] as int? ?? 0,
              toolId: tc['id'] as String?,
              toolName: fn is Map ? fn['name'] as String? : null,
              toolArgsDelta: fn is Map ? fn['arguments'] as String? : null,
            );
          }
        }
      }
    } on http.RequestAbortedException {
      if (connectTimedOut) {
        throw TimeoutException('Connection timed out', connectTimeout);
      }
      throw const AIRequestCancelledException();
    } finally {
      connectTimer.cancel();
      abortOnce();
      myClient.close();
    }
  }

  static IOClient _createOwnedClient(AIConfigBuilder config) {
    final httpClient = HttpClient();
    final proxy = config.proxy;
    if (proxy != null && proxy.trim().isNotEmpty) {
      httpClient.findProxy = (uri) => 'PROXY $proxy';
    }
    return IOClient(httpClient);
  }
}
