import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/voice/voice_audio_route.dart';
import 'package:chatgpt_app_core/voice/voice_conversation_controller.dart';
import 'package:chatgpt_app_core/voice/sentence_speech_queue.dart';
import 'support/fake_voice_input.dart';

Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

class _Headset extends VoiceAudioRoute {
  bool connected = true;
  int releases = 0;
  @override
  Future<bool> prepareHeadset() async => connected;
  @override
  Future<bool> headsetStillConnected() async => connected;
  @override
  Future<void> release() async {
    releases++;
  }
}

void main() {
  test('第一句在模型结束前播放，后续句子串行且代码围栏不口播', () async {
    final voice = FakeVoiceOutput();
    var current = true;
    var failed = false;
    final queue = SentenceSpeechQueue(
        voice: voice,
        current: () => current,
        onSentence: () {},
        onFailure: () => failed = true);
    queue.update('第一句。未完成');
    await eventually(() => voice.requests.length == 1);
    expect(voice.requests.first.text, '第一句。');
    queue.update('第一句。未完成的第二句。\n```dart\nsecret();\n```\n结束。');
    expect(voice.requests, hasLength(1));
    voice.finish();
    await eventually(() => voice.requests.length == 2);
    expect(voice.requests.last.text, '未完成的第二句。');
    voice.finish();
    await eventually(() => voice.requests.length == 3);
    expect(voice.requests.last.text, '结束。');
    voice.finish();
    await queue.finish('第一句。未完成的第二句。\n```dart\nsecret();\n```\n结束。');
    expect(failed, isFalse);
    current = false;
  });
  test('取消后排队句子和迟到流都不能继续播报', () async {
    final voice = FakeVoiceOutput();
    var current = true;
    final queue = SentenceSpeechQueue(
        voice: voice,
        current: () => current,
        onSentence: () {},
        onFailure: () {});
    queue.update('第一句。第二句。');
    await eventually(() => voice.requests.length == 1);
    current = false;
    await voice.stop();
    queue.update('第一句。第二句。迟到。');
    await queue.finish('第一句。第二句。迟到。');
    expect(voice.requests, hasLength(1));
  });
  test('文本被重写或播报失败时停止，不把差异拼接成错误答案', () async {
    final voice = FakeVoiceOutput();
    var failed = false;
    final queue = SentenceSpeechQueue(
        voice: voice,
        current: () => true,
        onSentence: () {},
        onFailure: () => failed = true);
    queue.update('原始部分');
    queue.update('被替换的部分');
    expect(failed, isTrue);
    await expectLater(queue.finish('被替换的部分'), throwsStateError);
    expect(voice.requests, isEmpty);
  });
  test('普通流式对话提前播放，外放保持麦克风关闭', () async {
    final speech = FakeVoiceInput(), voice = FakeVoiceOutput();
    final model = Completer<String>();
    VoiceTurnContext? turn;
    final c = VoiceConversationController(
        speech: speech,
        voice: voice,
        streamReplies: true,
        echoDelay: Duration.zero,
        isCurrent: () => true,
        cancelReply: () async {},
        send: (text, ctx) {
          turn = ctx;
          return model.future;
        });
    try {
      await c.start();
      await eventually(() => speech.results.isNotEmpty);
      speech.finish('问题');
      await eventually(() => turn != null);
      turn!.emitText('已经有第一句。');
      await eventually(() => voice.requests.isNotEmpty);
      expect(model.isCompleted, isFalse);
      expect(speech.microphone, isFalse);
      voice.finish();
      model.complete('已经有第一句。还有第二句。');
      await eventually(() => voice.requests.length == 2);
      voice.finish();
      await eventually(() => speech.results.length == 2);
    } finally {
      await c.end();
      c.dispose();
    }
  });
  test('耳机插话先取消旧输出，收到完整识别后只发送一次新问题', () async {
    final speech = FakeVoiceInput(),
        voice = FakeVoiceOutput(),
        headset = _Headset();
    final old = Completer<String>();
    final sends = <String>[];
    final turns = <VoiceTurnContext>[];
    var cancelled = 0;
    final c = VoiceConversationController(
        speech: speech,
        voice: voice,
        streamReplies: true,
        audioRoute: headset,
        echoDelay: Duration.zero,
        isCurrent: () => true,
        cancelReply: () async {
          cancelled++;
        },
        send: (text, ctx) {
          sends.add(text);
          turns.add(ctx);
          if (sends.length == 1) {
            ctx.emitText('旧回答第一句。');
            return old.future;
          }
          return Future.value('新问题的回答。');
        });
    try {
      await c.enableHandsFree(true);
      expect(c.handsFree, isTrue);
      await c.start();
      await eventually(() => speech.results.length == 1);
      speech.finish('第一个问题');
      await eventually(
          () => voice.requests.isNotEmpty && speech.results.length == 2);
      speech.partials.last?.call('换个问题');
      await eventually(() => cancelled > 0);
      expect(turns.first.isCurrent, isFalse);
      expect(sends, hasLength(1));
      speech.finish('换个问题完整句');
      await eventually(() => sends.length == 2);
      expect(sends, ['第一个问题', '换个问题完整句']);
      turns.first.emitText('旧回答第一句。迟到部分不播放。');
      old.complete('旧回答迟到终态');
      await eventually(() => voice.requests.length == 2);
      expect(voice.requests.last.text, '新问题的回答。');
      expect(voice.requests.any((r) => r.text.contains('迟到')), isFalse);
    } finally {
      await c.end();
      c.dispose();
    }
  });
  test('耳机断开会暂停收音、模型和播放，不自动切到外放继续', () async {
    final speech = FakeVoiceInput(),
        voice = FakeVoiceOutput(),
        headset = _Headset();
    var cancelled = 0;
    final c = VoiceConversationController(
        speech: speech,
        voice: voice,
        audioRoute: headset,
        isCurrent: () => true,
        cancelReply: () async {
          cancelled++;
        },
        send: (_, __) async => '回答');
    try {
      await c.enableHandsFree(true);
      await c.start();
      await eventually(() => speech.microphone);
      headset.connected = false;
      await eventually(() => c.phase == VoiceConversationPhase.paused);
      await eventually(() => !speech.microphone && cancelled > 0);
      expect(c.note, contains('耳机已断开'));
      expect(headset.releases, greaterThan(0));
    } finally {
      await c.end();
      c.dispose();
    }
  });
  test('不支持耳机路由时不能误开启双工', () async {
    final headset = _Headset()..connected = false;
    final c = VoiceConversationController(
        speech: FakeVoiceInput(),
        voice: FakeVoiceOutput(),
        audioRoute: headset,
        isCurrent: () => true,
        cancelReply: () async {},
        send: (_, __) async => '回答');
    try {
      await c.enableHandsFree(true);
      expect(c.handsFree, isFalse);
      expect(c.note, contains('请连接'));
    } finally {
      await c.end();
      c.dispose();
    }
  });
}
