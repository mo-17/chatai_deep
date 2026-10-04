import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/chat_request_recovery.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/application/tool_call_accumulator.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

class BackendChatService
    implements
        ChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  final AISettings _settings;

  BackendChatService(this._settings);

  Map<String, dynamic> _reasoningFields(ChatRequestOptions options,
      {bool includeDefaultPolicy = false}) {
    final effort =
        options.deepSeekReasoningEffort ?? _settings.deepSeekReasoningEffort;
    final catalogProvider =
        ModelCatalog.optionFor(_settings.effectiveModel)?.providerCode;
    // 目录缺失时只允许精确的 DeepSeek 双模式名称，由后端再核对最终服务商。
    final supportsEffort = ReasoningControlAdapter.supportsDeepSeekEffort(
      providerId: catalogProvider ?? 'deepseek',
      providerCode: catalogProvider,
      modelId: _settings.effectiveModel,
    );
    final policy = options.suppressReasoningControl
        ? ChatReasoningPolicy.providerDefault
        : options.reasoningPolicy == ChatReasoningPolicy.offIfSupported ||
                (supportsEffort && effort == DeepSeekReasoningEffort.off)
            ? ChatReasoningPolicy.offIfSupported
            : ChatReasoningPolicy.providerDefault;
    return {
      if (includeDefaultPolicy || policy != ChatReasoningPolicy.providerDefault)
        'reasoning_policy': _reasoningPolicy(policy),
      if (!options.suppressReasoningControl &&
          policy == ChatReasoningPolicy.providerDefault &&
          supportsEffort &&
          effort != null &&
          effort != DeepSeekReasoningEffort.off)
        'reasoning_effort': effort.wireValue,
    };
  }

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
  ]) {
    final model = _settings.effectiveModel;
    final catalogProvider = ModelCatalog.optionFor(model)?.providerCode;
    // 模型名只是客户端的候选判断；自有后端还会按最终解析的 provider 再过滤。
    // 目录明确归属其他服务商时提前移除，未知目录的 DeepSeek V4 交给后端决定。
    final preserveReasoning =
        (catalogProvider == null || catalogProvider == 'deepseek') &&
            (ModelCapabilities.isDeepSeekVisionModel(model) ||
                model.trim().toLowerCase() == 'deepseek-v4-pro');
    final messages = [
      ...history,
      {
        'role': 'user',
        'content':
            (attachments ?? const ChatAttachments()).buildUserContent(prompt),
      },
      ...extraMessages,
    ];
    return messages.map((message) {
      final copy = Map<String, dynamic>.from(message);
      if (!preserveReasoning ||
          copy['role'] != 'assistant' ||
          copy['reasoning_content'] is! String) {
        copy.remove('reasoning_content');
      }
      return copy;
    }).toList();
  }

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) async =>
      (await _completeWithUsage(
              prompt: prompt,
              history: history,
              attachments: attachments,
              options: const ChatRequestOptions(),
              timeout: timeout ?? const Duration(minutes: 2)))
          .content;

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      _completeWithUsage(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: const ChatRequestOptions(),
      );

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    required ChatRequestOptions options,
  }) =>
      _completeWithUsage(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: options,
      );

  Future<ChatCompletionResult> _completeWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    required ChatRequestOptions options,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    validateMaxOutputTokensOverride(options.maxOutputTokensOverride);
    return recoverChatRequest(
        () => _completeOnceWithUsage(
            prompt: prompt,
            history: history,
            attachments: attachments,
            options: options,
            timeout: timeout),
        options: options);
  }

  Future<ChatCompletionResult> _completeOnceWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    required ChatRequestOptions options,
    required Duration timeout,
  }) async {
    final maxTokens = _maxTokensFor(options);
    final uri = BackendConst.buildUri('/uapi/chat/completions');
    final messages = _buildMessages(prompt, history, attachments);
    final body = {
      'model': _settings.effectiveModel,
      'messages': messages,
      // 0 = 不限制：不带 max_tokens，用上游默认（避免长回复被截断）。
      if (maxTokens != null) 'max_tokens': maxTokens,
      // null = 不带 temperature，用上游默认。
      if (_settings.temperature != null) 'temperature': _settings.temperature,
      // null = 不带 top_p，用上游默认。
      if (_settings.topP != null) 'top_p': _settings.topP,
      ..._reasoningFields(options),
      if (options.profile != ChatRequestProfile.standard)
        'request_profile': _requestProfile(options.profile),
    };
    final loginSession = _BackendLoginSession.capture();
    final token = loginSession.token;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    };
    final response = await () async {
      final client = http.Client();
      var responseStarted = false;
      int? responseStatus;
      Map<String, String> responseHeaders = const {};
      try {
        final request = http.AbortableRequest('POST', uri,
            abortTrigger: options.abortTrigger)
          ..headers.addAll(headers)
          ..body = jsonEncode(body);
        return await () async {
          final streamed = await client.send(request);
          responseStatus = streamed.statusCode;
          responseHeaders = streamed.headers;
          return await http.Response.fromStream(
              http.StreamedResponse(streamed.stream.map((bytes) {
            if (streamed.statusCode >= 200 &&
                streamed.statusCode < 300 &&
                bytes.isNotEmpty) {
              responseStarted = true;
            }
            return bytes;
          }), streamed.statusCode, headers: streamed.headers));
        }()
            .timeout(timeout);
      } catch (error, stack) {
        if (responseStatus != null &&
            responseStatus != 200 &&
            responseStatus != 201 &&
            error is! http.RequestAbortedException) {
          if (responseStatus == 401) {
            _scheduleExpiredSessionLogout(loginSession);
            throw _expiredBackendLoginFailure;
          }
          throw _httpFailure(
              statusCode: responseStatus!,
              headers: responseHeaders,
              payload: null);
        }
        Error.throwWithStackTrace(
            _mapBackendTransportFailure(error,
                responseStarted: responseStarted),
            stack);
      } finally {
        client.close();
      }
    }();
    try {
      final payload = _decodeJsonBytes(response.bodyBytes);

      if (response.statusCode == 401) {
        if (_isTrustedUpstreamAuthEnvelope(payload, response.statusCode)) {
          throw _httpFailure(
            statusCode: response.statusCode,
            headers: response.headers,
            payload: payload,
          );
        }
        _scheduleExpiredSessionLogout(loginSession);
        throw _expiredBackendLoginFailure;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final result = payload;
        if (result == null) {
          throw const ChatTransportException(
              safeCode: 'invalid_response',
              safeMessage: '响应格式无效',
              responseStarted: true,
              failureStage: ChatFailureStage.decode,
              failureKind: ChatFailureKind.invalidPayload);
        }
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
        throw _sseFailure(result);
      }
      throw _httpFailure(
          statusCode: response.statusCode,
          headers: response.headers,
          payload: payload);
    } catch (error, stack) {
      Error.throwWithStackTrace(
          _mapBackendTransportFailure(error,
              responseStarted:
                  response.statusCode == 200 || response.statusCode == 201),
          stack);
    }
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
  }) =>
      chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: const ChatRequestOptions(),
      );

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) async* {
    yield* recoverChatStream(
        () => _streamOnceWithOptions(
            prompt: prompt,
            history: history,
            attachments: attachments,
            tools: tools,
            extraMessages: extraMessages,
            options: options),
        options: options);
  }

  Stream<StreamEvent> _streamOnceWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) async* {
    var responseStarted = false;
    final maxTokens = _maxTokensFor(options);
    final httpClient = http.Client();
    try {
      final uri = BackendConst.buildUri('/uapi/chat/completions/stream');
      final messages =
          _buildMessages(prompt, history, attachments, extraMessages);
      final body = {
        'model': _settings.effectiveModel,
        'messages': messages,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (_settings.temperature != null) 'temperature': _settings.temperature,
        if (_settings.topP != null) 'top_p': _settings.topP,
        if (tools != null && tools.isNotEmpty) 'tools': tools,
        'request_profile': _requestProfile(options.profile),
        ..._reasoningFields(options, includeDefaultPolicy: true),
      };
      final loginSession = _BackendLoginSession.capture();
      final token = loginSession.token;
      final request = http.AbortableRequest(
        'POST',
        uri,
        abortTrigger: options.abortTrigger,
      )
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${token ?? ''}',
        })
        ..body = jsonEncode(body);

      final streamedResponse =
          await httpClient.send(request).timeout(options.connectTimeout);
      AILogger.log('backend stream status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode != 200 &&
          streamedResponse.statusCode != 201) {
        List<int> bytes;
        try {
          bytes = await streamedResponse.stream.toBytes();
        } on http.RequestAbortedException {
          rethrow;
        } catch (_) {
          bytes = const [];
        }
        final payload = _decodeJsonBytes(bytes);
        if (streamedResponse.statusCode == 401 &&
            !_isTrustedUpstreamAuthEnvelope(
              payload,
              streamedResponse.statusCode,
            )) {
          _scheduleExpiredSessionLogout(loginSession);
          throw _expiredBackendLoginFailure;
        }
        throw _httpFailure(
          statusCode: streamedResponse.statusCode,
          headers: streamedResponse.headers,
          payload: payload,
        );
      }

      final lineStream = streamedResponse.stream
          .map((bytes) {
            if (bytes.isNotEmpty) responseStarted = true;
            return bytes;
          })
          .transform(const Utf8Decoder())
          .transform(const LineSplitter());
      final toolAcc = ToolCallAccumulator();
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
          throw _sseFailure(_decodeJsonObject(data));
        }
        if (data == '[DONE]') break;

        final decoded = _decodeJsonObject(data);
        if (decoded == null) continue;
        if (decoded['error'] != null || decoded['code'] == 'upstream_error') {
          throw _sseFailure(decoded);
        }
        final usageEvent = usageEventFromStreamJson(decoded);
        if (usageEvent != null) yield usageEvent;
        final choices = decoded['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices[0];
        if (choice is! Map<String, dynamic>) continue;
        final delta = choice['delta'];
        if (delta is! Map<String, dynamic>) continue;
        final reasoning = delta['reasoning_content'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield StreamEvent.reasoning(reasoning);
        }
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield StreamEvent.text(content);
        }
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
      for (final event in toolAcc.flush()) {
        yield event;
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
          _mapBackendTransportFailure(error, responseStarted: responseStarted),
          stackTrace);
    } finally {
      httpClient.close();
    }
  }

  int? _maxTokensFor(ChatRequestOptions options) {
    final exact =
        validateMaxOutputTokensOverride(options.maxOutputTokensOverride);
    if (exact != null) {
      return exact;
    }
    final requestedMinimum = options.minOutputTokens ?? 0;
    final value = _settings.maxOutputTokens >= requestedMinimum
        ? _settings.maxOutputTokens
        : requestedMinimum;
    return value > 0 ? value : null;
  }
}

