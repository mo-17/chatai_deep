import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';

class ChatCompletionResult {
  final String? content;
  final int? promptTokens;
  final int? cachedPromptTokens;
  final int? completionTokens;

  /// 该轮 token 是否为估算：true 说明未拿到 provider 真实 usage。
  final bool estimated;

  /// 该轮的成本估算值（当前由成本估算模型给出）
  final double cost;

  const ChatCompletionResult({
    required this.content,
    this.promptTokens,
    this.cachedPromptTokens,
    this.completionTokens,
    this.estimated = false,
    this.cost = 0,
  });
}

abstract class ChatService {
  /// 当前生效模型的能力探测结果（阶段三）。UI 据此开关图片/PDF/工具入口，
  /// 上层无需关心背后是 OpenAI / DeepSeek / 后端代理。
  ModelCapabilities get capabilities;

  /// 当前轮可携带附件（阶段四）：图片多模态 / 原生文件 / 降级抽取的文本。
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  });

  /// 仅文本的流式（保留向后兼容）。新的块化分发请用 [chatStreamEvents]。
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  });

  /// 「带类型」的流式：正文与推理分别 yield 成 [StreamEvent]，
  /// 供 StreamDispatcher 落到 mainText / thinking 块。
  ///
  /// 工具调用（阶段六）：[tools] 为 OpenAI function declarations，传入后
  /// 模型可能不输出正文而发起调用 —— 实现层把 `delta.tool_calls` 分片
  /// 累积完整后，在流结束前 yield [StreamEvent.toolCall]。
  /// [extraMessages] 追加在当前轮 user 消息之后（assistant tool_calls 回灌
  /// + role:tool 结果），供 ToolLoopRunner 续轮请求使用。
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  });

  /// 非流式带 usage 的调用。
  ///
  /// 约定是「按调用成功回传文本 + prompt / completion token」；
  /// 不支持的 provider 或 SDK 版本可直接返回 content，usage 留空。
  /// [estimated] 表示 usage 由本地估算而非 provider 实际返回。
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async {
    final content = await chat(
      prompt: prompt,
      history: history,
      attachments: attachments,
    );
    return ChatCompletionResult(content: content, estimated: true);
  }

  factory ChatService.from(AISettings s) {
    if (s.mode == AIMode.backend) return BackendChatService(s);
    // 把本地服务商 code（'openai'/'deepseek'）一并传入，供能力探测按厂商区分。
    return DirectChatService(s.activeLocal,
        providerId: s.activeProvider.id,
        providerCode: providerCodeFor(s),
        maxOutputTokens: s.maxOutputTokens,
        temperature: s.temperature,
        topP: s.topP);
  }

  /// providerCode 派生规则的唯一出处：本地模式用激活服务商的 code，
  /// 后端模式不传（由 ModelCatalog 按 modelId 从清单反查）。
  static String? providerCodeFor(AISettings s) =>
      s.mode == AIMode.local ? s.activeProviderCode : null;

  /// 从 [AISettings] 直接算能力位（与 `ChatService.from(s).capabilities` 同源）。
  /// UI 在 build 里同步调用它即可随 settings 变化实时刷新入口开关。
  static ModelCapabilities capabilitiesFor(AISettings s) =>
      ModelCatalog.capabilitiesFor(
        s.effectiveModel,
        providerCode: providerCodeFor(s),
      );
}

/// 可选的 options-aware transport 能力。
///
/// 现有 fake 多数以 `implements ChatService` 实现；Dart 不会为 `implements`
/// 继承 concrete member，因此不能直接给 [ChatService] 增加成员而要求所有 fake
/// 改签名。Direct/Backend 实现本接口，旧实现则由下面 extension 委托旧入口。
abstract interface class OptionsAwareChatService {
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  });
}

extension ChatServiceRequestOptionsExtension on ChatService {
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) {
    final service = this;
    if (service is OptionsAwareChatService) {
      return (service as OptionsAwareChatService).chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: options,
      );
    }
    return chatStreamEvents(
      prompt: prompt,
      history: history,
      attachments: attachments,
      tools: tools,
      extraMessages: extraMessages,
    );
  }
}
