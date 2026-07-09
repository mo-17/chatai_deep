import 'dart:async';

import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter/foundation.dart';

enum StoryRoomReadAloudStatus { idle, preparing, synthesizing, playing }

class StoryRoomReadAloudState {
  final int? messageCreatedAt;
  final StoryRoomReadAloudStatus status;

  const StoryRoomReadAloudState({
    this.messageCreatedAt,
    this.status = StoryRoomReadAloudStatus.idle,
  });

  bool get isActive => messageCreatedAt != null;
  bool get isGenerating =>
      status == StoryRoomReadAloudStatus.preparing ||
      status == StoryRoomReadAloudStatus.synthesizing;
  bool get isPlaying => status == StoryRoomReadAloudStatus.playing;

  bool isActiveFor(StoryMessageModel message) =>
      isActive && messageCreatedAt == message.createdAt;
}

class StoryRoomReadAloudVoiceResolver {
  const StoryRoomReadAloudVoiceResolver._();

  static String resolve(
    StoryMessageModel message,
    Iterable<StoryParticipantModel> participants,
  ) {
    final snapshot = message.speakerVoiceStyle?.trim();
    if (snapshot != null && snapshot.isNotEmpty) return snapshot;
    for (final participant in participants) {
      if (participant.id != message.speakerId) continue;
      final current = participant.voiceStyle?.trim();
      if (current != null && current.isNotEmpty) return current;
      break;
    }
    return TtsVoiceStyle.system.id;
  }
}

class StoryRoomReadAloudController extends ChangeNotifier {
  StoryRoomReadAloudController({ReadAloudService? service})
      : _service = service ?? HybridReadAloudService();

  final ReadAloudService _service;
  StoryRoomReadAloudState _state = const StoryRoomReadAloudState();
  Future<void>? _inFlight;
  int _generation = 0;
  bool _disposed = false;

  StoryRoomReadAloudState get state => _state;

  Future<void> toggle({
    required StoryMessageModel message,
    required String voiceStyle,
    String? locale,
    double? rate,
  }) {
    if (state.isActiveFor(message)) return stop();
    return start(
      message: message,
      voiceStyle: voiceStyle,
      locale: locale,
      rate: rate,
    );
  }

  Future<void> start({
    required StoryMessageModel message,
    required String voiceStyle,
    String? locale,
    double? rate,
  }) async {
    final text = message.content.trim();
    if (text.isEmpty || _disposed) return;
    final generation = ++_generation;
    await _service.stop();
    if (!_isCurrent(generation)) return;
    _setState(StoryRoomReadAloudState(
      messageCreatedAt: message.createdAt,
      status: StoryRoomReadAloudStatus.preparing,
    ));
    final task = _run(
      generation: generation,
      message: message,
      voiceStyle: voiceStyle,
      locale: locale,
      rate: rate,
    );
    _inFlight = task;
    await task;
    if (identical(_inFlight, task)) _inFlight = null;
  }

  Future<void> _run({
    required int generation,
    required StoryMessageModel message,
    required String voiceStyle,
    required String? locale,
    required double? rate,
  }) async {
    try {
      await ReadAloudCoordinator.maybeSpeak(
        service: _service,
        text: message.content,
        enabled: true,
        locale: locale,
        rate: rate,
        voiceStyle: voiceStyle,
        isCancelled: () => !_isCurrent(generation),
        onStage: (stage) {
          if (!_isCurrent(generation)) return;
          final status = switch (stage) {
            ReadAloudStage.preparing => StoryRoomReadAloudStatus.preparing,
            ReadAloudStage.synthesizing =>
              StoryRoomReadAloudStatus.synthesizing,
            ReadAloudStage.playing => StoryRoomReadAloudStatus.playing,
            ReadAloudStage.completed => StoryRoomReadAloudStatus.idle,
          };
          if (status == StoryRoomReadAloudStatus.idle) return;
          _setState(StoryRoomReadAloudState(
            messageCreatedAt: message.createdAt,
            status: status,
          ));
        },
      );
    } finally {
      if (_isCurrent(generation)) {
        _setState(const StoryRoomReadAloudState());
      }
    }
  }

  Future<void> stop() async {
    ++_generation;
    if (!_disposed) _setState(const StoryRoomReadAloudState());
    await _service.stop();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _setState(StoryRoomReadAloudState next) {
    if (_disposed ||
        next.messageCreatedAt == _state.messageCreatedAt &&
            next.status == _state.status) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_service.stop());
    super.dispose();
  }
}
