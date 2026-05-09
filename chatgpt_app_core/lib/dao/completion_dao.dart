import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

class CompletionDao {
  final ChatService chatService;
  final List<MessageModel> _messageList;

  CompletionDao({required AISettings settings, List<MessageModel>? messages})
      : chatService = ChatService.from(settings),
        _messageList = messages ?? [] {
    AILogger.log('init finish, loaded ${_messageList.length} messages');
  }

  ///当前历史消息列表，供重建 CompletionDao 时传递
  List<MessageModel> get currentMessages => List.unmodifiable(_messageList);

  ///和 AI 进行会话
  Future<String?> createCompletions({required String prompt}) async {
    final history = _buildHistory();
    var response = await chatService.chat(prompt: prompt, history: history);
    AILogger.log('ai response length: ${response?.length ?? 0}');
    return response;
  }

  ///流式会话，逐 token yield
  Stream<String> streamCompletions({required String prompt}) {
    final history = _buildHistory();
    return chatService.chatStream(prompt: prompt, history: history);
  }

  List<Map<String, String>> _buildHistory() {
    final history = <Map<String, String>>[];
    for (final m in _messageList) {
      history.add({
        'role': m.ownerType == OwnerType.sender ? 'user' : 'assistant',
        'content': m.content,
      });
    }
    return history;
  }
}
