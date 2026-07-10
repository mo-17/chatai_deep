import 'package:chatgpt_app_core/chat/application/story_template_background_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(StoryTemplateBackgroundScheduler.resetForTest);

  test('调度桥把账号传给平台壳层并支持登出取消', () async {
    final scheduled = <String>[];
    final cancelled = <String>[];
    StoryTemplateBackgroundScheduler.install(
      schedule: (accountHash) async => scheduled.add(accountHash),
      cancel: (accountHash) async => cancelled.add(accountHash),
    );

    await StoryTemplateBackgroundScheduler.schedule('account-a');
    await StoryTemplateBackgroundScheduler.cancel('account-a');

    expect(scheduled, ['account-a']);
    expect(cancelled, ['account-a']);
  });

  test('未安装平台处理器或平台调度失败不会中断前台任务', () async {
    await StoryTemplateBackgroundScheduler.schedule('account-a');
    await StoryTemplateBackgroundScheduler.cancel('account-a');

    StoryTemplateBackgroundScheduler.install(
      schedule: (_) async => throw StateError('schedule failed'),
      cancel: (_) async => throw StateError('cancel failed'),
    );

    await expectLater(
      StoryTemplateBackgroundScheduler.schedule('account-a'),
      completes,
    );
    await expectLater(
      StoryTemplateBackgroundScheduler.cancel('account-a'),
      completes,
    );
  });
}
