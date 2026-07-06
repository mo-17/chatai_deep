import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_state_suggester.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('从单条用户消息生成会话状态草稿', () {
    final draft = ConversationRoleStateSuggester.fromMessage(
      conversation: ConversationModel(cid: 1, icon: ''),
      assistant: AssistantModel(name: '艾琳'),
      message: MessageModel(
        ownerType: OwnerType.sender,
        content: '我们回到雨夜旧书店二楼，窗外钟声很近',
        createdAt: 1,
        avatar: '',
        ownerName: 'user',
      ),
    );

    expect(draft.scene, '延续最近话题：我们回到雨夜旧书店二楼，窗外钟声很近');
    expect(draft.relationship, '用户与艾琳正在持续对话');
    expect(draft.toneNote, '延续当前对话语气');
  });

  test('从单条助手消息生成语气草稿，并保留已有会话状态', () {
    final draft = ConversationRoleStateSuggester.fromMessage(
      conversation: ConversationModel(
        cid: 2,
        icon: '',
        roleScene: '旧书店二楼',
      ),
      assistant: AssistantModel(name: '艾琳'),
      message: MessageModel(
        ownerType: OwnerType.receiver,
        content: '我把声音压低，只留下一句很短的提醒。',
        createdAt: 2,
        avatar: '',
        ownerName: '艾琳',
      ),
    );

    expect(draft.scene, '旧书店二楼');
    expect(draft.relationship, '用户与艾琳正在持续对话');
    expect(draft.toneNote, '延续最近回复语气：我把声音压低，只留下一句很短的提醒。');
  });

  test('从最近用户和助手消息生成可编辑会话状态草稿', () {
    final draft = ConversationRoleStateSuggester.suggest(
      conversation: ConversationModel(cid: 1, icon: ''),
      assistant: AssistantModel(name: '艾琳'),
      messages: [
        MessageModel(
          ownerType: OwnerType.sender,
          content: '我们刚到雨夜旧书店，门口的铜铃响了',
          createdAt: 1,
          avatar: '',
          ownerName: 'user',
        ),
        MessageModel(
          ownerType: OwnerType.receiver,
          content: '我把灯调暗一点，声音压得很轻。',
          createdAt: 2,
          avatar: '',
          ownerName: '艾琳',
        ),
      ],
    );

    expect(draft, isNotNull);
    expect(draft!.scene, '延续最近话题：我们刚到雨夜旧书店，门口的铜铃响了');
    expect(draft.relationship, '用户与艾琳正在持续对话');
    expect(draft.toneNote, '延续最近回复语气：我把灯调暗一点，声音压得很轻。');
  });

  test('已有会话状态优先保留，只补空字段', () {
    final draft = ConversationRoleStateSuggester.suggest(
      conversation: ConversationModel(
        cid: 2,
        icon: '',
        roleScene: '旧书店二楼',
      ),
      assistant: AssistantModel(name: '艾琳'),
      messages: [
        MessageModel(
          ownerType: OwnerType.sender,
          content: '继续刚才的谈话',
          createdAt: 1,
          avatar: '',
          ownerName: 'user',
        ),
      ],
    );

    expect(draft, isNotNull);
    expect(draft!.scene, '旧书店二楼');
    expect(draft.relationship, '用户与艾琳正在持续对话');
    expect(draft.toneNote, '延续当前对话语气');
  });

  test('按创建时间选择最新消息，不依赖列表顺序', () {
    final draft = ConversationRoleStateSuggester.suggest(
      conversation: ConversationModel(cid: 4, icon: ''),
      assistant: AssistantModel(name: '艾琳'),
      messages: [
        MessageModel(
          ownerType: OwnerType.receiver,
          content: '旧回复会被忽略',
          createdAt: 5,
          avatar: '',
          ownerName: '艾琳',
        ),
        MessageModel(
          ownerType: OwnerType.sender,
          content: '旧场景会被忽略',
          createdAt: 10,
          avatar: '',
          ownerName: 'user',
        ),
        MessageModel(
          ownerType: OwnerType.receiver,
          content: '我把伞收起来，示意你先坐下。',
          createdAt: 30,
          avatar: '',
          ownerName: '艾琳',
        ),
        MessageModel(
          ownerType: OwnerType.sender,
          content: '我们已经坐在窗边，外面雨声很密',
          createdAt: 20,
          avatar: '',
          ownerName: 'user',
        ),
      ],
    );

    expect(draft, isNotNull);
    expect(draft!.scene, '延续最近话题：我们已经坐在窗边，外面雨声很密');
    expect(draft.toneNote, '延续最近回复语气：我把伞收起来，示意你先坐下。');
  });

  test('没有历史和已有状态时不生成草稿', () {
    final draft = ConversationRoleStateSuggester.suggest(
      conversation: ConversationModel(cid: 3, icon: ''),
      messages: const [],
    );

    expect(draft, isNull);
  });
}
