import 'package:flutter/services.dart';

/// 系统离线音色；每段等待真实播报结束，停止后不会继续下一段。
class FlutterTts {
  static const _channel = MethodChannel('com.hzb.flutter_ai/tts');
  String _language = 'zh-CN';
  int _person = 0;
  double _rate = 0.5, _volume = 1, _pitch = 1;
  // 原生播放引擎为进程级资源，不同页面的实例也必须使旧的分段队列失效。
  static int _epoch = 0;
  Future<dynamic> get getVoices => _channel.invokeListMethod<dynamic>('voices');
  Future<int> awaitSpeakCompletion(bool enabled) async => 1;
  Future<int> setLanguage(String language) async {
    _language = language.replaceAll('_', '-');
    return 1;
  }

  Future<int> setVoice(Map<String, String> voice) async {
    _person = int.tryParse(voice['identifier'] ?? voice['name'] ?? '') ?? 0;
    _language = voice['locale'] ?? _language;
    return 1;
  }

  Future<int> setSpeechRate(double rate) async {
    _rate = rate;
    return 1;
  }

  Future<int> setVolume(double volume) async {
    _volume = volume;
    return 1;
  }

  Future<int> setPitch(double pitch) async {
    _pitch = pitch;
    return 1;
  }

  Future<int> speak(String text) async {
    final epoch = ++_epoch;
    var offset = 0;
    while (offset < text.length) {
      var end = (offset + 1000).clamp(0, text.length);
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff)
        end--;
      if (epoch != _epoch) return 0;
      try {
        final result = await _channel.invokeMethod<int>('speak', {
          'text': text.substring(offset, end),
          'language': _language,
          'person': _person,
          'speed': (_rate * 2).clamp(0.5, 2.0),
          'volume': _volume,
          'pitch': _pitch,
        });
        if (result != 1 || epoch != _epoch) return 0;
      } catch (_) {
        if (epoch != _epoch) return 0;
        rethrow;
      }
      offset = end;
    }
    return 1;
  }

  Future<int> stop() async {
    _epoch++;
    return await _channel.invokeMethod<int>('stop') ?? 0;
  }
}
