import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_state_suggester.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('角色资料页展示角色卡、世界书、长期记忆和工具摘要', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      emoji: '🕯️',
      description: '浮岛钟表师',
      prompt: '保持克制而温柔',
      openingMessage: '你听见钟声了吗？',
      exampleDialogs: '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''',
      memoryBook:
          '城市由七座浮岛组成\n钟声 => 第一段设定    第二段设定会被压成一行，abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n[off] 废稿 => 不注入',
      defaultVoiceStyle: 'female',
      providerId: 'openai',
      model: 'gpt-4o',
      toolIds: ['knowledge_search'],
    );

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: assistant,
        memories: [
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户喜欢\n简短回答',
            source: 'manual',
          ),
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户正在准备浮岛旅行',
            source: 'suggestion',
          ),
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户说自己怕冷',
            source: 'user_message',
          ),
        ],
      ),
    ));

    expect(find.text('艾琳'), findsOneWidget);
    expect(find.text('浮岛钟表师'), findsOneWidget);
    expect(find.text('系统提示词'), findsOneWidget);
    expect(find.text('7 字'), findsOneWidget);
    expect(find.text('开场白内容'), findsOneWidget);
    expect(find.text('你听见钟声了吗？'), findsOneWidget);
    expect(find.text('示例对话内容'), findsOneWidget);
    expect(find.textContaining('夜色很安静'), findsOneWidget);
    expect(find.text('备选开场'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('备选开场内容'), findsOneWidget);
    expect(find.text('雨声盖住了脚步声。'), findsOneWidget);
    expect(find.text('钟塔今晚没有准点报时。'), findsOneWidget);
    expect(find.text('下一轮上下文影响'), findsOneWidget);
    expect(find.text('系统提示词 7 字会注入'), findsOneWidget);
    expect(
      find.text('常驻 1 条会注入，关键词 2 条按用户输入命中，禁用 1 条不注入'),
      findsOneWidget,
    );
    expect(find.text('最近 3 条会注入'), findsOneWidget);
    expect(find.text('复制角色卡摘要'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('3 条（常驻 1 / 关键词 2 / 禁用 1）'), 220);
    await tester.pumpAndSettle();
    expect(find.text('3 条（常驻 1 / 关键词 2 / 禁用 1）'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(find.text('世界书预览'), findsOneWidget);
    expect(find.text('常驻：城市由七座浮岛组成'), findsOneWidget);
    expect(
      find.textContaining('钟声：第一段设定 第二段设定会被压成一行'),
      findsOneWidget,
    );
    expect(find.textContaining('...'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(find.text('3 条最近记忆（手动 1 / 自动建议 1 / 对话 1）'), findsOneWidget);
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.textContaining('用户喜欢 简短回答'), findsOneWidget);
    expect(find.text('来自自动建议'), findsOneWidget);
    expect(find.textContaining('用户正在准备浮岛旅行'), findsOneWidget);
    expect(find.text('来自用户消息'), findsOneWidget);
    expect(find.textContaining('用户说自己怕冷'), findsOneWidget);
    expect(find.text('knowledge_search'), findsOneWidget);
    expect(find.byTooltip('编辑角色'), findsOneWidget);
  });

  testWidgets('角色资料页可编辑当前会话状态', (tester) async {
    final assistant = AssistantModel(id: 1, name: '艾琳');
    final conversation = ConversationModel(
      cid: 100,
      icon: '',
      roleScene: '旧场景',
    );
    ({String? scene, String? relationship, String? toneNote})? saved;

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: assistant,
        conversation: conversation,
        suggestedRoleState: const ConversationRoleStateDraft(
          scene: '雨夜旧书店',
          relationship: '熟悉但保持距离',
          toneNote: '克制温柔',
        ),
        onSaveRoleState: ({
          String? roleScene,
          String? roleRelationship,
          String? roleToneNote,
        }) async {
          saved = (
            scene: roleScene,
            relationship: roleRelationship,
            toneNote: roleToneNote
          );
        },
      ),
    ));

    expect(find.text('当前会话状态'), findsOneWidget);
    expect(find.text('旧场景'), findsWidgets);
    expect(find.text('会注入当前会话状态'), findsOneWidget);

    await tester.tap(find.text('当前会话状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从最近对话填入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved?.scene, '雨夜旧书店');
    expect(saved?.relationship, '熟悉但保持距离');
    expect(saved?.toneNote, '克制温柔');
    expect(find.text('雨夜旧书店 / 熟悉但保持距离 / 克制温柔'), findsOneWidget);
  });

  testWidgets('角色资料页可复制当前会话状态摘要', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(id: 1, name: '艾琳'),
        conversation: ConversationModel(
          cid: 100,
          icon: '',
          roleScene: '雨夜旧书店',
          roleRelationship: '熟悉但保持距离',
          roleToneNote: '克制温柔',
        ),
      ),
    ));

    expect(find.text('当前会话状态摘要'), findsOneWidget);
    await tester.tap(find.text('复制会话状态摘要'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('# 艾琳 · 当前会话状态'));
    expect(copied.single, contains('场景：雨夜旧书店'));
    expect(copied.single, contains('关系：熟悉但保持距离'));
    expect(copied.single, contains('语气：克制温柔'));
    expect(find.text('会话状态摘要已复制'), findsOneWidget);
  });

  testWidgets('角色资料页可显示并触发开始对话动作', (tester) async {
    var started = false;

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(id: 1, name: '艾琳'),
        onStartConversation: () {
          started = true;
        },
      ),
    ));

    expect(find.text('开始对话'), findsOneWidget);

    await tester.tap(find.text('开始对话'));
    await tester.pumpAndSettle();

    expect(started, isTrue);
  });

  testWidgets('角色资料页可保存为会话模板', (tester) async {
    final saved = <WorkflowTemplate>[];

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(
          id: 1,
          name: '艾琳',
          prompt: '保持克制而温柔',
          openingMessage: '你听见钟声了吗？',
          exampleDialogs: '''
[备选开场白]
雨声盖住了脚步声。
钟塔今晚没有准点报时。
''',
          providerId: 'openai',
          model: 'gpt-4o',
          toolIds: ['knowledge_search'],
        ),
        saveWorkflowTemplate: (template) async => saved.add(template),
      ),
    ));

    await tester.tap(find.text('保存为会话模板'));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    final template = saved.single;
    expect(template.title, '艾琳 · 角色场景');
    expect(template.category, '角色场景');
    expect(template.projectName, '艾琳 角色场景');
    expect(template.assistantName, '艾琳');
    expect(template.providerCode, 'openai');
    expect(template.modelId, 'gpt-4o');
    expect(template.toolIds, ['knowledge_search']);
    expect(template.systemPrompt, '保持克制而温柔');
    expect(template.firstUserPrompt, contains('你听见钟声了吗？'));
    expect(template.firstUserPrompt, contains('可选备选开场白：'));
    expect(template.firstUserPrompt, contains('- 雨声盖住了脚步声。'));
    expect(template.firstUserPrompt, contains('- 钟塔今晚没有准点报时。'));
    expect(find.text('已保存到会话模板'), findsOneWidget);
  });

  testWidgets('角色资料页从编辑页返回后刷新角色资料', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      description: '旧简介',
      openingMessage: '旧开场白',
    );

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: assistant,
        openEditor: (context, assistant) async {
          assistant
            ..description = '新简介'
            ..openingMessage = '新开场白';
          return true;
        },
      ),
    ));

    expect(find.text('旧简介'), findsOneWidget);
    expect(find.text('旧开场白'), findsOneWidget);

    await tester.tap(find.byTooltip('编辑角色'));
    await tester.pumpAndSettle();

    expect(find.text('新简介'), findsOneWidget);
    expect(find.text('新开场白'), findsOneWidget);
    expect(find.text('旧简介'), findsNothing);
    expect(find.text('旧开场白'), findsNothing);
  });

  testWidgets('角色资料页可复制角色卡摘要', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(
          id: 1,
          name: '艾琳',
          description: '浮岛钟表师',
          prompt: '保持克制而温柔',
          openingMessage: '你听见钟声了吗？',
          exampleDialogs: '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''',
          memoryBook: '城市由七座浮岛组成\n[p=5] 钟声 => 钟声    代表潮汐\n[off] 废稿 => 不注入',
          defaultVoiceStyle: 'female',
          providerId: 'openai',
          model: 'gpt-4o',
          toolIds: ['knowledge_search'],
        ),
      ),
    ));

    await tester.tap(find.text('复制角色卡摘要'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('# 艾琳'));
    expect(copied.single, contains('浮岛钟表师'));
    expect(copied.single, contains('[系统提示词]'));
    expect(copied.single, contains('你听见钟声了吗？'));
    expect(copied.single, contains('[示例对话]\n用户：你好\n助手：夜色很安静。'));
    expect(copied.single, contains('夜色很安静'));
    expect(copied.single, contains('[备选开场白]'));
    expect(copied.single, contains('雨声盖住了脚步声。'));
    expect(copied.single, contains('钟塔今晚没有准点报时。'));
    expect(copied.single, contains('城市由七座浮岛组成'));
    expect(copied.single, contains('- 钟声 · p=5：钟声 代表潮汐'));
    expect(copied.single, contains('- 废稿 · 已禁用：不注入'));
    expect(copied.single, contains('默认语音：female'));
    expect(copied.single, contains('模型覆盖：openai / gpt-4o'));
    expect(copied.single, contains('工具：knowledge_search'));
    expect(find.text('角色卡摘要已复制'), findsOneWidget);
  });

  testWidgets('角色资料页可复制世界书摘要', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(
          id: 1,
          name: '艾琳',
          memoryBook: '城市由七座浮岛组成\n[p=5] 钟声 => 钟声    代表潮汐\n[off] 废稿 => 不注入',
        ),
      ),
    ));

    await tester.scrollUntilVisible(find.text('复制世界书摘要'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制世界书摘要'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('# 艾琳 · 世界书'));
    expect(copied.single, contains('3 条（常驻 1 / 关键词 2 / 禁用 1）'));
    expect(copied.single, contains('- 常驻：城市由七座浮岛组成'));
    expect(copied.single, contains('- 钟声 · p=5：钟声 代表潮汐'));
    expect(copied.single, contains('- 废稿 · 已禁用：不注入'));
    expect(find.text('世界书摘要已复制'), findsOneWidget);
  });

  testWidgets('角色资料页可复制长期记忆摘要', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(id: 1, name: '艾琳'),
        memories: [
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户喜欢\n简短回答',
            source: 'manual',
          ),
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户正在准备浮岛旅行',
            source: 'suggestion',
          ),
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户说自己怕冷',
            source: 'user_message',
          ),
        ],
      ),
    ));

    await tester.scrollUntilVisible(find.text('复制长期记忆摘要'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制长期记忆摘要'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('# 艾琳 · 最近长期记忆'));
    expect(copied.single, contains('3 条最近记忆（手动 1 / 自动建议 1 / 对话 1）'));
    expect(copied.single, contains('- 手动添加：用户喜欢 简短回答'));
    expect(copied.single, contains('- 来自自动建议：用户正在准备浮岛旅行'));
    expect(copied.single, contains('- 来自用户消息：用户说自己怕冷'));
    expect(find.text('长期记忆摘要已复制'), findsOneWidget);
  });

  testWidgets('角色资料页可复制下一轮上下文影响摘要', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(
          id: 1,
          name: '艾琳',
          prompt: '保持克制而温柔',
          memoryBook: '城市由七座浮岛组成\n钟声 => 钟声代表潮汐\n[off] 废稿 => 不注入',
        ),
        conversation: ConversationModel(
          cid: 100,
          icon: '',
          roleScene: '雨夜旧书店',
        ),
        memories: [
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户喜欢简短回答',
          ),
        ],
      ),
    ));

    await tester.scrollUntilVisible(find.text('复制影响摘要'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制影响摘要'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('# 艾琳 · 下一轮上下文影响'));
    expect(copied.single, contains('角色卡：系统提示词 7 字会注入'));
    expect(
      copied.single,
      contains('世界书：常驻 1 条会注入，关键词 2 条按用户输入命中，禁用 1 条不注入'),
    );
    expect(copied.single, contains('会话状态：会注入当前会话状态'));
    expect(copied.single, contains('长期记忆：最近 1 条会注入'));
    expect(find.text('上下文影响摘要已复制'), findsOneWidget);
  });

  testWidgets('角色资料页从长期记忆页返回后刷新最近记忆', (tester) async {
    final dao = _FakeAssistantMemoryDao();

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(id: 1, name: '艾琳'),
        memoryDao: dao,
      ),
    ));

    expect(find.text('未保存'), findsOneWidget);

    await tester.scrollUntilVisible(find.widgetWithText(ListTile, '长期记忆'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '长期记忆'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '记忆内容'), '用户喜欢热茶');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('1 条最近记忆（手动 1）'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.textContaining('用户喜欢热茶'), findsOneWidget);
  });

  testWidgets('角色资料页从世界书页返回后刷新世界书预览', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '钟声 => 旧潮汐设定',
    );
    final saved = <String>[];

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: assistant,
        worldBookSaver: (next) async => saved.add(next.memoryBook),
      ),
    ));

    await tester.scrollUntilVisible(find.widgetWithText(ListTile, '世界书'), 220);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '世界书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '触发关键词'), '风铃');
    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '新潮汐设定');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(saved, ['钟声 => 旧潮汐设定\n风铃 => 新潮汐设定']);
    expect(assistant.memoryBook, '钟声 => 旧潮汐设定\n风铃 => 新潮汐设定');
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('风铃：新潮汐设定'), findsOneWidget);
    expect(find.text('钟声：旧潮汐设定'), findsOneWidget);
  });

  testWidgets('角色资料页可预览最终注入上下文并模拟世界书命中', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      prompt: '保持克制而温柔',
      memoryBook: '城市由七座浮岛组成\n钟声 => 钟声代表潮汐',
    );
    final conversation = ConversationModel(
      cid: 101,
      icon: '',
      roleScene: '雨夜旧书店',
      roleRelationship: '熟悉但保持距离',
      roleToneNote: '克制温柔',
    );

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: assistant,
        conversation: conversation,
        memories: [
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户喜欢简短回答',
          ),
        ],
      ),
    ));

    await tester.tap(find.text('上下文预览'));
    await tester.pumpAndSettle();

    expect(find.textContaining('保持克制而温柔'), findsOneWidget);
    expect(find.textContaining('[当前会话角色状态]'), findsOneWidget);
    expect(find.textContaining('当前场景：雨夜旧书店'), findsOneWidget);
    expect(find.textContaining('[长期记忆]'), findsOneWidget);
    expect(find.textContaining('用户喜欢简短回答'), findsOneWidget);
    expect(
      find.textContaining('当前输入会注入世界书 1 条（常驻 1 / 关键词 0）'),
      findsOneWidget,
    );
    expect(find.textContaining('命中：常驻：城市由七座浮岛组成'), findsOneWidget);
    expect(_contextPreviewText(tester), isNot(contains('钟声代表潮汐')));

    await tester.enterText(find.byType(TextField), '钟声响了');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('当前输入会注入世界书 2 条（常驻 1 / 关键词 1）'),
      findsOneWidget,
    );
    expect(find.textContaining('钟声：钟声代表潮汐'), findsOneWidget);
    expect(find.textContaining('[当前命中的角色记忆]'), findsOneWidget);
    expect(_contextPreviewText(tester), contains('钟声代表潮汐'));
  });

  testWidgets('角色资料页上下文预览可复制当前完整上下文', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(
          id: 1,
          name: '艾琳',
          prompt: '保持克制而温柔',
          memoryBook: '钟声 => 钟声代表潮汐',
        ),
        memories: [
          AssistantMemoryModel(
            assistantId: 1,
            content: '用户喜欢简短回答',
          ),
        ],
      ),
    ));

    await tester.tap(find.text('上下文预览'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '钟声响了');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复制上下文'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('保持克制而温柔'));
    expect(copied.single, contains('钟声代表潮汐'));
    expect(copied.single, contains('[长期记忆]'));
    expect(copied.single, contains('用户喜欢简短回答'));
    expect(find.text('上下文已复制'), findsOneWidget);
  });

  testWidgets('角色资料页上下文预览可复制命中的世界书', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: AssistantProfilePage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: AssistantModel(
          id: 1,
          name: '艾琳',
          memoryBook:
              '城市由七座浮岛组成\n[p=5] 钟声 => 钟声代表潮汐\n风铃 => 风铃只在黄昏响起\n[off] 废稿 => 不注入',
        ),
      ),
    ));

    await tester.tap(find.text('上下文预览'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '钟声响了');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复制命中世界书'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('# 艾琳 · 命中世界书'));
    expect(copied.single, contains('当前输入会注入世界书 2 条（常驻 1 / 关键词 1）'));
    expect(copied.single, contains('- 常驻：城市由七座浮岛组成'));
    expect(copied.single, contains('- 钟声 · p=5：钟声代表潮汐'));
    expect(copied.single, isNot(contains('风铃只在黄昏响起')));
    expect(copied.single, isNot(contains('不注入')));
    expect(find.text('命中世界书已复制'), findsOneWidget);
  });
}

String _contextPreviewText(WidgetTester tester) {
  return tester.widget<SelectableText>(find.byType(SelectableText)).data ?? '';
}

class _FakeAssistantMemoryDao implements IAssistantMemory {
  final List<AssistantMemoryModel> _items = [];
  int _nextId = 1;

  @override
  Future<int> deleteMemory(int id) async {
    final before = _items.length;
    _items.removeWhere((item) => item.id == id);
    return before - _items.length;
  }

  @override
  Future<List<AssistantMemoryModel>> getMemories(int assistantId,
      {int limit = 20}) async {
    return _items
        .where((item) => item.assistantId == assistantId)
        .take(limit)
        .map((item) => AssistantMemoryModel.fromJson(item.toJson()))
        .toList();
  }

  @override
  Future<int?> saveMemory(AssistantMemoryModel model) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    model
      ..id ??= _nextId++
      ..createdAt = model.createdAt == 0 ? now : model.createdAt
      ..updatedAt = now;
    final index = _items.indexWhere((item) => item.id == model.id);
    final copy = AssistantMemoryModel.fromJson(model.toJson());
    if (index >= 0) {
      _items[index] = copy;
    } else {
      _items.insert(0, copy);
    }
    return model.id;
  }
}
