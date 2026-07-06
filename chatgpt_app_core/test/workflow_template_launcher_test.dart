import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/capability/workflow_template_launcher.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => sqfliteFfiInit());

  test('ensureAssistantForTemplate 创建并复用模板助手', () async {
    final storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    final template = BuiltinWorkflowTemplates.byId('paper_reading')!;

    final first = await WorkflowTemplateLauncher.ensureAssistantForTemplate(
        storage, template);
    final second = await WorkflowTemplateLauncher.ensureAssistantForTemplate(
        storage, template);
    final dao = await AssistantDao.create(storage);
    final assistants = await dao.getAssistants();

    expect(first, isNotNull);
    expect(second!.id, first!.id);
    expect(assistants, hasLength(1));
    expect(assistants.single.name, template.assistantName);
    expect(assistants.single.prompt, template.systemPrompt);
    expect(assistants.single.toolIds, template.toolIds);
    await storage.db.close();
  });

  test('角色场景模板创建助手时保留主开场和备选开场', () async {
    final storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    const template = WorkflowTemplate(
      id: 'role_scene',
      title: '艾琳 · 角色场景',
      category: '角色场景',
      assistantName: '艾琳',
      systemPrompt: '保持克制而温柔',
      firstUserPrompt: '''
请以「艾琳」的角色设定开始本场景。
角色开场白：
你听见钟声了吗？

可选备选开场白：
- 雨声盖住了脚步声。
- 钟塔今晚没有准点报时。
''',
    );

    final assistant = await WorkflowTemplateLauncher.ensureAssistantForTemplate(
        storage, template);

    expect(assistant, isNotNull);
    expect(assistant!.openingMessage, '你听见钟声了吗？');
    expect(assistant.exampleDialogs, contains('[备选开场白]'));
    expect(assistant.exampleDialogs, contains('雨声盖住了脚步声。'));
    expect(assistant.exampleDialogs, contains('钟塔今晚没有准点报时。'));

    final dao = await AssistantDao.create(storage);
    final saved = (await dao.getAssistants()).single;
    expect(saved.openingMessage, '你听见钟声了吗？');
    expect(saved.exampleDialogs, contains('雨声盖住了脚步声。'));
    await storage.db.close();
  });

  test('复用旧模板助手时会补齐缺失的开场候选', () async {
    final storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    final dao = await AssistantDao.create(storage);
    await dao.saveAssistant(AssistantModel(
      name: '艾琳',
      prompt: '保持克制而温柔',
    ));
    const template = WorkflowTemplate(
      id: 'role_scene',
      title: '艾琳 · 角色场景',
      category: '角色场景',
      assistantName: '艾琳',
      systemPrompt: '保持克制而温柔',
      firstUserPrompt: '''
请以「艾琳」的角色设定开始本场景。
角色开场白：你听见钟声了吗？

可选备选开场白：
- 雨声盖住了脚步声。
''',
    );

    final assistant = await WorkflowTemplateLauncher.ensureAssistantForTemplate(
        storage, template);

    expect(assistant!.openingMessage, '你听见钟声了吗？');
    expect(assistant.exampleDialogs, contains('雨声盖住了脚步声。'));
    final assistants = await dao.getAssistants();
    expect(assistants, hasLength(1));
    expect(assistants.single.openingMessage, '你听见钟声了吗？');
    expect(assistants.single.exampleDialogs, contains('雨声盖住了脚步声。'));
    await storage.db.close();
  });

  test('conversationForTemplate 继承模型、工具和联网搜索配置', () async {
    final template = BuiltinWorkflowTemplates.byId('paper_reading')!;
    final conversation = WorkflowTemplateLauncher.conversationForTemplate(
      template,
      null,
      now: 42,
      icon: 'avatar.png',
      projectId: 7,
    );

    expect(conversation.cid, 42);
    expect(conversation.icon, 'avatar.png');
    expect(conversation.projectId, 7);
    expect(conversation.webSearchEnabled, isTrue);
    expect(conversation.toolIds, template.toolIds);
    expect(conversation.title, isNull);
  });

  test('模板项目会创建/复用项目，并绑定已有知识库文档', () async {
    final storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    final template = BuiltinWorkflowTemplates.byId('paper_reading')!.copyWith(
      providerCode: 'openai',
      modelId: 'gpt-4o',
    );
    final assistant = await WorkflowTemplateLauncher.ensureAssistantForTemplate(
        storage, template);
    final knowledgeDao = await KnowledgeDao.create(storage);
    final paperId = await knowledgeDao.addDocument('论文原文', 'Flutter RAG');
    await knowledgeDao.addDocument('无关文档', 'Other');

    final project = await WorkflowTemplateLauncher.ensureProjectForTemplate(
      storage,
      template,
      assistant: assistant,
    );
    final bound = await WorkflowTemplateLauncher.bindKnowledgeForTemplate(
      storage,
      template,
      project,
    );

    expect(project, isNotNull);
    expect(project!.name, '研究阅读');
    expect(project.defaultProviderId, 'openai');
    expect(project.defaultModelId, 'gpt-4o');
    expect(project.defaultAssistantId, assistant!.id);
    expect(project.defaultUseWebSearch, isTrue);
    expect(project.defaultToolIds, template.toolIds);
    expect(paperId, isNotNull);
    expect(bound, contains(paperId!));

    final projectDao = await ProjectDao.create(storage);
    final projects = await projectDao.getProjects();
    final saved = projects.single;
    expect(saved.name, '研究阅读');
    expect(saved.defaultAssistantId, assistant.id);
    expect(await knowledgeDao.getProjectDocIds(saved.id!), [paperId]);

    final again = await WorkflowTemplateLauncher.ensureProjectForTemplate(
      storage,
      template,
      assistant: assistant,
    );
    expect(again!.id, saved.id);
    expect((await projectDao.getProjects()), hasLength(1));
    await storage.db.close();
  });

  test('initialPromptForTemplate 注入项目、知识库和工具上下文', () {
    final template = BuiltinWorkflowTemplates.byId('paper_reading')!;
    final prompt = WorkflowTemplateLauncher.initialPromptForTemplate(template);

    expect(prompt, contains(template.firstUserPrompt));
    expect(prompt, contains('项目：${template.projectName}'));
    expect(prompt, contains('优先检索知识库：论文原文、研究笔记'));
    expect(prompt, contains('需要时请结合联网搜索核对最新信息。'));
    expect(prompt, contains('可用工具：web_search、knowledge_search'));
  });
}
