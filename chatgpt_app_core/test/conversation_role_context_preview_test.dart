import 'package:chatgpt_app_core/chat/application/conversation_role_context_preview.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('安全上下文预览和摘要保留正则世界书命中', () async {
    final assistant = AssistantModel(
      name: '艾琳',
      prompt: '保持克制',
      memoryBook: r'[re] 第[一二三]幕 => 银钥匙可以打开钟塔暗门',
    );
    final preview = await ConversationRoleContextPreview.buildSafely(
      assistant: assistant,
      userInput: '进入第二幕',
    );
    final summary = await ConversationRoleContextPreview.summarySafely(
      assistant: assistant,
      userInput: '进入第二幕',
    );
    expect(preview, contains('银钥匙可以打开钟塔暗门'));
    expect(summary, contains('世界书：本轮命中 1 条'));
    expect(summary, contains('银钥匙可以打开钟塔暗门'));
    expect(
      await ConversationRoleContextPreview.summarySafely(
        assistant: assistant,
        userInput: '普通闲聊',
      ),
      contains('世界书：本轮未命中'),
    );
  });

  test('世界书扫描文本包含最近消息和当前输入，并限制历史条数', () {
    final scanText = ConversationRoleContextPreview.scanText(
      userInput: '打开门',
      recentMessages: [
        '  ',
        '第一条',
        '第二条',
        '第三条',
        '第四条',
      ],
      maxMessages: 2,
    );

    expect(scanText, '第三条\n第四条\n打开门');
  });

  test('下一轮角色上下文可用最近消息触发世界书', () {
    final scanText = ConversationRoleContextPreview.scanText(
      userInput: '打开门',
      recentMessages: ['用户拿起银钥匙。'],
    );

    final preview = ConversationRoleContextPreview.build(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        prompt: '保持克制而温柔',
        memoryBook: '银钥匙 => 银钥匙可以打开钟塔暗门',
      ),
      userInput: scanText,
    );
    final summary = ConversationRoleContextPreview.summary(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        prompt: '保持克制而温柔',
        memoryBook: '银钥匙 => 银钥匙可以打开钟塔暗门',
      ),
      userInput: scanText,
    );

    expect(preview, contains('银钥匙可以打开钟塔暗门'));
    expect(summary, contains('世界书：本轮命中 1 条'));
  });

  test('下一轮角色上下文摘要会提示世界书预算裁剪', () {
    final longMemory = '高优先设定${'很长' * 1600}';
    final summary = ConversationRoleContextPreview.summary(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        prompt: '保持克制而温柔',
        memoryBook: [
          '[p=20] 艾琳 => $longMemory',
          '[p=5] 艾琳 => 中优先设定',
          '低优先常驻',
        ].join('\n'),
      ),
      userInput: '艾琳出现',
    );

    expect(summary, contains('世界书：本轮命中 3 条'));
    expect(summary, contains('世界书预算：注入 1/3 条'));
    expect(summary, contains('有截断'));
    expect(summary, contains('跳过 2 条'));
  });

  test('组装下一轮角色上下文包含角色卡、命中世界书、会话状态和长期记忆', () {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      prompt: '保持克制而温柔',
      memoryBook: '城市由七座浮岛组成\n钟声 => 钟声代表潮汐\n[off] 废稿 => 不注入',
    );
    final conversation = ConversationModel(
      cid: 100,
      icon: '',
      roleScene: '雨夜旧书店',
      roleRelationship: '熟悉但保持距离',
      roleToneNote: '克制温柔',
    );
    final memories = [
      AssistantMemoryModel(
        assistantId: 1,
        content: '用户喜欢简短回答',
      ),
    ];

    final preview = ConversationRoleContextPreview.build(
      assistant: assistant,
      userInput: '钟声响了',
      conversation: conversation,
      memories: memories,
    );

    expect(preview, contains('保持克制而温柔'));
    expect(preview, contains('[当前命中的角色记忆]'));
    expect(preview, contains('城市由七座浮岛组成'));
    expect(preview, contains('钟声代表潮汐'));
    expect(preview, isNot(contains('不注入')));
    expect(preview, contains('[当前会话角色状态]'));
    expect(preview, contains('当前场景：雨夜旧书店'));
    expect(preview, contains('[长期记忆]'));
    expect(preview, contains('用户喜欢简短回答'));
  });

  test('摘要说明当前上下文来源状态', () {
    final summary = ConversationRoleContextPreview.summary(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        prompt: '保持克制而温柔',
        memoryBook: '钟声 => 钟声代表潮汐',
      ),
      conversation: ConversationModel(
        cid: 100,
        icon: '',
        roleScene: '雨夜旧书店',
      ),
      memories: [
        AssistantMemoryModel(assistantId: 1, content: '用户喜欢简短回答'),
        AssistantMemoryModel(assistantId: 1, content: '用户怕冷'),
      ],
    );

    expect(summary, contains('角色卡：会注入系统提示词'));
    expect(summary, contains('世界书：会按输入命中注入'));
    expect(summary, contains('会话状态：会注入'));
    expect(summary, contains('长期记忆：最近 2 条会注入'));
  });

  test('摘要可按模拟输入展示本轮命中的世界书条目', () {
    final summary = ConversationRoleContextPreview.summary(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        prompt: '保持克制而温柔',
        memoryBook: '城市由七座浮岛组成\n[p=5] 钟声 => 钟声代表潮汐\n[off] 废稿 => 不注入',
      ),
      userInput: '钟声响了',
    );

    expect(summary, contains('世界书：本轮命中 2 条'));
    expect(summary, contains('钟声 · p=5：钟声代表潮汐'));
    expect(summary, contains('常驻：城市由七座浮岛组成'));
    expect(summary, isNot(contains('不注入')));
  });

  test('摘要在模拟输入没有命中关键词时明确提示本轮未命中', () {
    final summary = ConversationRoleContextPreview.summary(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        memoryBook: '钟声 => 钟声代表潮汐',
      ),
      userInput: '今晚下雨',
    );

    expect(summary, contains('世界书：本轮未命中'));
  });

  test('下一轮角色上下文不会把备选开场白当作示例对话注入', () {
    final preview = ConversationRoleContextPreview.build(
      assistant: AssistantModel(
        id: 1,
        name: '艾琳',
        prompt: '保持克制而温柔',
        exampleDialogs: [
          '用户：你好',
          '助手：夜色很安静。',
          '',
          '[备选开场白]',
          '雨声盖住了脚步声。',
          '',
          '钟塔今晚没有准点报时。',
        ].join('\n'),
      ),
      userInput: '你好',
    );

    expect(preview, contains('[示例对话]'));
    expect(preview, contains('用户：你好'));
    expect(preview, contains('助手：夜色很安静。'));
    expect(preview, isNot(contains('[备选开场白]')));
    expect(preview, isNot(contains('雨声盖住了脚步声。')));
    expect(preview, isNot(contains('钟塔今晚没有准点报时。')));
  });

  test('未绑定角色时不生成下一轮上下文', () {
    final preview = ConversationRoleContextPreview.build(
      assistant: null,
      userInput: '钟声响了',
      conversation: ConversationModel(cid: 100, icon: ''),
      memories: [
        AssistantMemoryModel(assistantId: 1, content: '用户喜欢简短回答'),
      ],
    );

    expect(preview, isEmpty);
    expect(
      ConversationRoleContextPreview.summary(assistant: null),
      '当前会话未绑定角色',
    );
  });
}
