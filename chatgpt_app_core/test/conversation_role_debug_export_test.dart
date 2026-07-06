import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_debug_export.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('角色调试包包含角色、消息、状态、世界书、长期记忆和完整上下文', () {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      description: '浮岛钟表师',
      providerId: 'openai',
      model: 'gpt-4o',
      toolIds: ['knowledge_search'],
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      '城市由七座浮岛组成\n[p=5] 钟声 => 钟声代表潮汐\n[off] 废稿 => 不注入',
      '钟声响了',
    );

    final text = ConversationRoleDebugExport.build(
      userMessage: '钟声响了',
      assistant: assistant,
      roleStateLines: const ['场景：雨夜旧书店', '语气：克制温柔'],
      memoryHits: hits,
      memories: [
        AssistantMemoryModel(
          assistantId: 1,
          content: '用户喜欢\n简短回答',
          source: 'manual',
        ),
        AssistantMemoryModel(
          assistantId: 1,
          content: '用户怕冷',
          source: 'user_message',
        ),
      ],
      roleContextSnapshot: '[当前命中的角色记忆]\n- 钟声代表潮汐',
    );

    expect(text, contains('# 角色调试包'));
    expect(text, contains('名称：艾琳'));
    expect(text, contains('模型覆盖：openai / gpt-4o'));
    expect(text, contains('工具：knowledge_search'));
    expect(text, contains('钟声响了'));
    expect(text, contains('场景：雨夜旧书店'));
    expect(text, contains('命中角色记忆 2 条（常驻 1 / 关键词 1）'));
    expect(text, contains('- 钟声 · p=5：钟声代表潮汐'));
    expect(text, contains('手动：用户喜欢 简短回答'));
    expect(text, contains('用户消息：用户怕冷'));
    expect(text, contains('## 本轮完整上下文'));
    expect(text, isNot(contains('不注入')));
  });

  test('角色调试包会导出世界书预算裁剪信息', () {
    final longMemory = '高优先设定${'很长' * 1600}';
    final book = [
      '[p=20] 艾琳 => $longMemory',
      '[p=5] 艾琳 => 中优先设定',
      '低优先常驻',
    ].join('\n');
    final hits = AssistantRoleCardService.matchMemoryEntries(book, '艾琳出现');
    final budget = AssistantMemoryBook.budgetContext(book, '艾琳出现');

    final text = ConversationRoleDebugExport.build(
      userMessage: '艾琳出现',
      assistant: AssistantModel(id: 1, name: '艾琳', memoryBook: book),
      memoryHits: hits,
      memoryBudget: budget,
    );

    expect(text, contains('## 世界书注入预算'));
    expect(text, contains('- 命中：3 条'));
    expect(text, contains('- 实际注入：1 条'));
    expect(text, contains('- 跳过：2 条'));
    expect(text, contains('- 截断：是'));
    expect(text, contains('- 字符预算：'));
  });

  test('会话角色调试包会按轮次导出世界书预算裁剪信息', () {
    final longMemory = '高优先设定${'很长' * 1600}';
    final book = [
      '[p=20] 艾琳 => $longMemory',
      '[p=5] 艾琳 => 中优先设定',
      '低优先常驻',
    ].join('\n');

    final text = ConversationRoleDebugExport.buildSession(
      title: '钟塔',
      turns: [
        ConversationRoleDebugTurn(
          index: 1,
          userMessage: '艾琳出现',
          memoryBudget: AssistantMemoryBook.budgetContext(book, '艾琳出现'),
        ),
      ],
    );

    expect(text, contains('## 轮次 1'));
    expect(text, contains('### 世界书注入预算'));
    expect(text, contains('- 命中：3 条'));
    expect(text, contains('- 实际注入：1 条'));
    expect(text, contains('- 跳过：2 条'));
  });

  test('会话角色调试包可导出从持久化块恢复的世界书命中条目', () {
    const restoredHits = [
      AssistantMemoryEntryPreview(
        keywords: ['钟声'],
        content: '钟声代表潮汐',
        alwaysOn: false,
        priority: 5,
      ),
    ];

    final text = ConversationRoleDebugExport.buildSession(
      title: '旧书店',
      turns: const [
        ConversationRoleDebugTurn(
          index: 1,
          userMessage: '钟声响了',
          memoryHits: restoredHits,
        ),
      ],
    );

    expect(text, contains('## 轮次 1'));
    expect(text, contains('命中角色记忆 1 条（常驻 0 / 关键词 1）'));
    expect(text, contains('- 钟声 · p=5：钟声代表潮汐'));
  });

  test('缺少角色数据时仍可导出用户消息和上下文', () {
    final text = ConversationRoleDebugExport.build(
      userMessage: '你好',
      roleContextSnapshot: '仅上下文',
    );

    expect(text, contains('## 用户消息'));
    expect(text, contains('你好'));
    expect(text, contains('仅上下文'));
    expect(text, isNot(contains('## 角色\n')));
  });

  test('会话角色调试包按轮次导出上下文、状态、世界书和长期记忆', () {
    final assistant = AssistantModel(
      id: 2,
      name: '洛瑶',
      description: '边境旅馆老板',
      providerId: 'deepseek',
      model: 'deepseek-chat',
      toolIds: ['knowledge_search', 'datetime'],
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      '旅馆 => 旅馆地下有旧港口\n[p=3] 银钥匙 => 银钥匙属于失踪船长',
      '我回到旅馆，拿出银钥匙',
    );

    final text = ConversationRoleDebugExport.buildSession(
      title: '边境旅馆',
      assistant: assistant,
      memories: [
        AssistantMemoryModel(
          assistantId: 2,
          content: '用户偏好慢节奏探索',
          source: 'manual',
        ),
      ],
      turns: [
        const ConversationRoleDebugTurn(
          index: 1,
          userMessage: '我回到旅馆',
          roleContextSnapshot: '[角色]\n洛瑶',
          roleStateLines: ['地点：边境旅馆'],
        ),
        ConversationRoleDebugTurn(
          index: 2,
          userMessage: '我回到旅馆，拿出银钥匙',
          roleContextSnapshot: '[世界书]\n银钥匙属于失踪船长',
          memoryHits: hits,
        ),
        const ConversationRoleDebugTurn(
          index: 3,
          userMessage: '',
        ),
      ],
    );

    expect(text, contains('# 会话角色调试包'));
    expect(text, contains('标题：边境旅馆'));
    expect(text, contains('名称：洛瑶'));
    expect(text, contains('模型覆盖：deepseek / deepseek-chat'));
    expect(text, contains('工具：knowledge_search, datetime'));
    expect(text, contains('手动：用户偏好慢节奏探索'));
    expect(text, contains('## 轮次 1'));
    expect(text, contains('### 当前会话状态'));
    expect(text, contains('地点：边境旅馆'));
    expect(text, contains('## 轮次 2'));
    expect(text, contains('命中角色记忆 2 条'));
    expect(text, contains('银钥匙属于失踪船长'));
    expect(text, isNot(contains('## 轮次 3')));
  });

  test('会话角色调试包没有可用数据时返回空字符串', () {
    final text = ConversationRoleDebugExport.buildSession(
      title: '',
      turns: const [
        ConversationRoleDebugTurn(index: 1, userMessage: ''),
      ],
    );

    expect(text, isEmpty);
  });
}
