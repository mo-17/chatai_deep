import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BackendChatService 可从流式 JSON 中解析 final usage 事件', () {
    final event = BackendChatService.usageEventFromStreamJson(const {
      'choices': [],
      'usage': {
        'prompt_tokens': 21,
        'prompt_tokens_details': {
          'cached_tokens': 8,
        },
        'completion_tokens': 9,
        'total_tokens': 30,
      },
    });

    expect(event, isNotNull);
    expect(event!.type, StreamEventType.usage);
    expect(event.promptTokens, 21);
    expect(event.cachedPromptTokens, 8);
    expect(event.completionTokens, 9);
  });

  test('BackendChatService 无 usage 的流式 JSON 不产生 usage 事件', () {
    final event = BackendChatService.usageEventFromStreamJson(const {
      'choices': [
        {
          'delta': {'content': '你好'}
        }
      ],
    });

    expect(event, isNull);
  });
}
