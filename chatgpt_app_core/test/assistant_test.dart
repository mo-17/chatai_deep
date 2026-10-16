import 'package:chatgpt_app_core/chat/application/assistant_conversation_factory.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 阶段七（助手系统）验收测试：
/// 1) AssistantModel JSON 往返；2) AssistantDao CRUD（真实 DAO + 内存库）；
/// 3) tb_conversation_list 旧表升级（assistantId 列 ALTER）；
/// 4) system prompt 注入；5) 模型覆盖与能力位联动。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('AssistantModel', () {
    test('toJson/fromJson 往返保持字段（useTools 以 0/1 存储）', () {
      final original = AssistantModel(
        id: 7,
        name: '翻译官',
        emoji: '🌐',
        avatarType: 'image',
        avatarValue: '/tmp/assistant.png',
        prompt: '你是专业翻译',
        description: '专业翻译角色',
        openingMessage: '把要翻译的内容发给我。',
        exampleDialogs: '用户：hello\n助手：你好',
        memoryBook: '术语 => 一律把 Flutter 翻译为 Flutter，不翻成颤振',
        worldBookJson: '{"entries":[]}',
        defaultVoiceStyle: 'female',
        providerId: 'openai',
        model: 'gpt-4o',
        useTools: false,
        createdAt: 100,
        updatedAt: 200,
      );
      final json = original.toJson();
      expect(json['useTools'], 0);
      final restored = AssistantModel.fromJson(json);
      expect(restored.id, 7);
      expect(restored.name, '翻译官');
      expect(restored.emoji, '🌐');
      expect(restored.avatarType, 'image');
      expect(restored.avatarValue, '/tmp/assistant.png');
      expect(restored.prompt, '你是专业翻译');
      expect(restored.description, '专业翻译角色');
      expect(restored.openingMessage, '把要翻译的内容发给我。');
      expect(restored.exampleDialogs, '用户：hello\n助手：你好');
      expect(restored.memoryBook, '术语 => 一律把 Flutter 翻译为 Flutter，不翻成颤振');
      expect(restored.worldBookJson, '{"entries":[]}');
      expect(restored.defaultVoiceStyle, 'female');
      expect(restored.providerId, 'openai');
      expect(restored.model, 'gpt-4o');
      expect(restored.useTools, isFalse);
      expect(restored.createdAt, 100);
      expect(restored.updatedAt, 200);
    });

    test('fromJson 缺省字段兜底（useTools 默认开）', () {
      final a = AssistantModel.fromJson({'name': 'x'});
      expect(a.useTools, isTrue);
      expect(a.emoji, '🤖');
      expect(a.providerId, isEmpty);
      expect(a.model, '');
      expect(a.prompt, '');
      expect(a.description, '');
      expect(a.openingMessage, '');
      expect(a.exampleDialogs, '');
      expect(a.memoryBook, '');
      expect(a.worldBookJson, '');
      expect(a.defaultVoiceStyle, '');
    });

    test('关键词记忆只注入当前轮命中的设定，未写箭头的行常驻', () {
      final book = [
        '世界观底色：城市由七座浮岛组成',
        '艾琳,女主 => 艾琳是主角，害怕海雾但擅长修钟',
        '反派 => 反派只能通过镜子和人交流',
        '艾琳 => 艾琳是主角，害怕海雾但擅长修钟',
        '# 注释',
      ].join('\n');

      final matched = AssistantMemoryBook.match(book, '艾琳今天要出场');
      expect(matched, [
        '世界观底色：城市由七座浮岛组成',
        '艾琳是主角，害怕海雾但擅长修钟',
      ]);

      final context = AssistantMemoryBook.buildContext(book, '反派出现了');
      expect(context, contains('[当前命中的角色记忆]'));
      expect(context, contains('城市由七座浮岛组成'));
      expect(context, contains('反派只能通过镜子和人交流'));
      expect(context, isNot(contains('艾琳是主角')));
    });

    test('systemPromptFor 合并基础人设与命中的关键词记忆', () {
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        memoryBook: '艾琳 => 艾琳说话克制，不主动透露秘密',
      );
      final prompt = a.systemPromptFor('艾琳怎么回答？');
      expect(prompt, startsWith('你是严谨的小说助手'));
      expect(prompt, contains('[当前命中的角色记忆]'));
      expect(prompt, contains('艾琳说话克制，不主动透露秘密'));

      expect(a.systemPromptFor('其他角色'), '你是严谨的小说助手');
    });

    test('systemPromptForSafely 支持正则世界书触发', () async {
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        memoryBook: r'[re] 第[一二三]幕 || Act\s+\d+ => 按幕次切换叙事节奏',
      );

      final prompt = await a.systemPromptForSafely('现在进入第二幕。');

      expect(prompt, startsWith('你是严谨的小说助手'));
      expect(prompt, contains('[当前命中的角色记忆]'));
      expect(prompt, contains('按幕次切换叙事节奏'));
      expect(await a.systemPromptForSafely('普通闲聊'), '你是严谨的小说助手');
    });

    test('systemPromptFor 支持 selective 二级关键词触发', () {
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        memoryBook: '[sec=潮汐|浮岛] 钟声 => 钟声和潮汐同场时才注入',
      );

      expect(a.systemPromptFor('钟声响了'), '你是严谨的小说助手');
      final prompt = a.systemPromptFor('钟声响起，潮汐也开始变化。');

      expect(prompt, contains('[当前命中的角色记忆]'));
      expect(prompt, contains('钟声和潮汐同场时才注入'));
    });

    test('systemPromptFor 支持大小写敏感和整词世界书触发', () {
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        memoryBook: '[cs] [ww] Alice => 只在精确提到 Alice 时注入',
      );

      expect(a.systemPromptFor('alice 来了'), '你是严谨的小说助手');
      expect(a.systemPromptFor('Alicehood'), '你是严谨的小说助手');
      final prompt = a.systemPromptFor('Alice 来了');

      expect(prompt, contains('[当前命中的角色记忆]'));
      expect(prompt, contains('只在精确提到 Alice 时注入'));
    });

    test('systemPromptFor 会把示例对话作为角色卡上下文注入', () {
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        exampleDialogs: '用户：你好\n助手：夜色很安静。',
      );

      final prompt = a.systemPromptFor('你好');

      expect(prompt, startsWith('你是严谨的小说助手'));
      expect(prompt, contains('[示例对话]'));
      expect(prompt, contains('用户：你好'));
      expect(prompt, contains('助手：夜色很安静。'));
    });

    test('systemPromptFor 不把备选开场白当成示例对话注入', () {
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        exampleDialogs: [
          '用户：你好',
          '助手：夜色很安静。',
          '',
          '[备选开场白]',
          '雨声盖住了脚步声。',
          '',
          '钟塔今晚没有准点报时。',
        ].join('\n'),
      );

      final prompt = a.systemPromptFor('你好');

      expect(prompt, contains('[示例对话]'));
      expect(prompt, contains('用户：你好'));
      expect(prompt, contains('助手：夜色很安静。'));
      expect(prompt, isNot(contains('[备选开场白]')));
      expect(prompt, isNot(contains('雨声盖住了脚步声。')));
      expect(prompt, isNot(contains('钟塔今晚没有准点报时。')));
    });

    test('systemPromptFor 和角色卡服务共用示例对话过滤口径', () {
      final examples = [
        '用户：你好',
        '助手：夜色很安静。',
        '',
        '[alternate_greetings]',
        '雨声盖住了脚步声。',
        '',
        '钟塔今晚没有准点报时。',
      ].join('\n');
      final a = AssistantModel(
        name: '小说角色',
        prompt: '你是严谨的小说助手',
        exampleDialogs: examples,
      );

      final prompt = a.systemPromptFor('你好');

      expect(
        AssistantRoleCardService.exampleDialogPromptText(examples),
        '用户：你好\n助手：夜色很安静。',
      );
      expect(AssistantRoleCardService.alternateGreetings(examples), [
        '雨声盖住了脚步声。',
        '钟塔今晚没有准点报时。',
      ]);
      expect(prompt, contains('[示例对话]\n用户：你好\n助手：夜色很安静。'));
      expect(prompt, isNot(contains('alternate_greetings')));
      expect(prompt, isNot(contains('雨声盖住了脚步声。')));
    });

    test('世界书支持禁用条目和优先级排序', () {
      final book = [
        '低优先常驻',
        '[p=20] 艾琳 => 高优先艾琳设定',
        '[off] 艾琳 => 禁用设定不应注入',
        '[p=5] 艾琳 => 中优先艾琳设定',
      ].join('\n');

      expect(AssistantMemoryBook.match(book, '艾琳出现'), [
        '高优先艾琳设定',
        '中优先艾琳设定',
        '低优先常驻',
      ]);
    });

    test('世界书 system context 会按字符预算裁剪长内容', () {
      final longHighPriority = '高优先设定${'很长' * 80}';
      final book = [
        '[p=20] 艾琳 => $longHighPriority',
        '[p=5] 艾琳 => 中优先设定',
        '低优先常驻',
      ].join('\n');

      final context = AssistantMemoryBook.buildContext(
        book,
        '艾琳出现',
        maxContextChars: 80,
      );

      expect(context.length, lessThanOrEqualTo(80));
      expect(context, contains('[当前命中的角色记忆]'));
      expect(context, contains('- 高优先设定'));
      expect(context, contains('...'));
      expect(context, isNot(contains('中优先设定')));
      expect(context, isNot(contains('低优先常驻')));
    });

    test('世界书预算结果会报告注入、截断和跳过数量', () {
      final longHighPriority = '高优先设定${'很长' * 80}';
      final book = [
        '[p=20] 艾琳 => $longHighPriority',
        '[p=5] 艾琳 => 中优先设定',
        '低优先常驻',
      ].join('\n');

      final budget = AssistantMemoryBook.budgetContext(
        book,
        '艾琳出现',
        maxContextChars: 80,
      );

      expect(budget.context.length, lessThanOrEqualTo(80));
      expect(budget.matchedCount, 3);
      expect(budget.includedCount, 1);
      expect(budget.skippedCount, 2);
      expect(budget.truncated, isTrue);
      expect(budget.affected, isTrue);
      expect(budget.usedChars, budget.context.length);
      expect(budget.compactSummary, '注入 1/3 条，有截断，跳过 2 条');
    });
  });

  group('AssistantModel.applyTo（模型覆盖）', () {
    test('本地模式：覆盖当前服务商的 model，effectiveModel 随之变化', () {
      final s = AISettings.defaults(); // local + deepseek-chat
      final a = AssistantModel(name: 'a', model: 'deepseek-reasoner');
      final next = a.applyTo(s);
      expect(next.effectiveModel, 'deepseek-reasoner');
      // 原设置不被改动（clone 语义）
      expect(s.effectiveModel, 'deepseek-chat');
    });

    test('本地模式：覆盖服务商后再覆盖 model', () {
      final s = AISettings.defaults();
      final providerId = s.providers.first.id;
      final modelId = s.providers.first.models.isNotEmpty
          ? s.providers.first.models.first.id
          : 'gpt-3.5-turbo';
      final a = AssistantModel(
        name: 'a',
        providerId: providerId,
        model: modelId,
      );
      final next = a.applyTo(s);
      expect(next.activeProviderId, providerId);
      expect(next.effectiveModel, modelId);
    });

    test('本地模式：仅覆盖服务商时使用目标服务商当前模型', () {
      final s = AISettings.defaults();
      final target = s.providers.firstWhere((p) => p.id == 'openai');
      target.enabled = true;
      target.selectedModelId = 'gpt-4o';
      s.activeProviderId = 'deepseek';

      final a = AssistantModel(name: 'a', providerId: 'openai');
      final next = a.applyTo(s);

      expect(next.activeProviderId, 'openai');
      expect(next.effectiveModel, 'gpt-4o');
      expect(s.activeProviderId, 'deepseek');
    });

    test('本地模式：不存在的 providerId 保留原始覆盖供校验拒绝', () {
      final s = AISettings.defaults();
      s.activeProviderId = s.providers.last.id;
      final before = s.activeProviderId;
      final a = AssistantModel(name: 'a', providerId: 'ghost', model: 'x-gpt');
      final next = a.applyTo(s);
      expect(next.activeProviderId, 'ghost');
      expect(next.effectiveModel, isEmpty);
      expect(next.localSelectionValid, isFalse);
      expect(s.activeProviderId, before);
    });

    test('后端模式：覆盖 backendModel', () {
      final s = AISettings.defaults()..mode = AIMode.backend;
      final a = AssistantModel(name: 'a', model: 'gpt-4o');
      expect(a.applyTo(s).effectiveModel, 'gpt-4o');
      expect(s.backendModel, 'deepseek-chat');
    });

    test('无覆盖时返回同一实例，空白模型保留供校验拒绝', () {
      final s = AISettings.defaults();
      expect(identical(AssistantModel(name: 'a').applyTo(s), s), isTrue);
      final invalid = AssistantModel(name: 'a', model: '  ').applyTo(s);
      expect(identical(invalid, s), isFalse);
      expect(invalid.effectiveModel, '  ');
    });

    test('能力位联动：覆盖为 gpt-4o 后 capabilitiesFor 算出 vision', () {
      final s = AISettings.defaults()..activeProviderId = 'openai';
      s.setActiveModel('gpt-3.5-turbo');
      final base = ChatService.capabilitiesFor(s);
      expect(base.image, isFalse);
      final a = AssistantModel(name: 'a', model: 'gpt-4o');
      final overridden = ChatService.capabilitiesFor(a.applyTo(s));
      expect(overridden.image, isTrue);
      expect(overridden.tool, isTrue);
    });
  });

  group('AssistantConversationFactory', () {
    test('从助手创建新会话时绑定助手、默认音色和开场白', () {
      final assistant = AssistantModel(
        id: 42,
        name: '艾琳',
        openingMessage: '钟楼已经响了。',
        avatarType: 'image',
        avatarValue: '/tmp/ailin.png',
        defaultVoiceStyle: ' female ',
      );

      final conversation = AssistantConversationFactory.create(
        cid: 123,
        icon: 'avatar.png',
        assistant: assistant,
        projectId: 9,
        modelProviderId: 'openai',
        modelId: 'gpt-4o',
        webSearchEnabled: true,
        toolIds: const ['knowledge_search'],
      );

      expect(conversation.cid, 123);
      expect(conversation.icon, 'avatar.png');
      expect(conversation.assistantId, 42);
      expect(conversation.avatarType, 'image');
      expect(conversation.avatarValue, '/tmp/ailin.png');
      expect(conversation.projectId, 9);
      expect(conversation.modelProviderId, 'openai');
      expect(conversation.modelId, 'gpt-4o');
      expect(conversation.voiceStyle, 'female');
      expect(conversation.webSearchEnabled, isTrue);
      expect(conversation.toolIds, const ['knowledge_search']);
      expect(
        AssistantConversationFactory.openingMessageOf(assistant),
        '钟楼已经响了。',
      );
    });

    test('空默认音色不写入会话，未选助手时无开场白', () {
      final assistant = AssistantModel(
        id: 43,
        name: '空音色',
        emoji: '🕯️',
        defaultVoiceStyle: '   ',
      );

      final conversation = AssistantConversationFactory.create(
        cid: 124,
        icon: '',
        assistant: assistant,
      );

      expect(conversation.assistantId, 43);
      expect(conversation.avatarType, 'emoji');
      expect(conversation.avatarValue, '🕯️');
      expect(conversation.voiceStyle, isNull);
      expect(AssistantConversationFactory.openingMessageOf(null), isEmpty);
    });

    test('开场白候选包含主开场和 Tavern 备选开场', () {
      final assistant = AssistantModel(
        id: 44,
        name: '艾琳',
        openingMessage: '你听见钟声了吗？',
        exampleDialogs: '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''',
      );

      expect(AssistantConversationFactory.openingMessageCandidates(assistant), [
        '你听见钟声了吗？',
        '雨声盖住了脚步声。',
        '钟塔今晚没有准点报时。',
      ]);
      expect(
        AssistantConversationFactory.openingMessageOf(assistant),
        '你听见钟声了吗？',
      );
      expect(
        AssistantConversationFactory.openingMessageOf(
          assistant,
          candidateIndex: 2,
        ),
        '钟塔今晚没有准点报时。',
      );
    });

    test('Starcore asset avatar is copied into a new conversation', () {
      final assistant = AssistantModel(
        id: 45,
        name: '向导',
        emoji: '🤖',
        avatarType: AvatarAssetService.assetType,
        avatarValue: StarcoreIconAssets.assistantExplorerId,
      );

      final conversation = AssistantConversationFactory.create(
        cid: 125,
        icon: '',
        assistant: assistant,
      );

      expect(conversation.avatarType, AvatarAssetService.assetType);
      expect(
        conversation.avatarValue,
        StarcoreIconAssets.assistantExplorerId,
      );
    });

    test('unknown asset avatar falls back to the assistant emoji', () {
      final assistant = AssistantModel(
        id: 46,
        name: '未知头像',
        emoji: '🧭',
        avatarType: AvatarAssetService.assetType,
        avatarValue: 'unknown_asset',
      );

      final conversation = AssistantConversationFactory.create(
        cid: 126,
        icon: '',
        assistant: assistant,
      );

      expect(conversation.avatarType, 'emoji');
      expect(conversation.avatarValue, '🧭');
    });
  });

  group('CompletionDao.injectSystemPrompt', () {
    final history = [
      {'role': 'user', 'content': 'hi'},
      {'role': 'assistant', 'content': 'hello'},
    ];

    test('非空提示词插在头部，且前置当前日期', () {
      final out = CompletionDao.injectSystemPrompt(history, '你是猫娘');
      expect(out.length, 3);
      expect(out.first['role'], 'system');
      expect(
          out.first['content'], '${CompletionDao.dateSystemPrompt()}\n\n你是猫娘');
      expect(out[1]['role'], 'user');
    });

    test('空/null/全空白时仍注入当前日期 system', () {
      for (final p in [null, '', '  \n']) {
        final out = CompletionDao.injectSystemPrompt(history, p);
        expect(out.length, 3);
        expect(out.first,
            {'role': 'system', 'content': CompletionDao.dateSystemPrompt()});
        expect(out[1]['role'], 'user');
      }
    });

    test('提示词首尾空白被 trim', () {
      final out = CompletionDao.injectSystemPrompt(history, '  你是猫娘 \n');
      expect(
          out.first['content'], '${CompletionDao.dateSystemPrompt()}\n\n你是猫娘');
    });
  });

  group('AssistantDao（真实 DAO + 内存库）', () {
    late Database db;
    late AssistantDao dao;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      dao = await AssistantDao.create(HiDBManager.test(db));
    });

    tearDown(() async {
      await db.close();
    });

    test('新建 -> 查询 -> 更新 -> 删除 全链路', () async {
      final a = AssistantModel(
        name: '审查员',
        prompt: '你是代码审查员',
        description: '严格审查代码',
        openingMessage: '贴代码给我。',
        exampleDialogs: '用户：review\n助手：先看风险。',
        memoryBook: 'repo => 当前仓库只用 provider',
        worldBookJson: '{"entries":[{"content":"只用 provider"}]}',
        defaultVoiceStyle: 'sherpa_matcha_zh_baker',
        avatarType: 'image',
        avatarValue: '/tmp/reviewer.png',
        providerId: 'openai',
        model: 'gpt-4o',
        toolIds: ['web_search'],
      );
      final id = await dao.saveAssistant(a);
      expect(id, isNotNull);
      expect(a.id, id);
      expect(a.createdAt, greaterThan(0));

      final loaded = await dao.getAssistant(id!);
      expect(loaded, isNotNull);
      expect(loaded!.name, '审查员');
      expect(loaded.useTools, isTrue);
      expect(loaded.providerId, 'openai');
      expect(loaded.model, 'gpt-4o');
      expect(loaded.description, '严格审查代码');
      expect(loaded.openingMessage, '贴代码给我。');
      expect(loaded.exampleDialogs, '用户：review\n助手：先看风险。');
      expect(loaded.memoryBook, 'repo => 当前仓库只用 provider');
      expect(loaded.worldBookJson, '{"entries":[{"content":"只用 provider"}]}');
      expect(loaded.defaultVoiceStyle, 'sherpa_matcha_zh_baker');
      expect(loaded.avatarType, 'image');
      expect(loaded.avatarValue, '/tmp/reviewer.png');
      expect(loaded.toolIds, ['web_search']);

      loaded.name = '资深审查员';
      loaded.useTools = false;
      loaded.providerId = 'deepseek';
      loaded.model = 'deepseek-reasoner';
      await dao.saveAssistant(loaded);
      final reloaded = await dao.getAssistant(id);
      expect(reloaded!.name, '资深审查员');
      expect(reloaded.useTools, isFalse);
      expect(reloaded.providerId, 'deepseek');
      expect(reloaded.model, 'deepseek-reasoner');

      await dao.deleteAssistant(id);
      expect(await dao.getAssistant(id), isNull);
      expect(await dao.getAssistants(), isEmpty);
    });

    test('列表按 updatedAt 倒序', () async {
      final a = AssistantModel(name: 'A');
      await dao.saveAssistant(a);
      await Future.delayed(const Duration(milliseconds: 2));
      await dao.saveAssistant(AssistantModel(name: 'B'));
      await Future.delayed(const Duration(milliseconds: 2));
      // 再次保存 A，A 应排到最前
      await dao.saveAssistant(a);
      final list = await dao.getAssistants();
      expect(list.map((e) => e.name).toList(), ['A', 'B']);
    });

    test('旧助手表自动补齐角色卡字段', () async {
      await db.close();
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
          'create table tb_assistant (id integer primary key autoincrement'
          ', name text, emoji text, prompt text, providerId text, model text'
          ', useTools integer, tools text, createdAt integer, updatedAt integer)');
      dao = await AssistantDao.create(HiDBManager.test(db));

      final a = AssistantModel(
        name: '角色',
        description: '简介',
        openingMessage: '你好',
        exampleDialogs: '示例',
        memoryBook: '关键词 => 设定',
        worldBookJson: '{"entries":[]}',
        defaultVoiceStyle: 'female',
        avatarType: 'image',
        avatarValue: '/tmp/role.png',
      );
      final id = await dao.saveAssistant(a);
      final loaded = await dao.getAssistant(id!);

      expect(loaded!.description, '简介');
      expect(loaded.openingMessage, '你好');
      expect(loaded.exampleDialogs, '示例');
      expect(loaded.memoryBook, '关键词 => 设定');
      expect(loaded.worldBookJson, '{"entries":[]}');
      expect(loaded.defaultVoiceStyle, 'female');
      expect(loaded.avatarType, 'image');
      expect(loaded.avatarValue, '/tmp/role.png');
    });
  });

  group('tb_conversation_list 升级（assistantId 列）', () {
    late Database db;

    tearDown(() async {
      await db.close();
    });

    test('旧表（无 assistantId 列）经 create 后可读写 assistantId', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      // 模拟旧版 schema（阶段七之前，无 assistantId 列）
      await db.execute(
          'create table tb_conversation_list (id integer primary key autoincrement'
          ', cid integer, title text, icon text, updateAt integer'
          ', messageCount integer, lastMessage text, stickTime integer)');
      final dao = await ConversationListDao.create(HiDBManager.test(db));

      final model = ConversationModel(cid: 42, icon: '', assistantId: 9)
        ..title = 'with assistant'
        ..stickTime = 0;
      await dao.saveConversation(model);

      final list = await dao.getConversationList();
      expect(list.single.assistantId, 9);
    });

    test('新库直接建表（含 assistantId），重复 create 幂等', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final manager = HiDBManager.test(db);
      await ConversationListDao.create(manager);
      // 二次 create：ALTER 抛「列已存在」被吞掉，不影响使用
      final dao = await ConversationListDao.create(manager);

      final model = ConversationModel(cid: 1, icon: '')
        ..title = 'no assistant'
        ..stickTime = 0;
      await dao.saveConversation(model);
      final list = await dao.getConversationList();
      expect(list.single.assistantId, isNull);
    });
  });
}
