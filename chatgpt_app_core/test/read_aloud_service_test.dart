import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maybeSpeak 仅在开启且文本非空时调用服务', () async {
    final service = _FakeReadAloudService();

    expect(
      await ReadAloudCoordinator.maybeSpeak(
        service: service,
        text: '你好',
        enabled: false,
      ),
      isFalse,
    );
    expect(
      await ReadAloudCoordinator.maybeSpeak(
        service: service,
        text: '   ',
        enabled: true,
      ),
      isFalse,
    );
    expect(service.requests, isEmpty);

    expect(
      await ReadAloudCoordinator.maybeSpeak(
        service: service,
        text: '  你好，世界  ',
        enabled: true,
      ),
      isTrue,
    );
    expect(service.requests.single.text, '你好，世界');
  });

  test('maybeSpeak 规范化 locale、voiceStyle 并钳制朗读速率', () async {
    final service = _FakeReadAloudService();

    await ReadAloudCoordinator.maybeSpeak(
      service: service,
      text: 'hello',
      enabled: true,
      locale: ' zh_CN ',
      rate: 9,
      voiceStyle: ' female ',
    );
    await ReadAloudCoordinator.maybeSpeak(
      service: service,
      text: 'world',
      enabled: true,
      locale: '',
      rate: 0.1,
      voiceStyle: 'unknown',
    );

    expect(service.requests.first.locale, 'zh-CN');
    expect(service.requests.first.rate, 2.0);
    expect(service.requests.first.voiceStyle, 'female');
    expect(service.requests.last.locale, isNull);
    expect(service.requests.last.rate, 0.5);
    expect(service.requests.last.voiceStyle, isNull);
  });

  test('maybeSpeak 允许选择内置 sherpa-onnx 离线中文女声', () async {
    final service = _FakeReadAloudService();
    final stages = <ReadAloudStage>[];
    var cancelled = false;

    await ReadAloudCoordinator.maybeSpeak(
      service: service,
      text: '离线朗读',
      enabled: true,
      voiceStyle: ' ${TtsVoiceStyle.offlineZhFemale.id} ',
      onStage: stages.add,
      isCancelled: () => cancelled,
    );

    expect(
        service.requests.single.voiceStyle, TtsVoiceStyle.offlineZhFemale.id);
    expect(service.requests.single.isCancelled?.call(), isFalse);
    cancelled = true;
    expect(service.requests.single.isCancelled?.call(), isTrue);
    service.requests.single.onStage?.call(ReadAloudStage.synthesizing);
    expect(stages, [ReadAloudStage.synthesizing]);
    expect(
      TtsVoiceStyle.byId(TtsVoiceStyle.offlineZhFemale.id).label,
      contains('离线'),
    );
  });

  test('ReadAloudStageUi 提供阶段文案和进度显示判断', () {
    expect(ReadAloudStageUi.label(ReadAloudStage.preparing), '准备中');
    expect(ReadAloudStageUi.label(ReadAloudStage.synthesizing), '生成音频中');
    expect(ReadAloudStageUi.label(ReadAloudStage.playing), '播放中');
    expect(ReadAloudStageUi.label(ReadAloudStage.completed), '处理中');
    expect(ReadAloudStageUi.label(null), '处理中');

    expect(ReadAloudStageUi.showsProgress(ReadAloudStage.preparing), isTrue);
    expect(ReadAloudStageUi.showsProgress(ReadAloudStage.synthesizing), isTrue);
    expect(ReadAloudStageUi.showsProgress(ReadAloudStage.playing), isFalse);
    expect(ReadAloudStageUi.showsProgress(ReadAloudStage.completed), isFalse);
    expect(ReadAloudStageUi.showsProgress(null), isFalse);
  });

  test('NoopReadAloudService 可作为默认实现安全调用', () async {
    expect(
      await ReadAloudCoordinator.maybeSpeak(
        service: const NoopReadAloudService(),
        text: '无需平台 TTS 插件也不抛错',
        enabled: true,
      ),
      isTrue,
    );
  });

  test('FlutterTtsReadAloudService 调用真实 TTS engine 并应用语言、风格与语速', () async {
    final engine = _FakeTtsEngine(voices: [
      {'name': 'Li Na Female', 'locale': 'zh-CN', 'gender': 'female'},
      {'name': 'Tom Male', 'locale': 'en-US', 'gender': 'male'},
    ]);
    final service = FlutterTtsReadAloudService(engine: engine);

    await service.speak(const ReadAloudRequest(
      text: '你好，世界',
      locale: 'zh-CN',
      rate: 1.5,
      voiceStyle: 'female',
    ));

    expect(engine.calls, [
      'stop',
      'language:zh-CN',
      'voices',
      'voice:Li Na Female/zh-CN',
      'rate:0.75',
      'volume:1.0',
      'pitch:1.08',
      'awaitCompletion:true',
      'speak:你好，世界',
    ]);
  });

  test('FlutterTtsReadAloudService 风格匹配不到 voice 时用 pitch/rate 降级', () async {
    final engine = _FakeTtsEngine(voices: [
      {'name': 'Li Na Female', 'locale': 'zh-CN', 'gender': 'female'},
    ]);
    final service = FlutterTtsReadAloudService(engine: engine);

    await service.speak(const ReadAloudRequest(
      text: '慢一点',
      locale: 'zh-CN',
      rate: 1.0,
      voiceStyle: 'deep',
    ));

    expect(engine.calls, [
      'stop',
      'language:zh-CN',
      'voices',
      'rate:0.45',
      'volume:1.0',
      'pitch:0.82',
      'awaitCompletion:true',
      'speak:慢一点',
    ]);
  });

  test('FlutterTtsReadAloudService stop 透传到底层 engine', () async {
    final engine = _FakeTtsEngine();
    final service = FlutterTtsReadAloudService(engine: engine);

    await service.stop();

    expect(engine.calls, ['stop']);
  });
}

class _FakeReadAloudService implements ReadAloudService {
  final requests = <ReadAloudRequest>[];

  @override
  Future<void> speak(ReadAloudRequest request) async {
    requests.add(request);
  }

  @override
  Future<void> stop() async {}
}

class _FakeTtsEngine implements TtsEngine {
  _FakeTtsEngine({this.voices = const []});

  final List<Map<String, String>> voices;
  final calls = <String>[];

  @override
  Future<dynamic> getVoices() async {
    calls.add('voices');
    return voices;
  }

  @override
  Future<void> awaitSpeakCompletion(bool enabled) async {
    calls.add('awaitCompletion:$enabled');
  }

  @override
  Future<void> setVoice(Map<String, String> voice) async {
    calls.add('voice:${voice['name']}/${voice['locale']}');
  }

  @override
  Future<void> setLanguage(String language) async {
    calls.add('language:$language');
  }

  @override
  Future<void> setPitch(double pitch) async {
    calls.add('pitch:$pitch');
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    calls.add('rate:$rate');
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('volume:$volume');
  }

  @override
  Future<void> speak(String text) async {
    calls.add('speak:$text');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }
}
