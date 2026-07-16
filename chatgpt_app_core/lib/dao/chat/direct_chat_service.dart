import 'dart:async';

import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/tool_call_accumulator.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

class DirectChatService implements ChatService, OptionsAwareChatService {
  final ProviderConfig _cfg;

  /// 精确服务商 id。用于防止 custom/openrouter 因派生 code 被误判为 first-party。
  final String? _providerId;

  /// 本地服务商 code（'openai'/'deepseek'），供能力探测按厂商区分。
  final String? _providerCode;

  /// 最大输出 token 数，0 = 不限制（不发 max_tokens，用上游默认）。
  /// 之前写死 1000 会截断长回复（推理模型的思考也计入），现由设置驱动。
  final int _maxOutputTokens;

  /// 采样温度，null = 不发送（用上游默认）。0.0 是有效值，故用 null 作哨兵。
  final double? _temperature;

  /// 核采样阈值，null = 不发送（用上游默认）。0.0 是有效值。
  final double? _topP;

  DirectChatService(
    this._cfg, {
    String? providerId,
    String? providerCode,
    int maxOutputTokens = 0,
    double? temperature,
    double? topP,
  })  : _providerId = providerId,
        _providerCode = providerCode,
        _maxOutputTokens = maxOutputTokens,
        _temperature = temperature,
        _topP = topP;

  int? get _maxTokensOrNull => _maxOutputTokens > 0 ? _maxOutputTokens : null;

  @override
  ModelCapabilities get capabilities =>
      ModelCatalog.capabilitiesFor(_cfg.model, providerCode: _providerCode);

  void _ensureApiKey() {
    if (_cfg.apiKey.trim().isEmpty) {
      throw Exception('请先在「我的 → AI 服务设置」中填写 API Key');
    }
  }

  /// 组装当前轮消息：附件（图片/原生文件/降级文本）收敛进 user content；
  /// [extraMessages]（工具回灌）追加在 user 之后。
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
    _ensureApiKey();
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = _buildMessages(prompt, history, attachments);
    final response = await completion.createChat(
      model: _cfg.model,
      messages: messages,
      maxTokens: _maxTokensOrNull,
      temperature: _temperature,
      topP: _topP,
      timeout: timeout ?? const Duration(seconds: 15),
    );
    final choices = response.choices?.first;
    return choices?.message?.content;
  }

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async {
    _ensureApiKey();
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = _buildMessages(prompt, history, attachments);
    final response = await completion.createChat(
      model: _cfg.model,
      messages: messages,
      maxTokens: _maxTokensOrNull,
      temperature: _temperature,
      topP: _topP,
    );
    final choices = response.choices?.first;
    return ChatCompletionResult(
      content: choices?.message?.content,
      promptTokens: response.usage?.promptTokens,
      cachedPromptTokens: response.usage?.cachedPromptTokens,
      completionTokens: response.usage?.completionTokens,
      estimated: false,
    );
  }

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async* {
    _ensureApiKey();
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = _buildMessages(prompt, history, attachments);
    yield* completion.createChatStream(
      model: _cfg.model,
      messages: messages,
      maxTokens: _maxTokensOrNull,
      temperature: _temperature,
      topP: _topP,
    );
  }

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) async* {
    _ensureApiKey();
    yield* _createStreamEvents(
      prompt: prompt,
      history: history,
      attachments: attachments,
      tools: tools,
      extraMessages: extraMessages,
      maxTokens: _maxTokensOrNull,
    );
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) async* {
    try {
      _ensureApiKey();
      final reasoning = ReasoningControlAdapter.resolve(
        providerId: _providerId,
        providerCode: _providerCode,
        modelId: _cfg.model,
        policy: options.reasoningPolicy,
        suppressed: options.suppressReasoningControl,
      );
      final events = _createStreamEvents(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        maxTokens: _maxTokensFor(options),
        extraBody: reasoning.requestFields,
        abortTrigger: options.abortTrigger,
        connectTimeout: options.connectTimeout,
      );
      await for (final event in events) {
        yield event;
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(_mapTransportFailure(error), stackTrace);
    }
  }

  int? _maxTokensFor(ChatRequestOptions options) {
    final requestedMinimum = options.minOutputTokens ?? 0;
    final value = _maxOutputTokens >= requestedMinimum
        ? _maxOutputTokens
        : requestedMinimum;
    return value > 0 ? value : null;
  }

  Stream<StreamEvent> _createStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    int? maxTokens,
    Map<String, dynamic> extraBody = const {},
    Future<void>? abortTrigger,
    Duration connectTimeout = const Duration(seconds: 20),
  }) async* {
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages =
        _buildMessages(prompt, history, attachments, extraMessages);
    // 工具调用分片按 index 累积，流结束后再发完整 toolCall 事件（阶段六）。
    final toolAcc = ToolCallAccumulator();
    await for (final chunk in completion.createChatStreamEvents(
      model: _cfg.model,
      messages: messages,
      maxTokens: maxTokens,
      temperature: _temperature,
      topP: _topP,
      tools: tools,
      extraBody: extraBody,
      abortTrigger: abortTrigger,
      connectTimeout: connectTimeout,
    )) {
      switch (chunk.kind) {
        case AIStreamKind.reasoning:
          yield StreamEvent.reasoning(chunk.text);
        case AIStreamKind.content:
          yield StreamEvent.text(chunk.text);
        case AIStreamKind.toolCall:
          toolAcc.feed(
            index: chunk.toolIndex ?? 0,
            id: chunk.toolId,
            name: chunk.toolName,
            argsDelta: chunk.toolArgsDelta,
          );
        case AIStreamKind.usage:
          yield StreamEvent.usage(
            promptTokens: chunk.promptTokens,
            cachedPromptTokens: chunk.cachedPromptTokens,
            completionTokens: chunk.completionTokens,
          );
      }
    }
    for (final e in toolAcc.flush()) {
      yield e;
    }
  }
}

ChatTransportException _mapTransportFailure(Object error) {
  if (error is ChatTransportException) return error;
  if (error is AIRequestCancelledException) {
    return const ChatTransportException(
      safeCode: 'cancelled',
      safeMessage: '请求已取消',
    );
  }
  if (error is TimeoutException) {
    return const ChatTransportException(
      safeCode: 'timeout',
      safeMessage: '请求超时',
    );
  }
  if (error is AITransportException) {
    return const ChatTransportException(
      safeCode: 'network_error',
      safeMessage: '网络请求失败',
    );
  }
  if (error is AIRequestException) {
    final code = error.safeCode ?? _safeCodeForStatus(error.statusCode);
    return ChatTransportException(
      statusCode: error.statusCode,
      retryAfter: error.retryAfter,
      safeCode: code,
      safeMessage: _safeMessageForCode(code),
    );
  }
  return const ChatTransportException(
    safeCode: 'request_failed',
    safeMessage: '请求失败',
  );
}

String _safeCodeForStatus(int statusCode) {
  if (statusCode == 400) return 'invalid_request';
  if (statusCode == 401 || statusCode == 403) return 'authentication_error';
  if (statusCode == 429) return 'rate_limited';
  if (statusCode >= 500) return 'server_error';
  return 'request_failed';
}

String _safeMessageForCode(String safeCode) {
  switch (safeCode) {
    case 'unknown_parameter':
    case 'unsupported_parameter':
      return '上游不支持请求参数';
    case 'invalid_request':
      return '请求参数无效';
    case 'authentication_error':
      return '身份验证失败';
    case 'rate_limited':
      return '请求过于频繁';
    case 'server_error':
      return '上游服务异常';
    default:
      return '请求失败';
  }
}
