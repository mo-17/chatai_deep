import 'dart:async';
import 'package:chatgpt_app_core/voice/speech_input.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';

class FakeVoiceInput implements SpeechInput {
  final results = <Completer<String>>[];
  final partials = <void Function(String)?>[];
  final listening = <void Function()?>[];
  bool microphone = false;
  bool fail = false, deferReady = false, failCancel = false;
  int cancels = 0;
  @override
  Future<String> listen(
      {String? locale,
      void Function(String)? onPartial,
      void Function()? onListening}) {
    if (fail) return Future.error(const SpeechInputFailure('识别服务不可用'));
    final result = Completer<String>();
    results.add(result);
    partials.add(onPartial);
    listening.add(onListening);
    microphone = true;
    if (!deferReady) onListening?.call();
    return result.future;
  }

  void finish(String text) {
    if (!results.last.isCompleted) results.last.complete(text);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (failCancel) throw StateError('synthetic release failure');
    microphone = false;
    for (final result in results) {
      if (!result.isCompleted) result.complete('');
    }
  }
}

class FakeVoiceOutput extends ReadAloudService {
  final requests = <ReadAloudRequest>[];
  final completions = <Completer<void>>[];
  int stops = 0;
  bool fail = false, ignoreStop = false;
  @override
  Future<void> speak(ReadAloudRequest request) {
    requests.add(request);
    if (fail) return Future.error(StateError('synthetic playback failure'));
    final done = Completer<void>();
    completions.add(done);
    request.onStage?.call(ReadAloudStage.playing);
    return done.future;
  }

  void finish() {
    if (!completions.last.isCompleted) completions.last.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    if (!ignoreStop) {
      for (final done in completions) {
        if (!done.isCompleted) done.complete();
      }
    }
  }
}
