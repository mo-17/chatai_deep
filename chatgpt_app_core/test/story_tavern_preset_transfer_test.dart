import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/story_tavern_preset_transfer.dart';
import 'package:chatgpt_app_core/model/story_tavern_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StoryTavernPresetTransfer', () {
    test('识别 OpenAI preset，递归移除敏感、路由和执行字段', () {
      const source = '''
{
  "temperature": 1.25,
  "max_tokens": 4096,
  "api_key": "do-not-keep",
  "custom_url": "https://example.invalid",
  "model": "do-not-force-model",
  "chat_completion_source": "do-not-force-provider",
  "prompts": [{"identifier": "main", "content": "{{char}}", "regex": "never-run"}],
  "prompt_order": [{"character_id": 100000, "order": [{"identifier": "main", "enabled": true}]}],
  "nested": {"authorization": "Bearer hidden", "items": [{"proxy": "x", "script": "x", "safe": true}]}
}
''';

      final preview = StoryTavernPresetTransfer.previewJson(source);

      expect(preview.isAccepted, isTrue);
      expect(preview.kind, StoryTavernPresetKind.openAi);
      expect(preview.applyValues.temperature, 1.25);
      expect(preview.applyValues.maxTokens, 4096);
      expect(preview.openAiPromptData, {
        'prompts': [
          {'identifier': 'main', 'content': '{{char}}'},
        ],
        'prompt_order': [
          {
            'character_id': 100000,
            'order': [
              {'identifier': 'main', 'enabled': true},
            ],
          },
        ],
      });
      expect(preview.sanitizedJson, isNot(contains('do-not-keep')));
      expect(preview.sanitizedJson, isNot(contains('example.invalid')));
      expect(preview.sanitizedJson, isNot(contains('do-not-force-model')));
      expect(preview.sanitizedJson, isNot(contains('do-not-force-provider')));
      expect(preview.sanitized!['nested'], {
        'items': [
          {'safe': true},
        ],
      });
      expect(preview.warnings.join('\n'), contains('已移除'));
    });

    test('Context 和 Instruct 只保留不执行数据，不应用采样值', () {
      final context = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'story_string': '{{char}} says {{user}}',
        'temperature': 1.8,
        'macro': 'must-not-run',
      }));
      final instruct = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'input_sequence': 'User:',
        'output_sequence': 'Assistant:',
        'max_tokens': 500,
        'regex': 'must-not-compile',
      }));

      expect(context.kind, StoryTavernPresetKind.context);
      expect(context.applyValues.isEmpty, isTrue);
      expect(context.sanitized!['story_string'], '{{char}} says {{user}}');
      expect(context.sanitized, isNot(contains('macro')));
      expect(context.warnings.join(), contains('不执行'));
      expect(instruct.kind, StoryTavernPresetKind.instruct);
      expect(instruct.applyValues.isEmpty, isTrue);
      expect(instruct.sanitized, isNot(contains('regex')));
      expect(instruct.warnings.join(), contains('不执行'));
    });

    test('识别 TextGen sampler，且只提取受范围约束的采样值', () {
      final accepted = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'temp': '0.7',
        'max_new_tokens': 2048,
        'top_p': 0.9,
      }));
      final rejectedValues = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'temperature': 3,
        'max_tokens': 0,
      }));

      expect(accepted.kind, StoryTavernPresetKind.textgenSampler);
      expect(accepted.applyValues.temperature, 0.7);
      expect(accepted.applyValues.maxTokens, 2048);
      expect(rejectedValues.isAccepted, isTrue);
      expect(rejectedValues.applyValues.isEmpty, isTrue);
      expect(rejectedValues.warnings.join(), contains('未应用'));
    });

    test('拒绝超过 JSON 深度、数组、字符串和源文件大小的内容', () {
      dynamic deep = 'ok';
      for (var index = 0;
          index <= StoryTavernPresetTransfer.maxJsonDepth;
          index++) {
        deep = {'next': deep};
      }
      final tooDeep = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'story_string': 'x',
        'nested': deep,
      }));
      final tooMany = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'prompts': List.filled(StoryTavernPresetTransfer.maxArrayItems + 1, {}),
      }));
      final tooLong = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'story_string':
            'x' * (StoryTavernPresetTransfer.maxJsonStringChars + 1),
      }));
      final tooLarge = StoryTavernPresetTransfer.previewJson(
        ' ' * (StoryTavernPresetTransfer.maxSourceBytes + 1),
      );

      expect(tooDeep.isAccepted, isFalse);
      expect(tooMany.isAccepted, isFalse);
      expect(tooLong.isAccepted, isFalse);
      expect(tooLarge.isAccepted, isFalse);
    });

    test('安全 bundle 可 round-trip，且导入时仍会验证类型', () {
      final source = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'prompts': [
          {'identifier': 'main', 'content': 'hello'},
        ],
        'prompt_order': [],
        'temperature': 0,
        'max_tokens': 1,
        'token': 'redacted',
      }));

      final bundleJson = StoryTavernPresetTransfer.exportBundleJson(source);
      final restored = StoryTavernPresetTransfer.importBundleJson(bundleJson);
      final tampered = jsonDecode(bundleJson) as Map<String, dynamic>;
      tampered['kind'] = 'context';

      expect(restored.isAccepted, isTrue);
      expect(restored.kind, StoryTavernPresetKind.openAi);
      expect(restored.sanitized, source.sanitized);
      expect(restored.applyValues.temperature, 0);
      expect(restored.applyValues.maxTokens, 1);
      expect(
          StoryTavernPresetTransfer.importBundleJson(jsonEncode(tampered))
              .isAccepted,
          isFalse);
    });

    test('房间预设集合按类型合并并可整体导出导入', () {
      final context = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'story_string': '{{char}}',
      }));
      final sampler = StoryTavernPresetTransfer.previewJson(jsonEncode({
        'temp': 0.8,
        'max_new_tokens': 1024,
      }));
      var stored = StoryTavernPresetTransfer.mergeRoomBundle('', context);
      stored = StoryTavernPresetTransfer.mergeRoomBundle(stored, sampler);

      final restored = StoryTavernPresetTransfer.previewsFromRoomBundle(stored);
      final exported = StoryTavernPresetTransfer.exportRoomBundleJson(stored);
      final imported = StoryTavernPresetTransfer.previewImportFile(exported);

      expect(restored.map((item) => item.kind), [
        StoryTavernPresetKind.context,
        StoryTavernPresetKind.textgenSampler,
      ]);
      expect(
          imported.map((item) => item.kind), restored.map((item) => item.kind));
      expect(imported.last.applyValues.temperature, 0.8);
      expect(imported.last.applyValues.maxTokens, 1024);
      expect(
        StoryTavernPresetTransfer.previewImportFile('\uFEFF$exported')
            .map((item) => item.kind),
        restored.map((item) => item.kind),
      );
    });

    test('不可信持久化集合会重新清洗，非法类型与采样值会清空', () {
      final unsafe = jsonEncode({
        'format': StoryTavernPresetTransfer.roomBundleFormat,
        'formatVersion': StoryTavernPresetTransfer.roomBundleFormatVersion,
        'presets': {
          'openai': {
            'prompts': [],
            'prompt_order': [],
            'api_key': 'secret',
            'script': 'run()',
          },
        },
      });

      final normalized = StoryTavernPresetTransfer.normalizeRoomBundle(unsafe);

      expect(normalized, isNotEmpty);
      expect(normalized, isNot(contains('secret')));
      expect(normalized, isNot(contains('run()')));
      expect(StoryTavernPresetTransfer.normalizeRoomBundle({'bad': true}), '');
      expect(StoryTavernPresetTransfer.safeTemperature(2.1), isNull);
      expect(StoryTavernPresetTransfer.safeMaxTokens(0), isNull);
    });
  });
}
