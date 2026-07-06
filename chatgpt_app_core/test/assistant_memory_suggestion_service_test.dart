import 'package:chatgpt_app_core/chat/application/assistant_memory_suggestion_service.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('明显用户偏好会生成长期记忆候选', () {
    expect(
      AssistantMemorySuggestionService.suggestFromUserMessage(
        '我喜欢简短直接的回答',
        const [],
      ),
      '我喜欢简短直接的回答',
    );
  });

  test('显式请记住会去掉指令前缀', () {
    expect(
      AssistantMemorySuggestionService.suggestFromUserMessage(
        '请记住：我叫阿斌',
        const [],
      ),
      '我叫阿斌',
    );
  });

  test('普通问题和过长文本不会生成候选', () {
    expect(
      AssistantMemorySuggestionService.suggestFromUserMessage(
        '怎么写一个 Flutter 页面？',
        const [],
      ),
      isNull,
    );
    expect(
      AssistantMemorySuggestionService.suggestFromUserMessage(
        '我喜欢${'很'.padRight(140, '长')}的回答',
        const [],
      ),
      isNull,
    );
  });

  test('已存在的长期记忆不会重复建议', () {
    final existing = [
      AssistantMemoryModel(assistantId: 1, content: '我喜欢 简短直接的回答'),
    ];

    expect(
      AssistantMemorySuggestionService.suggestFromUserMessage(
        ' 我喜欢\n简短直接的回答 ',
        existing,
      ),
      isNull,
    );
  });
}
