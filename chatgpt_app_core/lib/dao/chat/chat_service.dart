import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

abstract class ChatService {
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
  });

  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
  });

  factory ChatService.from(AISettings s) {
    if (s.mode == AIMode.backend) return BackendChatService(s);
    return DirectChatService(s.activeLocal);
  }
}
