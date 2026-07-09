import 'package:chatgpt_app_core/chat/application/story_ai_workflow_service.dart';
import 'package:chatgpt_app_core/chat/application/story_artifact_context_builder.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final artifacts = [
    StoryArtifactModel(
      roomId: 7,
      type: StoryArtifactType.outline,
      title: '主线',
      content: '主角在雨夜寻找失落的城市。',
    ),
    StoryArtifactModel(
      roomId: 7,
      type: StoryArtifactType.foreshadowing,
      title: '怀表',
      content: '第三章回收。',
      status: '未回收',
    ),
  ];

  test('剧情导演审阅带入基础公共上下文和资料，但不重复工作台快照', () {
    final room = StoryRoomModel(
      id: 7,
      title: '雨夜书店',
      publicContext: StoryArtifactContextBuilder.mergeIntoPublicContext(
        '文风：冷峻克制。',
        artifacts,
      ),
    );

    final request = StoryAiWorkflowService.prepare(
      kind: StoryAiWorkflowKind.directorReview,
      room: room,
      artifacts: artifacts,
    );

    expect(request.title, '剧情导演审阅');
    expect(request.history.single['content'], contains('剧情导演'));
    expect(request.prompt, contains('文风：冷峻克制。'));
    expect(request.prompt, contains('怀表'), reason: '资料应单独带入');
    expect(request.prompt.split('怀表'), hasLength(2), reason: '资料快照不能重复');
    expect(request.usagePrompt, contains('system：'));
    expect(request.usagePrompt, contains('user：'));
  });

  test('世界书检查使用固定预算并准备可保存的部分结果', () {
    final room = StoryRoomModel(
      id: 7,
      title: '长篇',
      publicContext: List.filled(7000, '设').join(),
    );
    final request = StoryAiWorkflowService.prepare(
      kind: StoryAiWorkflowKind.worldBookConsistency,
      room: room,
      artifacts: artifacts,
    );
    final artifact = StoryAiWorkflowService.resultArtifact(
      request: request,
      roomId: 7,
      sortOrder: 4,
      content: '## 明确设定冲突\n未完成的检查结果。',
      stopped: true,
      createdAt: 123,
    );

    expect(request.title, '世界书一致性检查');
    expect(request.prompt, contains('建议新增或更新的世界书条目'));
    expect(request.prompt.length, lessThanOrEqualTo(6000 + 6000 + 2000));
    expect(artifact.type, StoryArtifactType.outline);
    expect(artifact.title, '世界书一致性检查（未完成）');
    expect(artifact.status, 'AI 部分生成');
    expect(artifact.createdAt, 123);
  });
}
