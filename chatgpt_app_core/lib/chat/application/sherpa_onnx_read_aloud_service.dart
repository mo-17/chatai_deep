import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

abstract class SherpaOnnxAssetInstaller {
  Future<InstalledSherpaOnnxTtsModel> ensureInstalled(
    BundledSherpaOnnxTtsModel model,
  );
}

class BundledSherpaOnnxAssetInstaller implements SherpaOnnxAssetInstaller {
  BundledSherpaOnnxAssetInstaller({
    AssetBundle? bundle,
    Future<Directory> Function()? baseDir,
  })  : _bundle = bundle ?? rootBundle,
        _baseDir = baseDir ?? getApplicationSupportDirectory;

  final AssetBundle _bundle;
  final Future<Directory> Function() _baseDir;

  @override
  Future<InstalledSherpaOnnxTtsModel> ensureInstalled(
    BundledSherpaOnnxTtsModel model,
  ) async {
    final base = await _baseDir();
    final root = Directory('${base.path}/tts_models/${model.id}');
    await root.create(recursive: true);
    for (final assetKey in model.fileAssetKeys) {
      final relative = assetKey.substring('${model.rootAsset}/'.length);
      final target = File('${root.path}/$relative');
      if (await target.exists() && await target.length() > 0) continue;
      await target.parent.create(recursive: true);
      final data = await _bundle.load(assetKey);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    final manifestText =
        await File('${root.path}/manifest.json').readAsString();
    final manifest = SherpaOnnxTtsManifest.decode(manifestText);
    final missing = model.missingRequiredAssets(manifest);
    if (missing.isNotEmpty) {
      throw StateError('Missing sherpa-onnx TTS assets: ${missing.join(', ')}');
    }
    return InstalledSherpaOnnxTtsModel(
      id: model.id,
      bundled: model,
      rootDir: root,
      manifest: manifest,
    );
  }
}

abstract class SherpaOnnxTtsRuntime {
  Future<void> prepare(InstalledSherpaOnnxTtsModel model) async {}

  Future<File> synthesize({
    required InstalledSherpaOnnxTtsModel model,
    required String text,
    required double speed,
    required Directory outputDir,
  });
}

class SherpaOnnxOfflineTtsRuntime implements SherpaOnnxTtsRuntime {
  SherpaOnnxOfflineTtsRuntime({this.runInBackground = true});

  static bool _initialized = false;
  final bool runInBackground;
  final _ttsByModelPath = <String, Future<sherpa.OfflineTts>>{};

  @override
  Future<void> prepare(InstalledSherpaOnnxTtsModel model) async {
    if (runInBackground) return;
    await _loadTts(model);
  }

  @override
  Future<File> synthesize({
    required InstalledSherpaOnnxTtsModel model,
    required String text,
    required double speed,
    required Directory outputDir,
  }) async {
    await outputDir.create(recursive: true);
    final outFile = File(
      '${outputDir.path}/sherpa_tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    if (runInBackground) {
      return Isolate.run(() => _synthesizeInBackground(
            _SherpaTtsJob.from(model, text, speed, outFile.path),
          ));
    }
    final tts = await _loadTts(model);
    return _synthesizeOnCurrentIsolate(
      tts: tts,
      text: text,
      speed: speed,
      outPath: outFile.path,
    );
  }

  Future<sherpa.OfflineTts> _loadTts(InstalledSherpaOnnxTtsModel model) {
    return _ttsByModelPath.putIfAbsent(model.rootDir.path, () async {
      if (!_initialized) {
        sherpa.initBindings();
        _initialized = true;
      }
      final manifest = model.manifest;
      return sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            matcha: sherpa.OfflineTtsMatchaModelConfig(
              acousticModel: model.resolve(manifest.acousticModel),
              vocoder: model.resolve(manifest.vocoder),
              lexicon: manifest.lexicon == null
                  ? ''
                  : model.resolve(manifest.lexicon!),
              tokens: model.resolve(manifest.tokens),
              dictDir: manifest.dictDir == null
                  ? ''
                  : model.resolve(manifest.dictDir!),
            ),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
          ruleFsts: manifest.ruleFsts.map(model.resolve).join(','),
          maxNumSenetences: 1,
        ),
      );
    });
  }

  static Future<File> _synthesizeOnCurrentIsolate({
    required sherpa.OfflineTts tts,
    required String text,
    required double speed,
    required String outPath,
  }) async {
    final audio = tts.generate(text: text, speed: speed);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw StateError('Empty sherpa-onnx audio result');
    }
    final ok = sherpa.writeWave(
      filename: outPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );
    if (!ok) throw StateError('Failed to write sherpa-onnx wav: $outPath');
    return File(outPath);
  }
}

