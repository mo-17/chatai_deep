import 'read_aloud_service.dart';

/// Web 使用系统语音合成，原生离线引擎不会进入浏览器编译依赖。
class HybridReadAloudService implements ReadAloudService, ReadAloudPreparer {
  final ReadAloudService _system;
  HybridReadAloudService(
      {ReadAloudService? system,
      ReadAloudService? offline,
      ReadAloudService Function()? offlineFactory,
      bool Function()? offlineSupported})
      : _system = system ?? FlutterTtsReadAloudService();
  @override
  Future<void> prepare(ReadAloudRequest request) async {}
  @override
  Future<void> speak(ReadAloudRequest request) =>
      _system.speak(ReadAloudRequest(
        text: request.text,
        locale: request.locale,
        rate: request.rate,
        voiceStyle: request.voiceStyle?.startsWith('sherpa') == true
            ? TtsVoiceStyle.system.id
            : request.voiceStyle,
        onStage: request.onStage,
        isCancelled: request.isCancelled,
        throwOnError: request.throwOnError,
      ));
  @override
  Future<void> stop() => _system.stop();
}
