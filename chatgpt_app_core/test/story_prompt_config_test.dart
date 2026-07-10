import 'dart:convert';

import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StoryPromptConfigCodec', () {
    test('旧空值恢复默认 built-in 顺序并可 round-trip', () {
      final config = StoryPromptConfigCodec.decode('  ');

      expect(
        config.modules.map((module) => module.builtInSlot),
        StoryPromptBuiltInSlot.defaultOrder,
      );
      expect(
        StoryPromptConfigCodec.decode(StoryPromptConfigCodec.encode(config))
            .toJson(),
        config.toJson(),
      );
    });

    test('安全解析 JSON，跳过损坏和重复稳定 key，并限制模块数量', () {
      final raw = <Object?>[
        {'key': 'valid', 'content': '保留'},
        {'key': '', 'content': '无稳定 key'},
        {'key': 'valid', 'content': '重复 key'},
        'not-a-map',
        for (var index = 0; index < 50; index++)
          {'key': 'module-$index', 'content': '内容 $index'},
      ];

      final config = StoryPromptConfigCodec.decode(jsonEncode(raw));

      expect(config.modules, hasLength(StoryPromptLimits.maxModules));
      expect(config.modules.first.key, 'valid');
      expect(config.modules.map((module) => module.key), isNot(contains('')));
      expect(StoryPromptConfigCodec.decode('{broken-json').modules,
          StoryPromptConfigCodec.defaultModules);
    });

    test('兼容旧字段、规整 role/placement/depth，并裁剪超长内容', () {
      final config = StoryPromptConfigCodec.decode({
        'modules': [
          {
            'key': 'legacy-slot',
            'slot': 'legacy_runtime',
            'customContent': 'x' * (StoryPromptLimits.maxContentLength + 5),
            'enabled': '0',
            'role': 'unknown',
            'placement': 'history_depth',
            'depth': 999,
            'order': '4',
          },
        ],
      });
      final module = config.modules.single;

      expect(module.builtInSlot, 'legacy_runtime');
      expect(module.content.length, StoryPromptLimits.maxContentLength);
      expect(module.enabled, isFalse);
      expect(module.role, StoryPromptRole.system);
      expect(module.placement, StoryPromptPlacement.historyDepth);
      expect(module.depth, StoryPromptLimits.maxDepth);
      expect(module.sortOrder, 4);
    });

    test('解析 Tavern Prompt Manager 顺序、内置槽和 in-chat 自定义提示', () {
      final config = StoryPromptConfigCodec.fromTavernExtensions({
        'prompt_manager': {
          'prompts': [
            {
              'identifier': 'main',
              'content': '始终保持 {{char}} 的身份。',
              'role': 'system',
            },
            {
              'identifier': 'weather-note',
              'content': '{{room}} 正在下雨。',
              'role': 'user',
              'position': 'in_chat',
              'depth': 2,
            },
          ],
        },
        'prompt_order': {
          'weather-note': 5,
          'main': 10,
          'chat_history': 20,
        },
      });

      final rules = config.modules.singleWhere(
        (item) => item.builtInSlot == StoryPromptBuiltInSlot.rules,
      );
      final custom = config.modules.singleWhere(
        (item) => item.key == 'tavern.weather-note',
      );
      expect(rules.content, contains('{{char}}'));
      expect(custom.placement, StoryPromptPlacement.historyDepth);
      expect(custom.depth, 2);
      expect(custom.sortOrder, lessThan(rules.sortOrder));
    });
  });

  group('StoryPromptComposer', () {
    test('编排 built-in/custom 内容，替换变量，并按 placement/sort/depth 输出', () {
      const config = StoryPromptConfig(modules: [
        StoryPromptModule(
          key: 'custom-system',
          content: '{{char}} 在 {{room}} 等待 {{user}}。',
          sortOrder: 20,
        ),
        StoryPromptModule(
          key: 'builtin-and-custom',
          builtInSlot: 'speaker',
          content: '补充：{{char}} 保持一致。',
          role: StoryPromptRole.assistant,
          sortOrder: 10,
        ),
        StoryPromptModule(
          key: 'depth-two',
          content: '两轮前提示',
          placement: StoryPromptPlacement.historyDepth,
          depth: 2,
          sortOrder: 5,
        ),
        StoryPromptModule(
          key: 'disabled',
          content: '不可见',
          enabled: false,
        ),
      ]);

      final result = StoryPromptComposer.compose(
        config,
        builtInSlots: const {'speaker': '内置 {{char}}'},
        variables: const StoryPromptVariables(
          character: '艾琳',
          user: '阿青',
          room: '雨夜书店',
        ),
      );

      expect(result.systemMessages.map((message) => message.key),
          ['builtin-and-custom', 'custom-system']);
      expect(result.systemMessages.first.role, StoryPromptRole.assistant);
      expect(result.systemMessages.first.content, '内置 艾琳\n\n补充：艾琳 保持一致。');
      expect(result.systemMessages.last.content, '艾琳 在 雨夜书店 等待 阿青。');
      expect(result.historyDepthMessages.single.depth, 2);
      expect(result.messages, hasLength(3));
    });

    test('未解析的 builtin slot 不产出空消息，custom 内容仍可独立生效', () {
      const config = StoryPromptConfig(modules: [
        StoryPromptModule(key: 'missing', builtInSlot: 'not-provided'),
        StoryPromptModule(
          key: 'fallback-custom',
          builtInSlot: 'not-provided',
          content: '只使用自定义内容',
        ),
      ]);

      final result = StoryPromptComposer.compose(config);

      expect(result.systemMessages.map((message) => message.key),
          ['fallback-custom']);
      expect(result.systemMessages.single.content, '只使用自定义内容');
    });
  });
}
