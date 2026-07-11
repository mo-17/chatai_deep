import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/tool_call_accumulator.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

class BackendChatService implements ChatService {
  final AISettings _settings;

  BackendChatService(this._settings);

  static StreamEvent? usageEventFromStreamJson(Map<String, dynamic> json) {
    final usage = json['usage'];
    if (usage is! Map<String, dynamic>) return null;
    final promptDetails = usage['prompt_tokens_details'];
    return StreamEvent.usage(
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt(),
      cachedPromptTokens: promptDetails is Map
          ? (promptDetails['cached_tokens'] as num?)?.toInt()
          : null,
      completionTokens: (usage['completion_tokens'] as num?)?.toInt(),
    );
  }

  @override
  ModelCapabilities get capabilities =>
      // 后端模式不知道厂商，交给清单按 modelId 反查 providerCode + supportsVision。
      ModelCatalog.capabilitiesFor(_settings.effectiveModel);

  /// 组装当前轮消息：附件（图片/原生文件/降级文本）收敛进 user content；
  /// [extraMessages]（工具回灌）追加在 user 之后。
  /// 后端 /uapi/chat/completions 透传 OpenAI 兼容 body，多模态数组原样转发。
  List<Map<String, dynamic>> _buildMessages(
    String prompt,
    List<Map<String, dynamic>> history,
    ChatAttachments? attachments, [
    List<Map<String, dynamic>> extraMessages = const [],
  ]) =>
      [
        ...history,
        {
          'role': 'user',
          'content':
              (attachments ?? const ChatAttachments()).buildUserContent(prompt),
        },
        ...extraMessages,
      ];

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) async {
    final uri = BackendConst.buildUri('/uapi/chat/completions');
    final messages = _buildMessages(prompt, history, attachments);
    final body = {
      'model': _settings.effectiveModel,
      'messages': messages,
      // 0 = 不限制：不带 max_tokens，用上游默认（避免长回复被截断）。
      if (_settings.maxOutputTokens > 0)
        'max_tokens': _settings.maxOutputTokens,
      // null = 不带 temperature，用上游默认。
      if (_settings.temperature != null) 'temperature': _settings.temperature,
      // null = 不带 top_p，用上游默认。
      if (_settings.topP != null) 'top_p': _settings.topP,
    };
    final token = LoginDao.getBoardingPass();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    };
    final response = await http
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(timeout ?? const Duration(minutes: 2));
    AILogger.log('backend response: ${response.statusCode}');

    if (response.statusCode == 401) {
      LoginDao.logOut();
      throw Exception('登录已过期，请重新登录');
    }

    const utf8decoder = Utf8Decoder();
    final bodyString = utf8decoder.convert(response.bodyBytes);
    AILogger.log('backend response body: ${AILogger.truncate(bodyString)}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      final result = json.decode(bodyString) as Map<String, dynamic>;
      if (result['code'] == 0 && result['data'] != null) {
        final data = result['data'] as Map<String, dynamic>;
        final content = data['content'] as String?;
        if (content != null && content.isNotEmpty) return content;
        final reasoning = data['reasoningContent'] as String?;
        if (reasoning != null && reasoning.isNotEmpty) return reasoning;
        // 后端返回了 data 但没有可展示的文本内容
        throw Exception('AI 未返回有效内容');
      }
      // code != 0：后端业务错误
      final msg = result['message'] as String?;
      throw Exception(msg ?? '请求失败');
    }
    // HTTP 错误
    throw Exception('服务异常(${response.statusCode})');
  }

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async {
    final uri = BackendConst.buildUri('/uapi/chat/completions');
    final messages = _buildMessages(prompt, history, attachments);
    final body = {
      'model': _settings.effectiveModel,
      'messages': messages,
      // 0 = 不限制：不带 max_tokens，用上游默认（避免长回复被截断）。
      if (_settings.maxOutputTokens > 0)
        'max_tokens': _settings.maxOutputTokens,
      // null = 不带 temperature，用上游默认。
      if (_settings.temperature != null) 'temperature': _settings.temperature,
      // null = 不带 top_p，用上游默认。
      if (_settings.topP != null) 'top_p': _settings.topP,
    };
    final token = LoginDao.getBoardingPass();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    };
    final response = await http
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    AILogger.log('backend response: ${response.statusCode}');

    if (response.statusCode == 401) {
      LoginDao.logOut();
      throw Exception('登录已过期，请重新登录');
    }

    const utf8decoder = Utf8Decoder();
    final bodyString = utf8decoder.convert(response.bodyBytes);
    AILogger.log('backend response body: ${AILogger.truncate(bodyString)}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      final result = json.decode(bodyString) as Map<String, dynamic>;
      if (result['code'] == 0 && result['data'] != null) {
        final data = result['data'] as Map<String, dynamic>;
        final usage = data['usage'] as Map<String, dynamic>?;
        final promptDetails = usage?['prompt_tokens_details'];
        final content = data['content'] as String?;
        final reasoning = data['reasoningContent'] as String?;
        return ChatCompletionResult(
          content:
              (content != null && content.isNotEmpty) ? content : reasoning,
          promptTokens: usage == null ? null : usage['prompt_tokens'] as int?,
          cachedPromptTokens: promptDetails is Map
              ? (promptDetails['cached_tokens'] as num?)?.toInt()
              : null,
          completionTokens:
              usage == null ? null : usage['completion_tokens'] as int?,
          estimated: false,
          cost: 0,
        );
      }
      final msg = result['message'] as String?;
      throw Exception(msg ?? '请求失败');
    }
    throw Exception('服务异常(${response.statusCode})');
  }

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      chatStreamEvents(
              prompt: prompt, history: history, attachments: attachments)
          .map((e) => e.delta);

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) async* {
    final uri = BackendConst.buildUri('/uapi/chat/completions/stream');
    final messages =
        _buildMessages(prompt, history, attachments, extraMessages);
    final body = {
      'model': _settings.effectiveModel,
      'messages': messages,
      // 0 = 不限制：不带 max_tokens，用上游默认（避免长回复被截断）。
      if (_settings.maxOutputTokens > 0)
        'max_tokens': _settings.maxOutputTokens,
      // null = 不带 temperature，用上游默认。
      if (_settings.temperature != null) 'temperature': _settings.temperature,
      // null = 不带 top_p，用上游默认。
      if (_settings.topP != null) 'top_p': _settings.topP,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
    };
    final token = LoginDao.getBoardingPass();

    final request = http.Request('POST', uri);
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    });
    request.body = jsonEncode(body);

    final httpClient = http.Client();
    try {
      final streamedResponse =
          await httpClient.send(request).timeout(const Duration(seconds: 20));
      AILogger.log('backend stream status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode == 401) {
        LoginDao.logOut();
        throw Exception('登录已过期，请重新登录');
      }

      if (streamedResponse.statusCode != 200 &&
          streamedResponse.statusCode != 201) {
        final bytes = await streamedResponse.stream.toBytes();
        final errorBody = const Utf8Decoder().convert(bytes);
        throw Exception('服务异常(${streamedResponse.statusCode}): $errorBody');
      }

      final lineStream = streamedResponse.stream
          .transform(const Utf8Decoder())
          .transform(const LineSplitter());

      // 工具调用分片按 index 累积，流结束后再发完整 toolCall 事件（阶段六）。
      final toolAcc = ToolCallAccumulator();
      await for (final line in lineStream) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6);
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final usageEvent = usageEventFromStreamJson(json);
          if (usageEvent != null) yield usageEvent;
          final choices = json['choices'] as List<dynamic>?;
          if (choices != null && choices.isNotEmpty) {
            final choice = choices[0];
            if (choice is! Map<String, dynamic>) continue;
            final delta = choice['delta'];
            if (delta is! Map<String, dynamic>) continue;
            // 推理内容增量 (DeepSeek reasoning models)：先于正文到达。
            final reasoning = delta['reasoning_content'];
            if (reasoning is String && reasoning.isNotEmpty) {
              yield StreamEvent.reasoning(reasoning);
            }
            // 常规内容增量
            final content = delta['content'];
            if (content is String && content.isNotEmpty) {
              yield StreamEvent.text(content);
            }
            // 工具调用增量（后端原样中继上游 SSE，分片格式同 OpenAI）。
            final toolCalls = delta['tool_calls'];
            if (toolCalls is List) {
              for (final tc in toolCalls.whereType<Map>()) {
                final fn = tc['function'];
                toolAcc.feed(
                  index: tc['index'] as int? ?? 0,
                  id: tc['id'] as String?,
                  name: fn is Map ? fn['name'] as String? : null,
                  argsDelta: fn is Map ? fn['arguments'] as String? : null,
                );
              }
            }
          }
        } catch (_) {
          // 忽略无法解析的行
        }
      }
      for (final e in toolAcc.flush()) {
        yield e;
      }
    } finally {
      httpClient.close();
    }
  }
}
