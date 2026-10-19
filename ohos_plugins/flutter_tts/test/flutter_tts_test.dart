import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hzb.flutter_ai/tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('长文本按 UTF16 上限分段且不切断 emoji，等待每段播放完成', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 1;
    });
    final tts = FlutterTts();
    final text = '${'中' * 999}😀${'文' * 1200}';
    expect(await tts.speak(text), 1);
    final chunks = calls
        .map((call) => call.arguments['text'] as String)
        .toList();
    expect(chunks.join(), text);
    expect(chunks.every((text) => text.length <= 1000), isTrue);
    expect(chunks.first.length, 999);
    expect(chunks[1].startsWith('😀'), isTrue);
  });

  test('停止正在播放的一段后不再发送后续文本', () async {
    final pending = Completer<int>();
    var speaks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') return 1;
      speaks++;
      return pending.future;
    });
    final tts = FlutterTts();
    final speaking = tts.speak('文' * 2100);
    await Future<void>.delayed(Duration.zero);
    await tts.stop();
    pending.complete(1);
    expect(await speaking, 0);
    expect(speaks, 1);
  });

  test('选音色、语言和语速参数传入系统，系统错误不伪装成功', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'voices')
        return [
          {'identifier': '3', 'locale': 'zh-CN'},
        ];
      if (call.arguments['text'] == '失败')
        throw PlatformException(code: 'tts_error');
      return 1;
    });
    final tts = FlutterTts();
    await tts.setLanguage('en_US');
    await tts.setVoice({'identifier': '3', 'locale': 'zh-CN'});
    await tts.setSpeechRate(0.75);
    await tts.setPitch(1.08);
    await tts.setVolume(0.6);
    expect(await tts.getVoices, isNotEmpty);
    expect(await tts.speak('正文'), 1);
    expect(calls.last.arguments, {
      'text': '正文',
      'language': 'zh-CN',
      'person': 3,
      'speed': 1.5,
      'volume': 0.6,
      'pitch': 1.08,
    });
    await expectLater(tts.speak('失败'), throwsA(isA<PlatformException>()));
  });

  test('新朗读使旧朗读失效，旧请求异常不会打断新请求', () async {
    final pending = Completer<int>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.arguments['text'] == '旧') return pending.future;
      return 1;
    });
    final tts = FlutterTts();
    final old = tts.speak('旧');
    await Future<void>.delayed(Duration.zero);
    expect(await FlutterTts().speak('新'), 1);
    pending.completeError(PlatformException(code: 'cancelled'));
    expect(await old, 0);
  });
}
