import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

class ReadAloudRequest {
  final String text;
  final String? locale;
  final double rate;
  final String? voiceStyle;
  final void Function(ReadAloudStage stage)? onStage;
  final bool Function()? isCancelled;

  const ReadAloudRequest({
    required this.text,
    this.locale,
    this.rate = 1.0,
    this.voiceStyle,
    this.onStage,
    this.isCancelled,
  });
}

enum ReadAloudStage { preparing, synthesizing, playing, completed }

class ReadAloudStageUi {
  const ReadAloudStageUi._();

  static String label(ReadAloudStage? stage) => switch (stage) {
        ReadAloudStage.preparing => '准备中',
        ReadAloudStage.synthesizing => '生成音频中',
        ReadAloudStage.playing => '播放中',
        ReadAloudStage.completed || null => '处理中',
      };

  static bool showsProgress(ReadAloudStage? stage) => switch (stage) {
        ReadAloudStage.preparing || ReadAloudStage.synthesizing => true,
        ReadAloudStage.playing || ReadAloudStage.completed || null => false,
      };
}

class TtsVoiceStyle {
  final String id;
  final String label;
  final String description;

  const TtsVoiceStyle({
    required this.id,
    required this.label,
    required this.description,
  });

  static const system = TtsVoiceStyle(
    id: 'system',
    label: '系统默认',
    description: '使用系统当前默认声音',
  );
  static const female = TtsVoiceStyle(
    id: 'female',
    label: '女声优先',
    description: '优先选择系统女声，声音略清亮',
  );
  static const male = TtsVoiceStyle(
    id: 'male',
    label: '男声优先',
    description: '优先选择系统男声，音色略低',
  );
  static const bright = TtsVoiceStyle(
    id: 'bright',
    label: '清亮高音',
    description: '提高音调与语速，适合短回答',
  );
  static const deep = TtsVoiceStyle(
    id: 'deep',
    label: '低沉慢速',
    description: '降低音调与语速，适合长文朗读',
  );
  static const offlineZhFemale = TtsVoiceStyle(
    id: 'sherpa_matcha_zh_baker',
    label: '内置离线中文女声',
    description: '使用随 app 打包的 sherpa-onnx Matcha 中文模型离线合成',
  );

  static const all = [system, female, male, bright, deep, offlineZhFemale];

  static bool isValid(String? id) =>
      id == null || all.any((style) => style.id == id);

  static TtsVoiceStyle byId(String? id) {
    for (final style in all) {
      if (style.id == id) return style;
    }
    return system;
  }
}

abstract class ReadAloudService {
  Future<void> speak(ReadAloudRequest request);

  Future<void> stop() async {}
}

abstract class ReadAloudPreparer {
  Future<void> prepare(ReadAloudRequest request);
}

class NoopReadAloudService implements ReadAloudService {
  const NoopReadAloudService();

  @override
  Future<void> speak(ReadAloudRequest request) async {}

  @override
  Future<void> stop() async {}
}

abstract class TtsEngine {
  Future<dynamic> getVoices();

  Future<dynamic> awaitSpeakCompletion(bool enabled);

  Future<dynamic> setVoice(Map<String, String> voice);

  Future<dynamic> setLanguage(String language);

  Future<dynamic> setSpeechRate(double rate);

  Future<dynamic> setVolume(double volume);

  Future<dynamic> setPitch(double pitch);

  Future<dynamic> speak(String text);

  Future<dynamic> stop();
}

