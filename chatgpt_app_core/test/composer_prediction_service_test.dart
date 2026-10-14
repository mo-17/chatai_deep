import 'dart:async';
import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/composer_prediction_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_composer_chat.dart';

List<MessageModel> history() => [
      MessageModel(
          ownerType: OwnerType.sender,
          content: '什么是单元测试？',
          createdAt: 1,
          imageUrlsOrB64: ['private-image']),
      MessageModel(
          ownerType: OwnerType.receiver,
          content: '单元测试可以独立检查一段功能。',
          createdAt: 2),
    ];

void main() {
  test('默认、旧 JSON 与非法开关均关闭；明确开启可 clone', () {
    expect(AISettings.defaults().composerPredictionsEnabled, isFalse);
    for (final value in [null, false, 'true', 1, <String>[]]) {
      expect(
          AISettings.fromJson({'composerPredictionsEnabled': value})
              .composerPredictionsEnabled,
          isFalse);
    }
    expect(
        (AISettings.defaults()..composerPredictionsEnabled = true)
            .clone()
            .composerPredictionsEnabled,
        isTrue);
  });

  test('只发送有界已发正文，独立预算、取消、无重试且无附件', () async {
    final fake = FakeComposerChat();
    final abort = Completer<void>();
    final messages = history();
    final result = await ComposerPredictionService(chatFactory: (_) => fake)
        .predict(
            settings: AISettings.defaults(),
            messages: messages,
            abortTrigger: abort.future);
    expect(result!.suggestion, '请给一个具体例子。');
    expect(fake.calls, 1);
    expect(fake.requests.single.abortTrigger, same(abort.future));
    expect(fake.requests.single.maxAutoRetries, 0);
    expect(fake.requests.single.maxOutputTokensOverride, 256);
    expect(fake.requests.single.reasoningPolicy,
        ChatReasoningPolicy.offIfSupported);
    expect(fake.attachmentsReceived.single, isNull);
    expect(jsonEncode(fake.histories.single), isNot(contains('private-image')));
    // 共享fake现在记录完整dispatch消息（包含辅助请求本身），而非仅history入参。
    expect(fake.histories.single.first['role'], 'system');
    expect(fake.histories.single, hasLength(messages.length + 2));
    expect(fake.histories.single.skip(1).map((m) => m['content']),
        [...messages.map((m) => m.content), '请给出下一条用户消息建议。']);
    expect(fake.histories.single.last['role'], 'user');
    expect(fake.prompts.single, '请给出下一条用户消息建议。');
    expect(messages, hasLength(2));
    expect(result.usage.promptTokens, 100);
    final long = List.generate(
        20,
        (i) => MessageModel(
            ownerType: i.isEven ? OwnerType.sender : OwnerType.receiver,
            content: '🙂' * 9000,
            createdAt: i + 1));
    final bounded = ComposerPredictionService.textHistory(long);
    expect(bounded.length, lessThanOrEqualTo(6));
    expect(
        bounded.fold<int>(
            0, (n, m) => n + (m['content'] as String).runes.length),
        lessThanOrEqualTo(4800));
  });

  test('模型放弃、无效 JSON、空或过长建议不展示', () {
    for (final raw in [
      null,
      'not json',
      '{"suggestion":null}',
      '{"suggestion":7}',
      '{"suggestion":" "}',
      jsonEncode({'suggestion': '长' * 201})
    ]) {
      expect(ComposerPredictionService.parseSuggestion(raw), isNull);
    }
    expect(
        ComposerPredictionService.parseSuggestion('{"suggestion":"请解释\\n例子"}'),
        '请解释 例子');
  });

  test('关闭和不满足展示条件时零调用；每个回复至多一次', () async {
    final fake = FakeComposerChat();
    final controller = ComposerPredictionController(
        service: ComposerPredictionService(chatFactory: (_) => fake));
    addTearDown(controller.dispose);
    final settings = AISettings.defaults();
    var eligible = true;
    Future<void> request() => controller.request(
        completedTurn: 2,
        settings: settings,
        messages: history(),
        isEligible: () => eligible);
    await request();
    settings.composerPredictionsEnabled = true;
    eligible = false;
    await request();
    expect(fake.calls, 0);
    eligible = true;
    await request();
    controller.cancel();
    await request();
    expect(fake.calls, 1);
    expect(controller.suggestion, isNull);
  });

  for (final reason in ['取消', '退出页面']) {
    test('$reason：取消信号生效，迟到结果不会恢复建议', () async {
      final fake = FakeComposerChat()
        ..pending = Completer<ChatCompletionResult>();
      final controller = ComposerPredictionController(
          service: ComposerPredictionService(chatFactory: (_) => fake));
      final result = controller.request(
          completedTurn: 2,
          settings: AISettings.defaults()..composerPredictionsEnabled = true,
          messages: history(),
          isEligible: () => true);
      await Future<void>.delayed(Duration.zero);
      var cancelled = false;
      fake.requests.single.abortTrigger!.then((_) => cancelled = true);
      if (reason == '退出页面') {
        controller.dispose();
      } else {
        controller.cancel();
      }
      await fake.requests.single.abortTrigger;
      await result;
      expect(cancelled, isTrue);
      fake.pending!.complete(ChatCompletionResult(content: fake.content));
      await Future<void>.delayed(Duration.zero);
      expect(controller.suggestion, isNull);
      if (reason != '退出页面') controller.dispose();
    });
  }

  test('超时中止请求；失败不重试；放弃建议仍记录用量', () async {
    final fake = FakeComposerChat()
      ..pending = Completer<ChatCompletionResult>();
    final controller = ComposerPredictionController(
        service: ComposerPredictionService(chatFactory: (_) => fake),
        timeout: const Duration(milliseconds: 5));
    addTearDown(controller.dispose);
    final settings = AISettings.defaults()..composerPredictionsEnabled = true;
    Future<void> request(int turn,
            {Future<void> Function(ComposerPredictionResult)? onUsage}) =>
        controller.request(
            completedTurn: turn,
            settings: settings,
            messages: history(),
            isEligible: () => true,
            onUsage: onUsage);
    await request(1);
    expect(controller.suggestion, isNull);
    fake.pending!.complete(ChatCompletionResult(content: fake.content));
    fake.pending = null;
    fake.fail = true;
    await request(2);
    expect(fake.calls, 2);
    fake.fail = false;
    fake.content = '{"suggestion":null}';
    var recorded = 0;
    await request(3, onUsage: (r) async {
      recorded++;
      expect(r.usage.completionTokens, 12);
    });
    expect(recorded, 1);
    expect(controller.suggestion, isNull);
  });
}
