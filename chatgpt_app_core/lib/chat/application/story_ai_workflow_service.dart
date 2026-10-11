import 'story_role_card_context.dart';
import 'package:chatgpt_app_core/chat/application/story_artifact_context_builder.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

enum StoryAiWorkflowKind { directorReview, worldBookConsistency }

class StoryAiWorkflowRequest {
  final StoryAiWorkflowKind kind;
  final String title;
  final String prompt;
  final List<Map<String, dynamic>> history;

  const StoryAiWorkflowRequest({
    required this.kind,
    required this.title,
    required this.prompt,
    required this.history,
  });

  String get usagePrompt => [
        for (final message in history)
          '${message['role']}：${message['content']}',
        'user：$prompt',
      ].join('\n');
}

/// 创作工作台的 AI 输入与可保存结果的纯逻辑。
///
/// 工作台已把资料快照写入房间公共上下文；这里先剥离该快照，再单独按预算
/// 注入资料，避免同一内容重复占用模型上下文。
class StoryAiWorkflowService {
  static const maxPublicContextCharacters = 6000;
  static const maxArtifactContextCharacters = 6000;

  const StoryAiWorkflowService._();

  static StoryAiWorkflowRequest prepare({
    required StoryAiWorkflowKind kind,
    required StoryRoomModel room,
    required List<StoryArtifactModel> artifacts,
    List<StoryParticipantModel>? participants,
  }) {
    final projection =
        StoryRoleCardContext.read(room, participants: participants);
    final publicContext = _clip(
      projection.isCardSource
          ? projection.basePublicText
          : _basePublicContext(projection.publicText),
      maxPublicContextCharacters,
    );
    final artifactContext = StoryArtifactContextBuilder.build(
      artifacts,
      maxCharacters: maxArtifactContextCharacters,
    );
    final title = titleFor(kind);
    final material = [
      '房间：${room.title.trim().isEmpty ? '未命名创作房间' : room.title.trim()}',
      '【公共上下文】',
      publicContext.isEmpty ? '（未填写）' : publicContext,
      '【工作台资料】',
      artifactContext.isEmpty ? '（暂无）' : artifactContext,
    ].join('\n');
    return StoryAiWorkflowRequest(
      kind: kind,
      title: title,
      history: [
        {
          'role': 'system',
          'content': _systemPromptFor(kind),
        },
      ],
      prompt: '${_taskPromptFor(kind)}\n\n$material',
    );
  }

  static StoryArtifactModel resultArtifact({
    required StoryAiWorkflowRequest request,
    required int roomId,
    required int sortOrder,
    required String content,
    bool stopped = false,
    int? createdAt,
  }) {
    final suffix = stopped ? '（未完成）' : '';
    return StoryArtifactModel(
      roomId: roomId,
      type: StoryArtifactType.outline,
      title: '${request.title}$suffix',
      content: content.trim(),
      status: stopped ? 'AI 部分生成' : 'AI 生成',
      sortOrder: sortOrder,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  static String titleFor(StoryAiWorkflowKind kind) {
    switch (kind) {
      case StoryAiWorkflowKind.directorReview:
        return '剧情导演审阅';
      case StoryAiWorkflowKind.worldBookConsistency:
        return '世界书一致性检查';
    }
  }

  static String _systemPromptFor(StoryAiWorkflowKind kind) {
    switch (kind) {
      case StoryAiWorkflowKind.directorReview:
        return '你是一位严谨的剧情导演和小说编辑。只依据提供的资料判断，'
            '不要把猜测写成既定事实。建议必须具体、可执行，并尽量指出对应人物、'
            '章节、事件或资料标题。';
      case StoryAiWorkflowKind.worldBookConsistency:
        return '你是一位严谨的世界观编辑。只依据提供的资料判断，'
            '不要臆造设定。请区分明确冲突、信息缺口和可选优化，'
            '并给出可直接补入世界书或工作台的更新建议。';
    }
  }

  static String _taskPromptFor(StoryAiWorkflowKind kind) {
    switch (kind) {
      case StoryAiWorkflowKind.directorReview:
        return '审阅以下创作资料，按 Markdown 输出：\n'
            '1. 总体判断（不超过 3 条）\n'
            '2. 冲突与逻辑断点\n'
            '3. 伏笔状态与回收建议\n'
            '4. 节奏问题与章节级调整建议\n'
            '5. 人物动机检查与可执行改写建议\n'
            '每条请标注严重度：高/中/低；没有问题的项也要明确写“未发现”。';
      case StoryAiWorkflowKind.worldBookConsistency:
        return '检查以下世界书与创作资料的一致性，按 Markdown 输出：\n'
            '1. 明确设定冲突（引用相互矛盾的信息）\n'
            '2. 设定缺口（会影响后续创作但尚未定义的信息）\n'
            '3. 时间线、规则、人物关系的风险点\n'
            '4. 建议新增或更新的世界书条目（标题 + 可直接使用的正文）\n'
            '每条请标注确定性：明确/待确认；没有冲突时也要明确写“未发现”。';
    }
  }

  static String _basePublicContext(String publicContext) {
    final markerIndex =
        publicContext.indexOf(StoryArtifactContextBuilder.marker);
    return (markerIndex < 0
            ? publicContext
            : publicContext.substring(0, markerIndex))
        .trim();
  }

  static String _clip(String text, int maxCharacters) {
    if (text.length <= maxCharacters) return text;
    if (maxCharacters <= 3) return text.substring(0, maxCharacters);
    return '${text.substring(0, maxCharacters - 3).trimRight()}...';
  }
}
