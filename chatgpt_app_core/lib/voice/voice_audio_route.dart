import 'package:flutter/services.dart';
import 'package:login_sdk/platform/app_io.dart';

class VoiceAudioRoute {
  static const channel = MethodChannel('aipu/voice-audio');
  Future<bool> prepareHeadset() async {
    try {
      final result =
          await channel.invokeMapMethod<String, dynamic>('prepareHeadset');
      return result?['safeDuplex'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> headsetStillConnected() async {
    try {
      return await channel.invokeMethod<bool>('headsetConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> release() async {
    try {
      await channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // 桌面和测试环境没有移动音频路由插件。
    } on PlatformException {
      if (Platform.operatingSystem == 'ohos') rethrow;
      // 其余收音、播放和请求清理仍继续执行。
    }
  }
}
