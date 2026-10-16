import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';

/// 仅普通后端会话：会话→助手→全局。NULL legacy 只携原模型名到R1，
/// follow跳过本层旧model；现代非法/foreign原样交readiness/transport阻断。
/// 不使用本地providerId，不读取目录猜服务商，不写任何父层或持久化记录。
AISettings ordinaryBackendSettings(AISettings global,
    ConversationModel conversation, AssistantModel? assistant) {
  final next = global.clone();
  if (global.mode != AIMode.backend) return next;
  final layers = [
    (selection: conversation.backendSelection, legacy: conversation.modelId),
    (selection: assistant?.backendSelection, legacy: assistant?.model),
  ];
  for (final layer in layers) {
    final selection = layer.selection;
    if (selection != null) {
      if (selection.isFollow) continue;
      next.backendSelection = selection;
      return next;
    }
    final legacy = layer.legacy;
    if (legacy != null && legacy.trim().isNotEmpty) {
      next.backendSelection = null;
      next.backendModel = legacy;
      return next;
    }
  }
  return next;
}
