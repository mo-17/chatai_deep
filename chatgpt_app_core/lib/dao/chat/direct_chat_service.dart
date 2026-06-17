import 'package:chatgpt_app_core/chat/application/tool_call_accumulator.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

class DirectChatService implements ChatService {
  final ProviderConfig _cfg;

  /// 本地服务商 code（'openai'/'deepseek'），供能力探测按厂商区分。
  final String? _providerCode;

  /// 最大输出 token 数，0 = 不限制（不发 max_tokens，用上游默认）。
  /// 之前写死 1000 会截断长回复（推理模型的思考也计入），现由设置驱动。
  final int _maxOutputTokens;

  /// 采样温度，null = 不发送（用上游默认）。0.0 是有效值，故用 null 作哨兵。
  final double? _temperature;

  DirectChatService(this._cfg,
      {String? providerCode, int maxOutputTokens = 0, double? temperature})
      : _providerCode = providerCode,
        _maxOutputTokens = maxOutputTokens,
        _temperature = temperature;

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
          'content': (attachments ?? const ChatAttachments())
              .buildUserContent(prompt),
        },
        ...extraMessages,
      ];

  @override
  Future<String?> chat({
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
    );
    final choices = response.choices?.first;
    return choices?.message?.content;
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
    final config = AIConfigBuilder(
      apiKey: _cfg.apiKey,
      chatUrl: _cfg.baseUrl,
    );
    final completion = AICompletion(config);
    final messages = _buildMessages(prompt, history, attachments, extraMessages);
    // 工具调用分片按 index 累积，流结束后再发完整 toolCall 事件（阶段六）。
    final toolAcc = ToolCallAccumulator();
    await for (final chunk in completion.createChatStreamEvents(
      model: _cfg.model,
      messages: messages,
      maxTokens: _maxTokensOrNull,
      temperature: _temperature,
      tools: tools,
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
      }
    }
    for (final e in toolAcc.flush()) {
      yield e;
    }
  }
}
