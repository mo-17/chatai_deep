import 'dart:convert';

import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StoryRegexScriptsCodec', () {
    test('安全解析自身 JSON，限制并跳过损坏规则', () {
      final scripts = StoryRegexScriptsCodec.decode(jsonEncode({
        'rules': [
          {
            'key': 'clean-input',
            'name': 'Clean input',
            'stage': 'userInput',
            'find': r'\\s+',
            'replace': ' ',
            'trimStrings': [' '],
            'sortOrder': '2',
          },
          {
            'key': 'bad',
            'name': 'Bad',
            'stage': 'unknown',
            'find': 'x',
          },
          {
            'key': 'clean-input',
            'name': 'Duplicate',
            'stage': 'assistantDisplay',
            'find': 'x',
          },
          for (var i = 0; i < 80; i++)
            {
              'key': 'rule-$i',
              'name': 'Rule $i',
              'stage': 'assistantDisplay',
              'find': 'x',
            },
        ],
      }));

      expect(scripts.rules, hasLength(StoryRegexScriptLimits.maxRules));
      expect(scripts.rules.first.key, 'clean-input');
      expect(scripts.rules.first.stage, StoryRegexStage.userInput);
      expect(scripts.rules.first.sortOrder, 2);
      expect(scripts.rules.map((rule) => rule.key), isNot(contains('bad')));
      expect(StoryRegexScriptsCodec.decode('{broken').rules, isEmpty);
    });

    test('round-trip preserves the controlled declarative fields', () {
      const scripts = StoryRegexScripts(rules: [
        StoryRegexScript(
          key: 'display',
          name: 'Display cleanup',
          stage: StoryRegexStage.assistantDisplay,
          find: r'foo',
          replace: 'bar',
          trimStrings: ['\\n'],
          enabled: false,
          sortOrder: 10,
        ),
      ]);

      expect(
        StoryRegexScriptsCodec.decode(StoryRegexScriptsCodec.encode(scripts))
            .toJson(),
        scripts.toJson(),
      );
    });

    test('导入 Tavern regex_scripts，只映射 placement 1 和 2', () {
      final scripts = StoryRegexScriptsCodec.fromTavernExtensions({
        'regex_scripts': [
          {
            'scriptName': 'Normalize',
            'findRegex': 'foo',
            'replaceString': 'bar',
            'placement': [1, 2, 3],
            'trimStrings': ['!'],
            'markdownOnly': true,
            'promptOnly': false,
          },
          {
            'scriptName': 'Disabled',
            'findRegex': 'x',
            'replaceString': 'y',
            'placement': 2,
            'disabled': true,
          },
          {
            'scriptName': 'Unsupported',
            'findRegex': 'x',
            'replaceString': 'y',
            'placement': 4,
          },
          {
            'scriptName': 'Prompt only',
            'findRegex': 'secret',
            'replaceString': '',
            'placement': 2,
            'promptOnly': true,
          },
        ],
      });

      expect(scripts.rules, hasLength(2));
      expect(
        scripts.rules.map((rule) => rule.stage),
        [StoryRegexStage.assistantDisplay, StoryRegexStage.assistantOutput],
      );
      expect(scripts.rules[0].find, 'foo');
      expect(scripts.rules[0].replace, 'bar');
      expect(scripts.rules[0].trimStrings, ['!']);
      expect(scripts.rules.last.enabled, isFalse);
      expect(scripts.rules.map((rule) => rule.name),
          isNot(contains('Unsupported')));
      expect(scripts.rules.map((rule) => rule.name),
          isNot(contains('Prompt only')));
    });

    test('Tavern 斜杠正则解析 i/m/s flags', () {
      final scripts = StoryRegexScriptsCodec.fromTavernExtensions({
        'regex_scripts': [
          {
            'scriptName': 'Flags',
            'findRegex': r'/^foo.(bar)$/ims',
            'replaceString': r'$1',
            'placement': [2],
          },
        ],
      });

      expect(scripts.rules.single.find, r'^foo.(bar)$');
      expect(scripts.rules.single.caseSensitive, isFalse);
      expect(scripts.rules.single.multiLine, isTrue);
      expect(scripts.rules.single.dotAll, isTrue);
    });

    test('超长 pattern/replacement 和控制字符会被安全跳过', () {
      final scripts = StoryRegexScriptsCodec.decode({
        'rules': [
          {
            'key': 'too-long-pattern',
            'name': 'Too long',
            'stage': 'userInput',
            'find': 'x' * (StoryRegexScriptLimits.maxPatternLength + 1),
          },
          {
            'key': 'too-long-replacement',
            'name': 'Too long',
            'stage': 'userInput',
            'find': 'x',
            'replace': 'x' * (StoryRegexScriptLimits.maxReplacementLength + 1),
          },
          {
            'key': 'valid',
            'name': 'Valid',
            'stage': 'assistantDisplay',
            'find': 'x',
          },
        ],
      });

      expect(scripts.rules.map((rule) => rule.key), ['valid']);
    });
  });
}