class _SherpaTtsJob {
  final String acousticModel;
  final String vocoder;
  final String lexicon;
  final String tokens;
  final String dictDir;
  final List<String> ruleFsts;
  final String text;
  final double speed;
  final String outPath;

  const _SherpaTtsJob({
    required this.acousticModel,
    required this.vocoder,
    required this.lexicon,
    required this.tokens,
    required this.dictDir,
    required this.ruleFsts,
    required this.text,
    required this.speed,
    required this.outPath,
  });

  factory _SherpaTtsJob.from(
    InstalledSherpaOnnxTtsModel model,
    String text,
    double speed,
    String outPath,
  ) {
    final manifest = model.manifest;
    return _SherpaTtsJob(
      acousticModel: model.resolve(manifest.acousticModel),
      vocoder: model.resolve(manifest.vocoder),
      lexicon: manifest.lexicon == null ? '' : model.resolve(manifest.lexicon!),
      tokens: model.resolve(manifest.tokens),
      dictDir: manifest.dictDir == null ? '' : model.resolve(manifest.dictDir!),
      ruleFsts: [for (final fst in manifest.ruleFsts) model.resolve(fst)],
      text: text,
      speed: speed,
      outPath: outPath,
    );
  }
}

Future<File> _synthesizeInBackground(_SherpaTtsJob job) async {
  sherpa.initBindings();
  final tts = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        matcha: sherpa.OfflineTtsMatchaModelConfig(
          acousticModel: job.acousticModel,
          vocoder: job.vocoder,
          lexicon: job.lexicon,
          tokens: job.tokens,
          dictDir: job.dictDir,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      ruleFsts: job.ruleFsts.join(','),
      maxNumSenetences: 1,
    ),
  );
  try {
    final audio = tts.generate(text: job.text, speed: job.speed);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw StateError('Empty sherpa-onnx audio result');
    }
    final ok = sherpa.writeWave(
      filename: job.outPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );
    if (!ok) {
      throw StateError('Failed to write sherpa-onnx wav: ${job.outPath}');
    }
    return File(job.outPath);
  } finally {
    tts.free();
  }
}

abstract class TtsAudioPlayback {
  Future<void> playFile(String path);

  Future<void> stop();

  Future<void> dispose();
}

