/// HarmonyOS 空实现 stub —— 仅提供共享核心用到的 flutter_tts 公开 API，使
/// OHOS 壳可编译。真正朗读在调用点由平台守卫跳过，正常不会触达本文件。
library;

class FlutterTts {
  Future<int> awaitSpeakCompletion(bool enabled) async => 0;

  Future<List<Map<String, String>>> get getVoices async => const [];

  Future<int> setVoice(Map<String, String> voice) async => 0;

  Future<int> setLanguage(String language) async => 0;

  Future<int> setSpeechRate(double rate) async => 0;

  Future<int> setVolume(double volume) async => 0;

  Future<int> setPitch(double pitch) async => 0;

  Future<int> speak(String text) async => 0;

  Future<int> stop() async => 0;
}
