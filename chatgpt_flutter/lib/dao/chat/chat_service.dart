import 'package:chatgpt_flutter/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_flutter/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_flutter/model/ai_settings.dart';

abstract class ChatService {
  Future<String?> chat({
    required String prompt,
    required List<Map<String, String>> history,
  });

  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, String>> history,
  });

  factory ChatService.from(AISettings s) {
    if (s.mode == AIMode.backend) return BackendChatService(s);
    return DirectChatService(s.activeLocal);
  }
}