class AudioplayersTtsPlayback implements TtsAudioPlayback {
  AudioplayersTtsPlayback({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  Completer<void>? _activePlayback;

  @override
  Future<void> playFile(String path) async {
    await stop();
    final completed = Completer<void>();
    _activePlayback = completed;
    final subscription = _player.onPlayerComplete.listen((_) {
      if (!completed.isCompleted) completed.complete();
    });
    try {
      await _player.play(DeviceFileSource(path));
      await completed.future;
    } finally {
      await subscription.cancel();
      if (identical(_activePlayback, completed)) {
        _activePlayback = null;
      }
    }
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    final active = _activePlayback;
    if (active != null && !active.isCompleted) {
      active.complete();
    }
  }

  @override
  Future<void> dispose() => _player.dispose();
}

class SherpaOnnxReadAloudService
    implements ReadAloudService, ReadAloudPreparer {
  SherpaOnnxReadAloudService({
    SherpaOnnxAssetInstaller? installer,
    SherpaOnnxTtsRuntime? runtime,
    TtsAudioPlayback? playback,
    Future<Directory> Function()? outputDir,
    bool Function()? isSupported,
    UserSherpaOnnxTtsModelStore? userModelStore,
    BundledSherpaOnnxTtsModel model = BundledSherpaOnnxTtsModel.matchaZhBaker,
  })  : _installer = installer ?? BundledSherpaOnnxAssetInstaller(),
        _runtime = runtime ?? SherpaOnnxOfflineTtsRuntime(),
        _playback = playback ?? AudioplayersTtsPlayback(),
        _outputDir = outputDir ?? getTemporaryDirectory,
        _isSupported =
            isSupported ?? (() => SherpaOnnxReadAloudService.isSupported),
        _userModelStore = userModelStore ?? UserSherpaOnnxTtsModelStore(),
        _model = model;

  final SherpaOnnxAssetInstaller _installer;
  final SherpaOnnxTtsRuntime _runtime;
  final TtsAudioPlayback _playback;
  final Future<Directory> Function() _outputDir;
  final bool Function() _isSupported;
  final UserSherpaOnnxTtsModelStore _userModelStore;
  final BundledSherpaOnnxTtsModel _model;

  static bool get isSupported {
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> prepare(ReadAloudRequest request) async {
    if (!_isSupported()) return;
    if (!_usesSherpa(request.voiceStyle)) return;
    try {
      final installed = await _installedModelFor(request.voiceStyle);
      await _runtime.prepare(installed);
    } catch (e) {
      AILogger.log('sherpa-onnx prepare failed: $e');
    }
  }

  @override
  Future<void> speak(ReadAloudRequest request) async {
    if (!_isSupported()) return;
    final text = request.text.trim();
    if (text.isEmpty) return;
    try {
      request.onStage?.call(ReadAloudStage.preparing);
      await _playback.stop();
      if (request.isCancelled?.call() == true) return;
      final installed = await _installedModelFor(request.voiceStyle);
      final speed = ReadAloudCoordinator.normalizeRate(request.rate);
      final cacheFile = await _cacheFileFor(
        installed: installed,
        text: text,
        speed: speed,
        baseDir: await _outputDir(),
      );
      if (request.isCancelled?.call() == true) return;
      if (await _isUsableWav(cacheFile)) {
        if (request.isCancelled?.call() == true) return;
        request.onStage?.call(ReadAloudStage.playing);
        await _playback.playFile(cacheFile.path);
        if (request.isCancelled?.call() != true) {
          request.onStage?.call(ReadAloudStage.completed);
        }
        return;
      }
      request.onStage?.call(ReadAloudStage.synthesizing);
      final wav = await _runtime.synthesize(
        model: installed,
        text: text,
        speed: speed,
        outputDir: cacheFile.parent,
      );
      final playable = await _storeCache(wav, cacheFile);
      if (request.isCancelled?.call() == true) return;
      request.onStage?.call(ReadAloudStage.playing);
      await _playback.playFile(playable.path);
      if (request.isCancelled?.call() != true) {
        request.onStage?.call(ReadAloudStage.completed);
      }
    } catch (e) {
      AILogger.log('sherpa-onnx speak failed: $e');
      request.onStage?.call(ReadAloudStage.completed);
    }
  }

  Future<File> _cacheFileFor({
    required InstalledSherpaOnnxTtsModel installed,
    required String text,
    required double speed,
    required Directory baseDir,
  }) async {
    final dir = Directory('${baseDir.path}/tts_audio_cache/${_model.id}');
    await dir.create(recursive: true);
    final digest = sha256.convert(utf8.encode([
      installed.id,
      installed.manifest.name,
      installed.manifest.locale,
      installed.manifest.speaker,
      installed.manifest.sampleRate,
      speed.toStringAsFixed(3),
      text,
    ].join('\n')));
    return File('${dir.path}/$digest.wav');
  }

  Future<bool> _isUsableWav(File file) async {
    try {
      return await file.exists() && await file.length() > 44;
    } catch (_) {
      return false;
    }
  }

  Future<File> _storeCache(File generated, File cacheFile) async {
    if (generated.path == cacheFile.path) return cacheFile;
    await cacheFile.parent.create(recursive: true);
    final tmp = File('${cacheFile.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
    await generated.copy(tmp.path);
    if (await cacheFile.exists()) await cacheFile.delete();
    await tmp.rename(cacheFile.path);
    return cacheFile;
  }

  @override
  Future<void> stop() => _playback.stop();

  bool _usesSherpa(String? voiceStyle) =>
      voiceStyle == TtsVoiceStyle.offlineZhFemale.id ||
      UserSherpaOnnxTtsModelStore.isUserVoiceStyle(voiceStyle);

  Future<InstalledSherpaOnnxTtsModel> _installedModelFor(
    String? voiceStyle,
  ) {
    if (UserSherpaOnnxTtsModelStore.isUserVoiceStyle(voiceStyle)) {
      return _userModelStore.resolveInstalled(voiceStyle!);
    }
    return _installer.ensureInstalled(_model);
  }
}

class HybridReadAloudService implements ReadAloudService, ReadAloudPreparer {
  HybridReadAloudService({
    ReadAloudService? system,
    ReadAloudService? offline,
  })  : _system = system ?? FlutterTtsReadAloudService(),
        _offline = offline ?? SherpaOnnxReadAloudService();

  final ReadAloudService _system;
  final ReadAloudService _offline;

  @override
  Future<void> prepare(ReadAloudRequest request) async {
    if (request.voiceStyle != TtsVoiceStyle.offlineZhFemale.id &&
        !UserSherpaOnnxTtsModelStore.isUserVoiceStyle(request.voiceStyle)) {
      return;
    }
    final service = _offline;
    if (service is ReadAloudPreparer) {
      await (service as ReadAloudPreparer).prepare(request);
    }
  }

  @override
  Future<void> speak(ReadAloudRequest request) {
    if (request.voiceStyle == TtsVoiceStyle.offlineZhFemale.id ||
        UserSherpaOnnxTtsModelStore.isUserVoiceStyle(request.voiceStyle)) {
      return _offline.speak(request);
    }
    return _system.speak(request);
  }

  @override
  Future<void> stop() async {
    await _system.stop();
    await _offline.stop();
  }
}
