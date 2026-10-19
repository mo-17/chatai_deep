import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('系统朗读与停止不创建模型播放器，不支持模型音色时明确提示', () async {
    var created = 0;
    final system = _FakeReadAloudService();
    final service = HybridReadAloudService(
      system: system,
      offlineSupported: () => false,
      offlineFactory: () {
        created++;
        return _FakeReadAloudService();
      },
    );
    await service.stop();
    await service.speak(const ReadAloudRequest(text: '系统朗读'));
    await service.stop();
    expect(created, 0);
    expect(system.stopCount, 2);
    await expectLater(
        Future.sync(() => service.speak(ReadAloudRequest(
              text: '模型音色',
              voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
            ))),
        throwsStateError);
    expect(created, 0);
  });

  test(
      'strict continuous voice cannot silently succeed on unsupported offline engine',
      () async {
    final service = SherpaOnnxReadAloudService(
        isSupported: () => false, playback: _FakePlayback());
    await service.speak(const ReadAloudRequest(text: 'legacy'));
    await expectLater(
        service
            .speak(const ReadAloudRequest(text: 'voice', throwOnError: true)),
        throwsStateError);
  });

  test('SherpaOnnxReadAloudService 安装模型、生成 wav 并播放', () async {
    final temp = await Directory.systemTemp.createTemp('sherpa_tts_test_');
    addTearDown(() => temp.delete(recursive: true));
    final installer = _FakeInstaller(temp);
    final runtime = _FakeRuntime();
    final playback = _FakePlayback();
    final stages = <ReadAloudStage>[];
    final service = SherpaOnnxReadAloudService(
      installer: installer,
      runtime: runtime,
      playback: playback,
      outputDir: () async => Directory('${temp.path}/out'),
      isSupported: () => true,
    );

    await service.speak(ReadAloudRequest(
      text: '  你好，离线朗读  ',
      rate: 9,
      voiceStyle: 'sherpa_matcha_zh_baker',
      onStage: stages.add,
    ));

    expect(installer.models, [BundledSherpaOnnxTtsModel.matchaZhBaker.id]);
    expect(runtime.texts, ['你好，离线朗读']);
    expect(runtime.speeds, [2.0]);
    expect(runtime.outputDirs.single.path, contains('/out/tts_audio_cache/'));
    expect(playback.calls.first, 'stop');
    expect(playback.calls.last, startsWith('play:'));
    expect(
      await File(playback.playedPaths.single).readAsString(),
      startsWith('fake wav'),
    );
    expect(stages, [
      ReadAloudStage.preparing,
      ReadAloudStage.synthesizing,
      ReadAloudStage.playing,
      ReadAloudStage.completed,
    ]);
  });

  test('SherpaOnnxReadAloudService 第二次播放相同文本会复用 wav 缓存', () async {
    final temp =
        await Directory.systemTemp.createTemp('sherpa_tts_cache_test_');
    addTearDown(() => temp.delete(recursive: true));
    final installer = _FakeInstaller(temp);
    final runtime = _FakeRuntime();
    final playback = _FakePlayback();
    final firstStages = <ReadAloudStage>[];
    final secondStages = <ReadAloudStage>[];
    final service = SherpaOnnxReadAloudService(
      installer: installer,
      runtime: runtime,
      playback: playback,
      outputDir: () async => Directory('${temp.path}/out'),
      isSupported: () => true,
    );
    final request = ReadAloudRequest(
      text: '缓存这段音频',
      rate: 1.0,
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
      onStage: firstStages.add,
    );

    await service.speak(request);
    await service.speak(ReadAloudRequest(
      text: '缓存这段音频',
      rate: 1.0,
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
      onStage: secondStages.add,
    ));

    expect(runtime.texts, ['缓存这段音频']);
    expect(playback.playedPaths, hasLength(2));
    expect(playback.playedPaths.first, playback.playedPaths.last);
    expect(firstStages, contains(ReadAloudStage.synthesizing));
    expect(secondStages, isNot(contains(ReadAloudStage.synthesizing)));
    expect(secondStages, [
      ReadAloudStage.preparing,
      ReadAloudStage.playing,
      ReadAloudStage.completed,
    ]);
  });

  test('SherpaOnnxReadAloudService 等待音频播放完成后才结束状态', () async {
    final temp =
        await Directory.systemTemp.createTemp('sherpa_tts_playing_test_');
    addTearDown(() => temp.delete(recursive: true));
    final playCompleter = Completer<void>();
    final playback = _FakePlayback(playCompleter: playCompleter);
    final stages = <ReadAloudStage>[];
    final service = SherpaOnnxReadAloudService(
      installer: _FakeInstaller(temp),
      runtime: _FakeRuntime(),
      playback: playback,
      outputDir: () async => Directory('${temp.path}/out'),
      isSupported: () => true,
    );

    final task = service.speak(ReadAloudRequest(
      text: '播放状态需要保持',
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
      onStage: stages.add,
    ));
    for (var i = 0; i < 100 && playback.playedPaths.isEmpty; i++) {
      await pumpEventQueue();
    }

    expect(playback.playedPaths, isNotEmpty);
    expect(stages.last, ReadAloudStage.playing);
    expect(stages, isNot(contains(ReadAloudStage.completed)));

    playCompleter.complete();
    await task;

    expect(stages.last, ReadAloudStage.completed);
  });

  test('SherpaOnnxReadAloudService 生成中取消后不播放音频', () async {
    final temp = await Directory.systemTemp.createTemp('sherpa_tts_cancel_');
    addTearDown(() => temp.delete(recursive: true));
    final installer = _FakeInstaller(temp);
    final runtime = _FakeRuntime();
    final playback = _FakePlayback();
    final stages = <ReadAloudStage>[];
    var cancelled = false;
    final service = SherpaOnnxReadAloudService(
      installer: installer,
      runtime: runtime,
      playback: playback,
      outputDir: () async => Directory('${temp.path}/out'),
      isSupported: () => true,
    );

    await service.speak(ReadAloudRequest(
      text: '生成中停止',
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
      onStage: (stage) {
        stages.add(stage);
        if (stage == ReadAloudStage.synthesizing) cancelled = true;
      },
      isCancelled: () => cancelled,
    ));

    expect(runtime.texts, ['生成中停止']);
    expect(playback.calls, ['stop']);
    expect(playback.playedPaths, isEmpty);
    expect(stages, [
      ReadAloudStage.preparing,
      ReadAloudStage.synthesizing,
    ]);
  });

  test('SherpaOnnxReadAloudService prepare 会提前安装模型并预热 runtime', () async {
    final temp = await Directory.systemTemp.createTemp('sherpa_tts_test_');
    addTearDown(() => temp.delete(recursive: true));
    final installer = _FakeInstaller(temp);
    final runtime = _FakeRuntime();
    final service = SherpaOnnxReadAloudService(
      installer: installer,
      runtime: runtime,
      playback: _FakePlayback(),
      isSupported: () => true,
    );

    await service.prepare(ReadAloudRequest(
      text: '',
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
    ));
    await service.prepare(const ReadAloudRequest(
      text: '',
      voiceStyle: 'female',
    ));

    expect(installer.models, [BundledSherpaOnnxTtsModel.matchaZhBaker.id]);
    expect(runtime.preparedRoots, [temp.path]);
  });

  test('SherpaOnnxReadAloudService 在不支持平台或空文本时不触发模型', () async {
    final installer = _FakeInstaller(await Directory.systemTemp.createTemp());
    addTearDown(() => installer.root.delete(recursive: true));
    final runtime = _FakeRuntime();
    final playback = _FakePlayback();

    await SherpaOnnxReadAloudService(
      installer: installer,
      runtime: runtime,
      playback: playback,
      isSupported: () => false,
    ).speak(const ReadAloudRequest(text: '你好'));
    await SherpaOnnxReadAloudService(
      installer: installer,
      runtime: runtime,
      playback: playback,
      isSupported: () => true,
    ).speak(const ReadAloudRequest(text: '   '));

    expect(installer.models, isEmpty);
    expect(runtime.texts, isEmpty);
    expect(playback.calls, isEmpty);
  });

  test('HybridReadAloudService 按 voiceStyle 路由系统 TTS 与离线 TTS', () async {
    final system = _FakeReadAloudService();
    final offline = _FakeReadAloudService();
    final service = HybridReadAloudService(system: system, offline: offline);

    await service.speak(const ReadAloudRequest(
      text: '系统朗读',
      voiceStyle: 'female',
    ));
    await service.speak(ReadAloudRequest(
      text: '离线朗读',
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
    ));
    await service.stop();

    expect(system.requests.map((e) => e.text), ['系统朗读']);
    expect(offline.requests.map((e) => e.text), ['离线朗读']);
    expect(system.stopCount, 1);
    expect(offline.stopCount, 1);
  });

  test('HybridReadAloudService 只对离线风格执行预热', () async {
    final offline = _FakeReadAloudService();
    final service = HybridReadAloudService(
      system: _FakeReadAloudService(),
      offline: offline,
    );

    await service.prepare(const ReadAloudRequest(
      text: '',
      voiceStyle: 'female',
    ));
    await service.prepare(ReadAloudRequest(
      text: '',
      voiceStyle: TtsVoiceStyle.offlineZhFemale.id,
    ));

    expect(offline.prepareCount, 1);
  });
}