const _expiredBackendLoginFailure = ChatTransportException(
    safeCode: 'authentication_error',
    safeMessage: '登录已过期，请重新登录',
    statusCode: 401,
    failureStage: ChatFailureStage.response,
    failureKind: ChatFailureKind.httpStatus);

class _BackendLoginSession {
  const _BackendLoginSession(this.storage, this.token, this.accountHash);

  factory _BackendLoginSession.capture() {
    final storage = LoginSdkConfig.instance.storage;
    return _BackendLoginSession(storage, storage.readTokenSync(),
        storage.readProfileSync()?['accountHash']?.toString());
  }

  final TokenStorage storage;
  final String? token;
  final String? accountHash;
}

void _scheduleExpiredSessionLogout(_BackendLoginSession session) {
  // 先交付 typed 401 并释放 HTTP/generator。logout ready hook 会等待任务收尾，
  // 若请求内部 await logout，则任务取消与 generator 会相互等待。
  unawaited(Future<void>(() async {
    try {
      await LoginDao.logOutIfSessionMatches(
          expectedStorage: session.storage,
          expectedToken: session.token,
          expectedAccountHash: session.accountHash);
    } catch (_) {
      AILogger.log('backend expired-session cleanup failed');
    }
  }));
}

ChatTransportException _mapBackendTransportFailure(Object error,
    {bool responseStarted = false}) {
  if (error is ChatTransportException) {
    return ChatTransportException(
        statusCode: error.statusCode,
        retryAfter: error.retryAfter,
        safeCode: error.safeCode,
        safeMessage: error.safeMessage,
        responseStarted: error.responseStarted || responseStarted,
        failureStage: error.failureStage,
        failureKind: error.failureKind);
  }
  if (error is http.RequestAbortedException) {
    return const ChatTransportException(
      safeCode: 'cancelled',
      safeMessage: '请求已取消',
    );
  }
  if (error is TimeoutException) {
    return ChatTransportException(
      responseStarted: responseStarted,
      failureStage: responseStarted
          ? ChatFailureStage.response
          : ChatFailureStage.connect,
      failureKind: ChatFailureKind.timeout,
      safeCode: 'timeout',
      safeMessage: '请求超时',
    );
  }
  if (error is http.ClientException ||
      error is SocketException ||
      error is TlsException ||
      error is HttpException) {
    return ChatTransportException(
      responseStarted: responseStarted,
      failureStage: responseStarted
          ? ChatFailureStage.response
          : ChatFailureStage.connect,
      failureKind: ChatFailureKind.transport,
      safeCode: 'network_error',
      safeMessage: '网络请求失败',
    );
  }
  return ChatTransportException(
    safeCode: error is FormatException ||
            (responseStarted && (error is TypeError || error is RangeError))
        ? 'invalid_response'
        : 'request_failed',
    safeMessage: '请求失败',
    responseStarted: responseStarted,
    failureStage:
        responseStarted ? ChatFailureStage.decode : ChatFailureStage.unknown,
    failureKind: error is FormatException
        ? ChatFailureKind.invalidPayload
        : error is TypeError
            ? ChatFailureKind.type
            : error is RangeError
                ? ChatFailureKind.range
                : error is StateError
                    ? ChatFailureKind.state
                    : ChatFailureKind.unknown,
  );
}

