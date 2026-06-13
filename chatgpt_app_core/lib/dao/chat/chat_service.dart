import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';

abstract class ChatService {
  /// 当前生效模型的能力探测结果（阶段三）。UI 据此开关图片/PDF/工具入口，
  /// 上层无需关心背后是 OpenAI / DeepSeek / 后端代理。
  ModelCapabilities get capabilities;

  /// 当前轮可携带附件（阶段四）：图片多模态 / 原生文件 / 降级抽取的文本。
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
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

  factory ChatService.from(AISettings s) {
    if (s.mode == AIMode.backend) return BackendChatService(s);
    // 把本地服务商 code（'openai'/'deepseek'）一并传入，供能力探测按厂商区分。
    return DirectChatService(s.activeLocal,
        providerCode: providerCodeFor(s), maxOutputTokens: s.maxOutputTokens);
  }

  /// providerCode 派生规则的唯一出处：本地模式用所选服务商 code，
  /// 后端模式不传（由 ModelCatalog 按 modelId 从清单反查）。
  static String? providerCodeFor(AISettings s) =>
      s.mode == AIMode.local ? s.localProvider.name : null;

  /// 从 [AISettings] 直接算能力位（与 `ChatService.from(s).capabilities` 同源）。
  /// UI 在 build 里同步调用它即可随 settings 变化实时刷新入口开关。
  static ModelCapabilities capabilitiesFor(AISettings s) =>
      ModelCatalog.capabilitiesFor(
        s.effectiveModel,
        providerCode: providerCodeFor(s),
      );
}