class FlutterTtsEngine implements TtsEngine {
  FlutterTtsEngine({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<dynamic> getVoices() => _tts.getVoices;

  @override
  Future<dynamic> awaitSpeakCompletion(bool enabled) =>
      _tts.awaitSpeakCompletion(enabled);

  @override
  Future<dynamic> setVoice(Map<String, String> voice) => _tts.setVoice(voice);

  @override
  Future<dynamic> setLanguage(String language) => _tts.setLanguage(language);

  @override
  Future<dynamic> setSpeechRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<dynamic> setVolume(double volume) => _tts.setVolume(volume);

  @override
  Future<dynamic> setPitch(double pitch) => _tts.setPitch(pitch);

  @override
  Future<dynamic> speak(String text) => _tts.speak(text);

  @override
  Future<dynamic> stop() => _tts.stop();
}

class FlutterTtsReadAloudService implements ReadAloudService {
  FlutterTtsReadAloudService({TtsEngine? engine})
      : _engine = engine ?? FlutterTtsEngine();

  final TtsEngine _engine;

  static bool get isSupported {
    try {
      return Platform.operatingSystem != 'ohos';
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> speak(ReadAloudRequest request) async {
    if (!isSupported) return;
    try {
      request.onStage?.call(ReadAloudStage.preparing);
      await _engine.stop();
      if (request.isCancelled?.call() == true) return;
      if (request.locale != null) {
        await _engine.setLanguage(request.locale!);
      }
      final style = TtsVoiceStyle.byId(request.voiceStyle);
      await _applyVoice(style, request.locale);
      await _engine.setSpeechRate(_pluginRate(request.rate, style));
      await _engine.setVolume(1.0);
      await _engine.setPitch(_pitchFor(style));
      if (request.isCancelled?.call() == true) return;
      await _engine.awaitSpeakCompletion(true);
      request.onStage?.call(ReadAloudStage.playing);
      await _engine.speak(request.text);
      if (request.isCancelled?.call() != true) {
        request.onStage?.call(ReadAloudStage.completed);
      }
    } catch (e) {
      AILogger.log('flutter_tts speak failed: $e');
      request.onStage?.call(ReadAloudStage.completed);
    }
  }

  @override
  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _engine.stop();
    } catch (e) {
      AILogger.log('flutter_tts stop failed: $e');
    }
  }

  Future<void> _applyVoice(TtsVoiceStyle style, String? locale) async {
    final preferredGender = switch (style.id) {
      'female' || 'bright' => 'female',
      'male' || 'deep' => 'male',
      _ => null,
    };
    if (preferredGender == null) return;
    final voice = _pickVoice(
      await _engine.getVoices(),
      locale: locale,
      preferredGender: preferredGender,
    );
    if (voice != null) await _engine.setVoice(voice);
  }

  static double _pluginRate(double rate, TtsVoiceStyle style) {
    final normalized = ReadAloudCoordinator.normalizeRate(rate);
    final multiplier = switch (style.id) {
      'bright' => 1.08,
      'deep' => 0.9,
      _ => 1.0,
    };
    return ((normalized / 2) * multiplier).clamp(0.25, 1.0).toDouble();
  }

  static double _pitchFor(TtsVoiceStyle style) => switch (style.id) {
        'female' => 1.08,
        'male' => 0.92,
        'bright' => 1.16,
        'deep' => 0.82,
        _ => 1.0,
      };

  static Map<String, String>? _pickVoice(
    dynamic rawVoices, {
    required String? locale,
    required String preferredGender,
  }) {
    if (rawVoices is! Iterable) return null;
    final normalizedLocale = locale?.toLowerCase().replaceAll('_', '-');
    final voices = <Map<String, String>>[];
    for (final raw in rawVoices) {
      if (raw is! Map) continue;
      final mapped = <String, String>{};
      for (final entry in raw.entries) {
        final key = entry.key?.toString();
        final value = entry.value?.toString();
        if (key != null && value != null) mapped[key] = value;
      }
      if (mapped['name'] != null || mapped['identifier'] != null) {
        voices.add(mapped);
      }
    }
    if (voices.isEmpty) return null;
    bool localeMatches(Map<String, String> voice) {
      if (normalizedLocale == null || normalizedLocale.isEmpty) return true;
      final voiceLocale = voice['locale']?.toLowerCase().replaceAll('_', '-');
      return voiceLocale == normalizedLocale ||
          (voiceLocale?.startsWith(normalizedLocale.split('-').first) ?? false);
    }

    bool genderMatches(Map<String, String> voice) {
      final gender = voice['gender']?.toLowerCase().trim();
      if (gender != null && gender.isNotEmpty) return gender == preferredGender;
      final haystack = '${voice['name'] ?? ''} ${voice['identifier'] ?? ''}'
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z]+'), ' ');
      return haystack.split(' ').contains(preferredGender);
    }

    for (final voice in voices) {
      if (localeMatches(voice) && genderMatches(voice)) return voice;
    }
    for (final voice in voices) {
      if (genderMatches(voice)) return voice;
    }
    return null;
  }
}

class ReadAloudCoordinator {
  const ReadAloudCoordinator._();

  static Future<bool> maybeSpeak({
    required ReadAloudService service,
    required String text,
    required bool? enabled,
    String? locale,
    double? rate,
    String? voiceStyle,
    void Function(ReadAloudStage stage)? onStage,
    bool Function()? isCancelled,
  }) async {
    if (enabled != true) return false;
    final content = text.trim();
    if (content.isEmpty) return false;
    if (isCancelled?.call() == true) return false;
    await service.speak(ReadAloudRequest(
      text: content,
      locale: normalizeLocale(locale),
      rate: normalizeRate(rate),
      voiceStyle: normalizeVoiceStyle(voiceStyle),
      onStage: onStage,
      isCancelled: isCancelled,
    ));
    return true;
  }

  static String? normalizeLocale(String? locale) {
    final value = locale?.trim();
    if (value == null || value.isEmpty) return null;
    return value.replaceAll('_', '-');
  }

  static double normalizeRate(double? rate) {
    final value = rate ?? 1.0;
    if (value < 0.5) return 0.5;
    if (value > 2.0) return 2.0;
    return value;
  }

  static String? normalizeVoiceStyle(String? voiceStyle) {
    final value = voiceStyle?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('custom_sherpa:') &&
        value.length > 'custom_sherpa:'.length) {
      return value;
    }
    return TtsVoiceStyle.isValid(value) ? value : null;
  }
}