class _FakeInstaller implements SherpaOnnxAssetInstaller {
  _FakeInstaller(this.root);

  final Directory root;
  final models = <String>[];

  @override
  Future<InstalledSherpaOnnxTtsModel> ensureInstalled(
    BundledSherpaOnnxTtsModel model,
  ) async {
    models.add(model.id);
    await root.create(recursive: true);
    return InstalledSherpaOnnxTtsModel(
      id: model.id,
      bundled: model,
      rootDir: root,
      manifest: _manifest,
    );
  }
}

class _FakeRuntime implements SherpaOnnxTtsRuntime {
  final preparedRoots = <String>[];
  final texts = <String>[];
  final speeds = <double>[];
  final outputDirs = <Directory>[];

  @override
  Future<void> prepare(InstalledSherpaOnnxTtsModel model) async {
    preparedRoots.add(model.rootDir.path);
  }

  @override
  Future<File> synthesize({
    required InstalledSherpaOnnxTtsModel model,
    required String text,
    required double speed,
    required Directory outputDir,
  }) async {
    texts.add(text);
    speeds.add(speed);
    outputDirs.add(outputDir);
    await outputDir.create(recursive: true);
    return File('${outputDir.path}/fake.wav')
        .writeAsString('fake wav ${List.filled(64, '0').join()}');
  }
}

