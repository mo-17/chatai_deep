import 'dart:async';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_preview_store.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/tool_call_accumulator.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

class DirectChatService
    implements
        ChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  final ProviderConfig _cfg;

  final DeepSeekAttachmentAdapter? _injectedAttachmentAdapter;
  final String? _previewAccountHash;
  final bool _explicitPreviewAccount;
  final DeepSeekFilePreviewStore _previewStore;

  /// 上传缓存跟随当前凭据和请求地址的服务实例，不将上游 file_id 写入本地消息。
  late final DeepSeekAttachmentAdapter? _attachmentAdapter =
      _injectedAttachmentAdapter ??
          (_usesDeepSeekFiles
              ? DeepSeekAttachmentAdapter(
                  chatCompletionsUrl: _cfg.baseUrl,
                  apiKey: _cfg.apiKey,
                  onUploaded: _saveUploadedPreview,
                )
              : null);

  bool get _usesDeepSeekFiles {
    final uri = Uri.tryParse(_cfg.baseUrl);
    return uri?.scheme == 'https' &&
        uri?.host.toLowerCase() == 'api.deepseek.com' &&
        capabilities.image;
  }

  Map<String, dynamic> _requestFields(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic> extraBody = const {},
  }) {
    final firstParty = _providerId == 'deepseek' ||
        (_providerId == null && _providerCode == 'deepseek') ||
        Uri.tryParse(_cfg.baseUrl)?.host.toLowerCase() == 'api.deepseek.com';
    final hasToolHistory = messages.any((message) =>
        message['role'] == 'assistant' &&
        message['tool_calls'] is List &&
        (message['tool_calls'] as List).isNotEmpty);
    // 当前工具历史未保存 reasoning_content。Flash 工具回路改用非思考模式，
    // 避免下一轮因缺少思考回传被拒绝；普通图片问答仍保留上游默认思考模式。
    final disableThinking = firstParty &&
        ModelCapabilities.isDeepSeekVisionModel(_cfg.model) &&
        ((tools?.isNotEmpty ?? false) || hasToolHistory);
    return {
      ...extraBody,
      if (disableThinking) 'thinking': {'type': 'disabled'},
    };
  }

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
    ProviderConfig cfg, {
    String? providerId,
    String? providerCode,
    int maxOutputTokens = 0,
    double? temperature,
    double? topP,
    DeepSeekAttachmentAdapter? attachmentAdapter,
    String? previewAccountHash,
    DeepSeekFilePreviewStore? previewStore,
  })  : _cfg = ProviderConfig(
          apiKey: cfg.apiKey,
          baseUrl: cfg.baseUrl,
          model: cfg.model,
        ),
        _injectedAttachmentAdapter = attachmentAdapter,
        _previewAccountHash =
            previewAccountHash ?? _currentPreviewAccountHash(),
        _explicitPreviewAccount = previewAccountHash != null,
        _previewStore = previewStore ?? DeepSeekFilePreviewStore.instance,
        _providerId = providerId,
        _providerCode = providerCode,
        _maxOutputTokens = maxOutputTokens,
        _temperature = temperature,
        _topP = topP;

  static String? _currentPreviewAccountHash() {
    // getter 只读取已存在的 provider；不可在纯 transport 构造时触发登录/缓存初始化。
    return AISettingsProvider.instance?.accountHash;
  }

  Future<void> _saveUploadedPreview(
      DeepSeekUploadedFile file, Uint8List bytes) async {
    final account = _previewAccountHash;
    if (account == null || account.trim().isEmpty) return;
    Future<void> save() => _previewStore.save(
          accountHash: account,
          chatCompletionsUrl: _cfg.baseUrl,
          apiKey: _cfg.apiKey,
          fileId: file.id,
          bytes: bytes,
          shouldSave: () =>
              !(_attachmentAdapter?.isFileDeleted(file.id) ?? false),
        );
    if (_explicitPreviewAccount) {
      await save();
    } else {
      // 网络等待不持有账号 lease；响应回来后仅在原账号仍有效时写缓存。
      await LoginDao.runWithStableAccount(
          expectedAccountHash: account, action: save);
    }
  }

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
  Future<List<Map<String, dynamic>>> _buildMessages(
    String prompt,
    List<Map<String, dynamic>> history,
    ChatAttachments? attachments, [
    List<Map<String, dynamic>> extraMessages = const [],
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
  ]) async {
    final messages = <Map<String, dynamic>>[
      ...history,
      {
        'role': 'user',
        'content':
            (attachments ?? const ChatAttachments()).buildUserContent(prompt),
      },
      ...extraMessages,
    ];
    final adapter = _attachmentAdapter;
    if (adapter == null) return messages;
    return await adapter.prepareMessages(messages,
        abortTrigger: abortTrigger, onProgress: onProgress);
  }

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
    final messages = await _buildMessages(prompt, history, attachments);
    final response = await completion.createChat(
      model: _cfg.model,
      messages: messages,
      extraBody: _requestFields(messages),
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
  }) =>
      _completeWithUsage(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: const ChatRequestOptions());

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    required ChatRequestOptions options,
  }) async {
    // 与流式入口一致，非法预算在上传图片前直接拒绝。
    validateMaxOutputTokensOverride(options.maxOutputTokensOverride);
    try {
      return await _completeWithUsage(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: options);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
          _mapTransportFailure(error, reasoningControlAttached: false),
          stackTrace);
    }
  }

  Future<ChatCompletionResult> _completeWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    required ChatRequestOptions options,
  }) async {
    _ensureApiKey();
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = await _buildMessages(prompt, history, attachments,
        const [], options.abortTrigger, options.onProgress);
    await _checkRequestAbort(options.abortTrigger);
    reportChatSendProgress(options.onProgress, const ChatSendProgress('等待回答'));
    final reasoning = ReasoningControlAdapter.resolve(
        providerId: _providerId,
        providerCode: _providerCode,
        modelId: _cfg.model,
        policy: options.reasoningPolicy,
        suppressed: options.suppressReasoningControl);
    final response = await _awaitUnlessAborted(
        completion.createChat(
          model: _cfg.model,
          messages: messages,
          extraBody:
              _requestFields(messages, extraBody: reasoning.requestFields),
          maxTokens: _maxTokensFor(options),
          temperature: _temperature,
          topP: _topP,
        ),
        options.abortTrigger);
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
    final messages = await _buildMessages(prompt, history, attachments);
    yield* completion.createChatStream(
      model: _cfg.model,
      messages: messages,
      extraBody: _requestFields(messages),
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
    final maxTokens = _maxTokensFor(options);
    var reasoningControlAttached = false;
    try {
      _ensureApiKey();
      final reasoning = ReasoningControlAdapter.resolve(
        providerId: _providerId,
        providerCode: _providerCode,
        modelId: _cfg.model,
        policy: options.reasoningPolicy,
        suppressed: options.suppressReasoningControl,
      );
      reasoningControlAttached = reasoning.requestFields.isNotEmpty;
      final events = _createStreamEvents(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        maxTokens: maxTokens,
        extraBody: reasoning.requestFields,
        abortTrigger: options.abortTrigger,
        connectTimeout: options.connectTimeout,
        onProgress: options.onProgress,
      );
      await for (final event in events) {
        yield event;
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _mapTransportFailure(
          error,
          reasoningControlAttached: reasoningControlAttached,
        ),
        stackTrace,
      );
    }
  }

  int? _maxTokensFor(ChatRequestOptions options) {
    final exact =
        validateMaxOutputTokensOverride(options.maxOutputTokensOverride);
    if (exact != null) {
      return exact;
    }
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
    ChatSendProgressCallback? onProgress,
  }) async* {
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = await _buildMessages(
        prompt, history, attachments, extraMessages, abortTrigger, onProgress);
    await _checkRequestAbort(abortTrigger);
    reportChatSendProgress(onProgress, const ChatSendProgress('等待回答'));
    // 工具调用分片按 index 累积，流结束后再发完整 toolCall 事件（阶段六）。
    final toolAcc = ToolCallAccumulator();
    await for (final chunk in completion.createChatStreamEvents(
      model: _cfg.model,
      messages: messages,
      maxTokens: maxTokens,
      temperature: _temperature,
      topP: _topP,
      tools: tools,
      extraBody: _requestFields(messages, tools: tools, extraBody: extraBody),
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

Future<void> _checkRequestAbort(Future<void>? abortTrigger) async {
  if (abortTrigger == null) return;
  var aborted = false;
  unawaited(abortTrigger.then((_) => aborted = true));
  await Future<void>.value();
  if (aborted) throw http.RequestAbortedException();
}

Future<T> _awaitUnlessAborted<T>(
    Future<T> request, Future<void>? abortTrigger) {
  if (abortTrigger == null) return request;
  // 旧 SDK 非流式接口没有传输取消参数；抑制迟到结果，底层仍按原超时收尾。
  return Future.any<T>([
    request,
    abortTrigger.then<T>((_) => throw http.RequestAbortedException()),
  ]);
}

ChatTransportException _mapTransportFailure(
  Object error, {
  required bool reasoningControlAttached,
}) {
  if (error is ChatTransportException) return error;
  if (error is DeepSeekFileException) {
    return ChatTransportException(
        safeCode: 'attachment_upload_failed', safeMessage: error.message);
  }
  if (error is AIRequestCancelledException ||
      error is http.RequestAbortedException) {
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
    final upstreamCode = error.safeCode ?? _safeCodeForStatus(error.statusCode);
    final code = reasoningControlAttached &&
            ReasoningControlAdapter.isExplicitUnsupportedParameter(
              statusCode: error.statusCode,
              safeErrorCode: upstreamCode,
            )
        ? 'unsupported_reasoning_control'
        : upstreamCode;
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
    case 'unsupported_reasoning_control':
      return '上游不支持推理控制';
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
