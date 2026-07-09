import 'dart:async';

import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_read_aloud_controller.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('角色消息优先使用快照，旧消息回退到当前角色音色', () {
    final participant = StoryParticipantModel(
      id: 7,
      roomId: 1,
      role: StoryParticipantRole.assistant,
      name: '风香',
      voiceStyle: TtsVoiceStyle.female.id,
    );
    final legacyMessage = StoryMessageModel(
      roomId: 1,
      speakerId: 7,
      speakerRole: participant.role,
      speakerName: participant.name,
      content: '旧消息',
    );
    expect(
      StoryRoomReadAloudVoiceResolver.resolve(legacyMessage, [participant]),
      TtsVoiceStyle.female.id,
    );

    legacyMessage.speakerVoiceStyle = TtsVoiceStyle.deep.id;
    expect(
      StoryRoomReadAloudVoiceResolver.resolve(legacyMessage, [participant]),
      TtsVoiceStyle.deep.id,
    );
  });

  test('朗读状态按准备、生成、播放、停止流转，并只保留一个活动消息', () async {
    final service = _FakeReadAloudService();
    final controller = StoryRoomReadAloudController(service: service);
    addTearDown(controller.dispose);
    final first = StoryMessageModel(
      roomId: 1,
      speakerId: 1,
      speakerRole: StoryParticipantRole.assistant,
      speakerName: '风香',
      content: '第一段',
    );
    final second = StoryMessageModel(
      roomId: 1,
      speakerId: 2,
      speakerRole: StoryParticipantRole.assistant,
      speakerName: '旁白',
      content: '第二段',
    );

    final firstTask = controller.start(
      message: first,
      voiceStyle: TtsVoiceStyle.female.id,
    );
    await _pump();
    expect(controller.state.status, StoryRoomReadAloudStatus.preparing);
    expect(service.request?.voiceStyle, TtsVoiceStyle.female.id);

    service.request!.onStage?.call(ReadAloudStage.synthesizing);
    expect(controller.state.status, StoryRoomReadAloudStatus.synthesizing);
    service.request!.onStage?.call(ReadAloudStage.playing);
    expect(controller.state.isPlaying, isTrue);

    final secondTask = controller.start(
      message: second,
      voiceStyle: TtsVoiceStyle.deep.id,
    );
    await _pump();
    expect(controller.state.messageCreatedAt, second.createdAt);
    expect(service.request?.voiceStyle, TtsVoiceStyle.deep.id);

    await controller.stop();
    await Future.wait([firstTask, secondTask]);
    expect(controller.state.isActive, isFalse);
    expect(service.stopCount, greaterThanOrEqualTo(2));
  });
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

class _FakeReadAloudService implements ReadAloudService {
  ReadAloudRequest? request;
  Completer<void>? _completion;
  int stopCount = 0;

  @override
  Future<void> speak(ReadAloudRequest next) {
    request = next;
    _completion = Completer<void>();
    next.onStage?.call(ReadAloudStage.preparing);
    return _completion!.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }
}
