import 'package:chatgpt_app_core/chat/application/story_regex_executor.dart';
import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按 sortOrder 在目标阶段执行，失败规则不阻断后续规则', () async {
    const scripts = StoryRegexScripts(rules: [
      StoryRegexScript(
        key: 'second',
        name: 'Second',
        stage: StoryRegexStage.userInput,
        find: 'b',
        replace: 'c',
        sortOrder: 20,
      ),
      StoryRegexScript(
        key: 'broken',
        name: 'Broken',
        stage: StoryRegexStage.userInput,
        find: '(',
        sortOrder: 10,
      ),
      StoryRegexScript(
        key: 'first',
        name: 'First',
        stage: StoryRegexStage.userInput,
        find: 'a',
        replace: 'b',
        sortOrder: 15,
      ),
      StoryRegexScript(
        key: 'other-stage',
        name: 'Other stage',
        stage: StoryRegexStage.assistantDisplay,
        find: 'c',
        replace: 'd',
      ),
    ]);

    final result = await StoryRegexExecutor.execute(
      scripts: scripts,
      stage: StoryRegexStage.userInput,
      input: 'a',
    );

    expect(result.output, 'c');
    expect(result.timedOut, isFalse);
    expect(
      result.rules.map((rule) => rule.status),
      [
        StoryRegexRuleStatus.skipped,
        StoryRegexRuleStatus.failed,
        StoryRegexRuleStatus.applied,
        StoryRegexRuleStatus.applied,
      ],
    );
    expect(result.rules[1].error, isNotEmpty);
    expect(result.rules.every((rule) => rule.elapsed >= Duration.zero), isTrue);
  });

  test('trimStrings 只从结果两端移除，并保留阶段隔离', () async {
    const scripts = StoryRegexScripts(rules: [
      StoryRegexScript(
        key: 'cleanup',
        name: 'Cleanup',
        stage: StoryRegexStage.assistantDisplay,
        find: 'foo',
        replace: '!bar!',
        trimStrings: ['!', '\n'],
      ),
    ]);

    final display = await StoryRegexExecutor.execute(
      scripts: scripts,
      stage: StoryRegexStage.assistantDisplay,
      input: '\n!foo!\n',
    );
    final output = await StoryRegexExecutor.execute(
      scripts: scripts,
      stage: StoryRegexStage.assistantOutput,
      input: '\n!foo!\n',
    );

    expect(display.output, 'bar');
    expect(output.output, '\n!foo!\n');
    expect(output.rules.single.status, StoryRegexRuleStatus.skipped);
  });

  test('输入和输出受 32000 字符上限约束', () async {
    const scripts = StoryRegexScripts(rules: [
      StoryRegexScript(
        key: 'expand',
        name: 'Expand',
        stage: StoryRegexStage.userInput,
        find: 'a',
        replace: 'bbbb',
      ),
    ]);

    final input = 'a' * (StoryRegexScriptLimits.maxTextLength + 10);
    final result = await StoryRegexExecutor.execute(
      scripts: scripts,
      stage: StoryRegexStage.userInput,
      input: input,
    );

    expect(result.inputTruncated, isTrue);
    expect(result.outputTruncated, isTrue);
    expect(result.output.length, StoryRegexScriptLimits.maxTextLength);
  });

  test('支持 Tavern flags、捕获组、完整匹配和美元转义', () async {
    const scripts = StoryRegexScripts(rules: [
      StoryRegexScript(
        key: 'capture',
        name: 'Capture',
        stage: StoryRegexStage.assistantOutput,
        find: r'^hello.(world)$',
        replace: r'$1|$&|$$|${1}',
        caseSensitive: false,
        multiLine: true,
        dotAll: true,
      ),
    ]);

    final result = await StoryRegexExecutor.execute(
      scripts: scripts,
      stage: StoryRegexStage.assistantOutput,
      input: 'HELLO\nworld',
    );

    expect(
        result.output, r'world|HELLO\nworld|$|world'.replaceAll(r'\n', '\n'));
  });

  test('灾难性回溯在阶段超时后终止 isolate，不阻塞调用方', () async {
    const scripts = StoryRegexScripts(rules: [
      StoryRegexScript(
        key: 'catastrophic',
        name: 'Catastrophic',
        stage: StoryRegexStage.userInput,
        find: r'^(a+)+$',
        replace: 'x',
      ),
      StoryRegexScript(
        key: 'later',
        name: 'Later',
        stage: StoryRegexStage.userInput,
        find: 'a',
        replace: 'b',
      ),
    ]);

    final stopwatch = Stopwatch()..start();
    final result = await StoryRegexExecutor.execute(
      scripts: scripts,
      stage: StoryRegexStage.userInput,
      input: '${'a' * 12000}!',
      stageTimeout: const Duration(milliseconds: 80),
    );
    stopwatch.stop();

    expect(result.timedOut, isTrue);
    expect(result.rules.first.status, StoryRegexRuleStatus.timedOut);
    expect(result.rules.last.status, StoryRegexRuleStatus.skipped);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