const _safeBackendCodes = {
  'unsupported_reasoning_control',
  'first_event_timeout',
  'idle_timeout',
  'total_timeout',
  'unknown_parameter',
  'unsupported_parameter',
  'invalid_request',
  'authentication_error',
  'rate_limited',
  'server_error',
  'request_failed',
  'insufficient_balance',
  'model_not_found',
};

String _requestProfile(ChatRequestProfile profile) => switch (profile) {
      ChatRequestProfile.standard => 'standard',
      ChatRequestProfile.translation => 'translation',
    };

String _reasoningPolicy(ChatReasoningPolicy policy) => switch (policy) {
      ChatReasoningPolicy.providerDefault => 'provider_default',
      ChatReasoningPolicy.offIfSupported => 'off_if_supported',
    };

ChatTransportException _httpFailure({
  required int statusCode,
  required Map<String, String> headers,
  required Map<String, dynamic>? payload,
}) {
  final safeCode =
      _safeCodeFromPayload(payload) ?? _safeCodeForBackendStatus(statusCode);
  return ChatTransportException(
    statusCode: statusCode,
    retryAfter:
        _retryAfterFromHeaders(headers) ?? _retryAfterFromPayload(payload),
    safeCode: safeCode,
    safeMessage: _safeBackendMessage(safeCode),
    failureStage: ChatFailureStage.response,
    failureKind: ChatFailureKind.httpStatus,
  );
}

