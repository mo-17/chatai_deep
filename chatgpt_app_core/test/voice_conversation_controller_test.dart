import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/voice/voice_conversation_controller.dart';
import 'support/fake_voice_input.dart';

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 80 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}

void main() {
  late FakeVoiceInput speech;
  late FakeVoiceOutput voice;
  late VoiceConversationController controller;
  late List<String> sends;
  late List<VoiceTurnContext> turns;
  Completer<String>? pending;
  var current = true, failReply = false, disposed = false;
  var cancelled = 0;
  setUp(() {
    speech = FakeVoiceInput();
    voice = FakeVoiceOutput();
    sends = [];
    turns = [];
    pending = null;
    current = true;
    failReply = false;
    cancelled = 0;
    disposed = false;
    controller = VoiceConversationController(
        speech: speech,
        voice: voice,
        echoDelay: Duration.zero,
        isCurrent: () => current,
        cancelReply: () async {
          cancelled++;
        },
        send: (text, turn) async {
          expect(speech.microphone, isFalse);
          sends.add(text);
          turns.add(turn);
          if (failReply) throw StateError('synthetic request failed');
          if (pending != null) return pending!.future;
          return '回答：$text';
        });
  });
  tearDown(() async {
    if (!disposed) {
      await controller.end();
      controller.dispose();
    }
  });
  Future<void> listen() async {
    await controller.start();
    await until(() => speech.results.isNotEmpty);
  }

  test(
      'explicit start; final text sends once; microphone off while thinking and speaking',
      () async {
    expect(speech.results, isEmpty);
    pending = Completer<String>();
    await listen();
    speech.partials.last?.call('部');
    expect(sends, isEmpty);
    speech.finish('第一句');
    await until(() => sends.length == 1);
    expect(controller.phase, VoiceConversationPhase.thinking);
    pending!.complete('第一轮回答');
    pending = null;
    await until(() => voice.requests.length == 1);
    expect(controller.phase, VoiceConversationPhase.speaking);
    expect(speech.results.length, 1);
    expect(speech.microphone, isFalse);
    voice.finish();
    await until(() => speech.results.length == 2);
    speech.finish('第二句');
    await until(() => voice.requests.length == 2);
    expect(sends, ['第一句', '第二句']);
    expect(voice.requests.every((r) => r.throwOnError), isTrue);
  });
  test('two silent sessions pause with no model requests', () async {
    await listen();
    speech.finish('');
    await until(() => speech.results.length == 2);
    speech.finish(' ');
    await until(() => controller.phase == VoiceConversationPhase.paused);
    expect(sends, isEmpty);
    expect(speech.microphone, isFalse);
  });
  test('permission failure stops without retrying', () async {
    speech.fail = true;
    await controller.start();
    await until(() => controller.phase == VoiceConversationPhase.error);
    expect(sends, isEmpty);
    expect(voice.requests, isEmpty);
  });
  test('late microphone-ready and partial callbacks after pause cannot send',
      () async {
    speech.deferReady = true;
    await listen();
    await controller.pause();
    speech.listening.first?.call();
    speech.partials.first?.call('迟到的识别');
    expect(controller.phase, VoiceConversationPhase.paused);
    expect(controller.heard, isEmpty);
    expect(sends, isEmpty);
  });
  test('failed model request never retries automatically', () async {
    failReply = true;
    await listen();
    speech.finish('第一句');
    await until(() => controller.phase == VoiceConversationPhase.error);
    expect(sends, ['第一句']);
    expect(speech.results.length, 1);
  });
  test('pause while thinking ignores late answer and cancels original turn',
      () async {
    pending = Completer<String>();
    await listen();
    speech.finish('第一句');
    await until(() => sends.length == 1);
    await controller.pause();
    pending!.complete('迟到的回答');
    await until(() => cancelled > 0);
    expect(turns.first.isCurrent, isFalse);
    expect(voice.requests, isEmpty);
    expect(speech.results.length, 1);
  });
  test(
      'tap interruption stops playback; late playback completion cannot restart listening',
      () async {
    voice.ignoreStop = true;
    await listen();
    speech.finish('第一句');
    await until(() => voice.requests.length == 1);
    await controller.interrupt();
    await until(() => speech.results.length == 2);
    expect(voice.requests.first.isCancelled?.call(), isTrue);
    voice.finish();
    await Future<void>.delayed(Duration.zero);
    expect(speech.results.length, 2);
    expect(voice.stops, greaterThan(0));
  });
  test('playback failure pauses instead of listening over missing audio',
      () async {
    voice.fail = true;
    await listen();
    speech.finish('第一句');
    await until(() => controller.phase == VoiceConversationPhase.error);
    expect(speech.results.length, 1);
    expect(speech.microphone, isFalse);
  });
  test(
      'identity change without UI notification still releases mic and prevents dispatch',
      () async {
    await listen();
    current = false;
    speech.finish('不得发送');
    await until(() => !controller.active);
    expect(sends, isEmpty);
    expect(speech.microphone, isFalse);
  });
  test('disposal does not notify listeners or accept late partial results',
      () async {
    await listen();
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.dispose();
    disposed = true;
    speech.partials.first?.call('不得显示');
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 0);
    expect(sends, isEmpty);
    expect(speech.microphone, isFalse);
  });
  test('cleanup failure fails closed and cannot restart microphone', () async {
    await listen();
    speech.failCancel = true;
    await controller.pause();
    await controller.start();
    expect(controller.phase, VoiceConversationPhase.error);
    expect(speech.results.length, 1);
    speech.failCancel = false;
  });
}
