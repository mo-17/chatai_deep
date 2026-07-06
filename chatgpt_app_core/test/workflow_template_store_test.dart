import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/capability/workflow_template_store.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  test('新增模板会补齐唯一 id 并持久化', () async {
    const store = WorkflowTemplateStore();

    var list = await store.add(const WorkflowTemplate(
      id: 'review',
      title: '审查',
      category: '自定义',
      firstUserPrompt: '请审查。',
    ));
    list = await store.add(const WorkflowTemplate(
      id: 'review',
      title: '二次审查',
      category: '自定义',
    ));

    expect(list.map((e) => e.id), ['review', 'review_2']);
    expect(store.load().map((e) => e.title), ['审查', '二次审查']);
  });

  test('复制模板保留工作流字段并生成副本标题', () async {
    const store = WorkflowTemplateStore();
    const template = WorkflowTemplate(
      id: 'paper',
      title: '论文阅读',
      category: '学习',
      assistantName: '论文助手',
      webSearch: true,
      toolIds: ['web_search', 'knowledge_search'],
      knowledgeDocTitles: ['论文原文'],
      systemPrompt: '拆解论文。',
      firstUserPrompt: '请总结。',
    );

    final list = await store.duplicate(template, now: 42);
    final copy = list.single;

    expect(copy.id, 'paper_copy_42');
    expect(copy.title, '论文阅读 副本');
    expect(copy.category, '学习');
    expect(copy.assistantName, '论文助手');
    expect(copy.webSearch, isTrue);
    expect(copy.toolIds, template.toolIds);
    expect(copy.knowledgeDocTitles, template.knowledgeDocTitles);
    expect(copy.systemPrompt, template.systemPrompt);
    expect(copy.firstUserPrompt, template.firstUserPrompt);
  });

  test('更新模板会保留原 id 并覆盖字段', () async {
    const store = WorkflowTemplateStore();
    await store.save(const [
      WorkflowTemplate(
        id: 'role_airin',
        title: '艾琳 · 角色场景',
        category: '角色场景',
        assistantName: '艾琳',
      ),
    ]);

    final list = await store.update(const WorkflowTemplate(
      id: 'role_airin',
      title: '艾琳 · 雨夜场景',
      category: '角色场景',
      projectName: '艾琳故事',
      assistantName: '艾琳',
      providerCode: 'openai',
      modelId: 'gpt-4o',
      toolIds: ['knowledge_search'],
      systemPrompt: '保持克制而温柔',
      firstUserPrompt: '从雨夜旧书店开始。',
    ));

    expect(list, hasLength(1));
    expect(list.single.id, 'role_airin');
    expect(list.single.title, '艾琳 · 雨夜场景');
    expect(list.single.projectName, '艾琳故事');
    expect(list.single.toolIds, ['knowledge_search']);
    expect(store.load().single.firstUserPrompt, '从雨夜旧书店开始。');
  });

  test('模板可上移下移并可删除', () async {
    const store = WorkflowTemplateStore();
    await store.save(const [
      WorkflowTemplate(id: 'a', title: 'A', category: '自定义'),
      WorkflowTemplate(id: 'b', title: 'B', category: '自定义'),
      WorkflowTemplate(id: 'c', title: 'C', category: '自定义'),
    ]);

    var list = await store.move('c', -1);
    expect(list.map((e) => e.id), ['a', 'c', 'b']);

    list = await store.move('a', -1);
    expect(list.map((e) => e.id), ['a', 'c', 'b']);

    list = await store.move('a', 1);
    expect(list.map((e) => e.id), ['c', 'a', 'b']);

    list = await store.delete('a');
    expect(list.map((e) => e.id), ['c', 'b']);
    expect(store.load().map((e) => e.id), ['c', 'b']);
  });
}