ChatTransportException _sseFailure(Map<String, dynamic>? payload) {
  final statusCode = _safeStatusCode(payload?['statusCode']);
  final safeCode = _safeCodeFromPayload(payload) ??
      (statusCode == null
          ? 'request_failed'
          : _safeCodeForBackendStatus(statusCode));
  return ChatTransportException(
    statusCode: statusCode,
    retryAfter: _retryAfterFromPayload(payload),
    safeCode: safeCode,
    safeMessage: _safeBackendMessage(safeCode),
    failureStage: ChatFailureStage.response,
    failureKind: ChatFailureKind.httpStatus,
  );
}

Map<String, dynamic>? _decodeJsonBytes(List<int> bytes) {
  try {
    return _decodeJsonObject(const Utf8Decoder().convert(bytes));
  } on FormatException {
    return null;
  }
}

Map<String, dynamic>? _decodeJsonObject(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

String? _safeCodeFromPayload(Map<String, dynamic>? payload) {
  final value = payload?['safeCode'];
  return value is String && _safeBackendCodes.contains(value) ? value : null;
}

bool _isTrustedUpstreamAuthEnvelope(
  Map<String, dynamic>? payload,
  int httpStatusCode,
) =>
    httpStatusCode == 401 &&
    payload?['code'] == 'upstream_error' &&
    payload?['safeCode'] == 'authentication_error' &&
    _safeStatusCode(payload?['statusCode']) == httpStatusCode;

int? _safeStatusCode(Object? value) =>
    value is int && value >= 100 && value <= 599 ? value : null;

Duration? _retryAfterFromPayload(Map<String, dynamic>? payload) {
  final seconds = payload?['retryAfterSeconds'];
  if (seconds is! int || seconds < 0) return null;
  return Duration(seconds: _clampRetryAfterSeconds(seconds));
}

Duration? _retryAfterFromHeaders(Map<String, String> headers) {
  String? value;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'retry-after') value = entry.value;
  }
  if (value == null || !RegExp(r'^\d+$').hasMatch(value)) return null;
  final seconds = int.tryParse(value);
  return seconds == null
      ? null
      : Duration(seconds: _clampRetryAfterSeconds(seconds));
}

int _clampRetryAfterSeconds(int seconds) {
  if (seconds < 1) return 1;
  if (seconds > 120) return 120;
  return seconds;
}

String _safeCodeForBackendStatus(int statusCode) =>
    chatFailureCodeForStatus(statusCode) ?? 'request_failed';

String _safeBackendMessage(String safeCode) {
  switch (safeCode) {
    case 'unsupported_reasoning_control':
      return '上游不支持推理控制';
    case 'first_event_timeout':
      return '首个响应事件超时';
    case 'idle_timeout':
      return '上游响应空闲超时';
    case 'total_timeout':
      return '上游响应总时长超时';
    case 'unknown_parameter':
    case 'unsupported_parameter':
      return '上游不支持请求参数';
    case 'insufficient_balance':
      return '服务商余额不足';
    case 'model_not_found':
      return '模型或 API 路由不存在';
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