class _FakePlayback implements TtsAudioPlayback {
  _FakePlayback({this.playCompleter});

  final Completer<void>? playCompleter;
  final calls = <String>[];
  final playedPaths = <String>[];

  @override
  Future<void> playFile(String path) async {
    calls.add('play:$path');
    playedPaths.add(path);
    await playCompleter?.future;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}

class _FakeReadAloudService implements ReadAloudService, ReadAloudPreparer {
  final requests = <ReadAloudRequest>[];
  int stopCount = 0;
  int prepareCount = 0;

  @override
  Future<void> prepare(ReadAloudRequest request) async {
    prepareCount++;
  }

  @override
  Future<void> speak(ReadAloudRequest request) async {
    requests.add(request);
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

const _manifest = SherpaOnnxTtsManifest(
  engine: 'sherpa-onnx-matcha',
  name: 'matcha-icefall-zh-baker',
  locale: 'zh-CN',
  speaker: 'female',
  acousticModel: 'matcha-icefall-zh-baker/model-steps-3.onnx',
  vocoder: 'vocos-22khz-univ.onnx',
  tokens: 'matcha-icefall-zh-baker/tokens.txt',
  lexicon: 'matcha-icefall-zh-baker/lexicon.txt',
  ruleFsts: [
    'matcha-icefall-zh-baker/phone.fst',
    'matcha-icefall-zh-baker/date.fst',
    'matcha-icefall-zh-baker/number.fst',
  ],
  dictDir: 'matcha-icefall-zh-baker/dict',
  sampleRate: 22050,
);
