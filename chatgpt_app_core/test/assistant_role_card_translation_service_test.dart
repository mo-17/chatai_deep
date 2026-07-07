import 'dart:async';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AssistantModel sampleAssistant() => AssistantModel(
        id: 7,
        name: 'Alice',
        emoji: '🎭',
        avatarType: 'image',
        avatarValue: '/tmp/alice.png',
        description: 'A detective from London.',
        prompt: 'You are a careful detective.',
        openingMessage: 'Good evening.',
        exampleDialogs: '<START>\nUser: Hello\nAlice: I observe first.',
        memoryBook: r'[re] ^Baker Street$ => Alice lives at Baker Street.',
        defaultVoiceStyle: 'custom_sherpa:voice-1',
        providerId: 'openrouter',
        model: 'anthropic/claude-sonnet',
        useTools: false,
        toolIds: ['web_search', 'knowledge_search'],
        createdAt: 100,
        updatedAt: 200,
      );

  test('translateToSimplifiedChinese applies only translated text fields',
      () async {
    final assistant = sampleAssistant();

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (_) async => '''
```json
{
  "name": "爱丽丝",
  "description": "一位来自伦敦的侦探。",
  "prompt": "你是一位细心的侦探。",
  "openingMessage": "晚上好。",
  "exampleDialogs": "<START>\\nUser: 你好\\nAlice: 我先观察。",
  "memoryBook": "[re] ^Baker Street\$ => 爱丽丝住在贝克街。",
  "providerId": "should-not-apply",
  "model": "should-not-apply",
  "defaultVoiceStyle": "should-not-apply"
}
```
''',
    );

    expect(translated.name, '爱丽丝');
    expect(translated.description, '一位来自伦敦的侦探。');
    expect(translated.prompt, '你是一位细心的侦探。');
    expect(translated.openingMessage, '晚上好。');
    expect(translated.exampleDialogs, contains('我先观察'));
    expect(translated.memoryBook, contains('爱丽丝住在贝克街'));

    expect(translated.id, assistant.id);
    expect(translated.emoji, assistant.emoji);
    expect(translated.avatarType, assistant.avatarType);
    expect(translated.avatarValue, assistant.avatarValue);
    expect(translated.defaultVoiceStyle, assistant.defaultVoiceStyle);
    expect(translated.providerId, assistant.providerId);
    expect(translated.model, assistant.model);
    expect(translated.useTools, assistant.useTools);
    expect(translated.toolIds, assistant.toolIds);
    expect(translated.createdAt, assistant.createdAt);
    expect(translated.updatedAt, assistant.updatedAt);
  });

  test('applyTranslatedFields keeps original value when a field is missing',
      () {
    final assistant = sampleAssistant();

    final translated =
        AssistantRoleCardTranslationService.applyTranslatedFields(
      assistant,
      {'name': '爱丽丝'},
    );

    expect(translated.name, '爱丽丝');
    expect(translated.prompt, assistant.prompt);
    expect(translated.memoryBook, assistant.memoryBook);
  });

  test('整卡翻译超时后会降级为分字段翻译', () async {
    final assistant = sampleAssistant();
    var calls = 0;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (prompt) async {
        calls++;
        if (calls == 1) throw TimeoutException('whole card timeout');
        if (prompt.contains('"name"')) return '{"name":"爱丽丝"}';
        if (prompt.contains('"description"')) {
          return '{"description":"一位来自伦敦的侦探。"}';
        }
        if (prompt.contains('"prompt"')) return '{"prompt":"你是一位细心的侦探。"}';
        if (prompt.contains('"openingMessage"')) {
          return '{"openingMessage":"晚上好。"}';
        }
        if (prompt.contains('"exampleDialogs"')) {
          return '{"exampleDialogs":"用户：你好\\n爱丽丝：我先观察。"}';
        }
        if (prompt.contains('"memoryBook"')) {
          return '{"memoryBook":"[re] ^Baker Street\$ => 爱丽丝住在贝克街。"}';
        }
        return '{}';
      },
    );

    expect(calls, greaterThan(1));
    expect(translated.name, '爱丽丝');
    expect(translated.description, '一位来自伦敦的侦探。');
    expect(translated.memoryBook, contains('爱丽丝住在贝克街'));
  });

  test('分字段翻译会拆分过长 memoryBook', () async {
    final assistant = AssistantModel(
      name: 'Alice',
      memoryBook: List.generate(
        80,
        (index) =>
            'key$index => Alice has a very long memory entry number $index.',
      ).join('\n'),
    );
    final memoryPrompts = <String>[];
    var calls = 0;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (prompt) async {
        calls++;
        if (calls == 1) throw TimeoutException('whole card timeout');
        if (prompt.contains('"name"') &&
            !prompt.contains('"memoryBook"') &&
            !prompt.contains('"description"')) {
          return '{"name":"爱丽丝"}';
        }
        if (prompt.contains('"memoryBook"')) {
          memoryPrompts.add(prompt);
          final start = prompt.indexOf('{');
          final payload = prompt.substring(start);
          return payload.replaceAll('Alice has', '爱丽丝有');
        }
        throw TimeoutException('force fallback');
      },
    );

    expect(memoryPrompts.length, greaterThan(1));
    expect(translated.memoryBook, contains('爱丽丝有'));
    expect(translated.memoryBook.split('\n'), hasLength(80));
  });

  test('decodeTranslation rejects non json output', () {
    expect(
      () => AssistantRoleCardTranslationService.decodeTranslation('已翻译完成'),
      throwsFormatException,
    );
  });

  test('buildPrompt asks model to preserve runtime configuration', () {
    final prompt =
        AssistantRoleCardTranslationService.buildPrompt(sampleAssistant());

    expect(prompt, contains('只返回一个 JSON 对象'));
    expect(prompt, contains('不要添加、删除或改写工具 ID、模型 ID、服务商 ID、语音 ID'));
    expect(prompt, contains('"name":"Alice"'));
    expect(prompt, isNot(contains('custom_sherpa:voice-1')));
    expect(prompt, isNot(contains('anthropic/claude-sonnet')));
  });
}
