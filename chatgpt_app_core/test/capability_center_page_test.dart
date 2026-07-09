import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/capability/workflow_template_store.dart';
import 'package:chatgpt_app_core/pages/capability_center_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  testWidgets('能力中心展示工作流模板、能力地基和回归清单', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CapabilityCenterPage()),
    );

    Future<void> scrollToText(String text) async {
      final target = find.text(text);
      for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -360));
        await tester.pump();
      }
      expect(target, findsOneWidget);
      await tester.ensureVisible(target);
      await tester.pump();
    }

    expect(find.text('AI 能力中心'), findsOneWidget);
    expect(find.text('工作流模板'), findsOneWidget);
    expect(find.text('论文阅读'), findsOneWidget);
    expect(find.text('代码审查'), findsOneWidget);

    await scrollToText('能力地基');
    expect(find.text('能力地基'), findsOneWidget);
    await scrollToText('用量 / 成本统计');
    expect(find.text('用量 / 成本统计'), findsOneWidget);
    expect(find.textContaining('项目维度'), findsOneWidget);
    expect(find.textContaining('服务商、模型、日期、项目、会话'), findsOneWidget);
    await scrollToText('向量知识库 / RAG');
    expect(find.text('向量知识库 / RAG'), findsOneWidget);

    await scrollToText('附件与 File API');
    expect(find.textContaining('assets/avatars'), findsOneWidget);
    expect(find.textContaining('assets/files'), findsOneWidget);
    expect(find.textContaining('assets/generated_images'), findsOneWidget);

    await scrollToText('图片生成保存');
    expect(find.textContaining('应用内相册并纳入备份'), findsOneWidget);

    await scrollToText('自动化回归清单');
    expect(find.text('自动化回归清单'), findsOneWidget);
    expect(find.text('发送消息与流式收尾'), findsOneWidget);
    await scrollToText('跨设备云同步');
    expect(find.text('跨设备云同步'), findsWidgets);
    await scrollToText('会话搜索与命中定位');
    expect(find.text('会话搜索与命中定位'), findsOneWidget);
  });

  testWidgets('能力中心回归清单覆盖所有场景项与步骤', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CapabilityCenterPage()),
    );
    await tester.pumpAndSettle();

    Future<void> scrollToText(String text) async {
      final target = find.text(text);
      for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -360));
        await tester.pump();
      }
      expect(target, findsOneWidget);
      await tester.ensureVisible(target);
      await tester.pump();
    }

    for (final template in BuiltinWorkflowTemplates.all) {
      await scrollToText(template.title);
    }

    for (final title in const [
      '用量 / 成本统计',
      '向量知识库 / RAG',
      '跨设备云同步',
      '附件与 File API',
      '图片生成保存',
      '语音输入 / 朗读',
      'MCP / 工具审计',
    ]) {
      await scrollToText(title);
    }

    for (final scenario in ReliabilityBacklog.scenarios) {
      await scrollToText(scenario.title);
      final tile = find.widgetWithText(ExpansionTile, scenario.title);
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pump();
      expect(find.text('${scenario.id} · 已绑定测试证据'), findsOneWidget);
      for (final step in scenario.steps) {
        expect(find.text(step), findsOneWidget);
      }
      final evidence = ReliabilityBacklog.evidenceFor(scenario.id);
      expect(evidence, isNotNull);
      expect(find.text('覆盖测试'), findsOneWidget);
      expect(find.text('关键断言'), findsOneWidget);
      expect(find.text('运行命令'), findsOneWidget);
      expect(find.textContaining(evidence!.testFiles.first), findsWidgets);
      expect(find.textContaining(evidence.assertions.first), findsOneWidget);
      expect(find.text(evidence.command), findsOneWidget);
      await tester.tap(tile);
      await tester.pump();
    }
  });

  testWidgets('工作流模板可一键开始', (tester) async {
    WorkflowTemplate? started;
    await tester.pumpWidget(
      MaterialApp(
        home: CapabilityCenterPage(
          onStartTemplate: (_, template) async => started = template,
        ),
      ),
    );

    await tester.tap(find.text('开始').first);
    await tester.pump();

    expect(started, isNotNull);
    expect(started!.id, 'paper_reading');
    expect(started!.firstUserPrompt, isNotEmpty);
  });

  testWidgets('可从内置工作流复制为自定义模板', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CapabilityCenterPage()),
    );

    await tester.tap(find.byTooltip('模板操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    expect(find.text('论文阅读 副本'), findsOneWidget);
    expect(const WorkflowTemplateStore().load().single.title, '论文阅读 副本');
  });

  testWidgets('可新增自定义模板并一键开始', (tester) async {
    WorkflowTemplate? started;
    await tester.pumpWidget(
      MaterialApp(
        home: CapabilityCenterPage(
          onStartTemplate: (_, template) async => started = template,
        ),
      ),
    );

    await tester.tap(find.byTooltip('新增模板'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '每日复盘');
    await tester.enterText(fields.at(1), '个人');
    await tester.enterText(fields.at(3), '复盘助手');
    await tester.enterText(fields.at(7), '你擅长复盘。');
    await tester.enterText(fields.at(8), '请帮我复盘今天。');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('每日复盘'), findsOneWidget);
    expect(const WorkflowTemplateStore().load().single.title, '每日复盘');

    await tester.tap(find.text('开始').first);
    await tester.pump();

    expect(started, isNotNull);
    expect(started!.title, '每日复盘');
    expect(started!.assistantName, '复盘助手');
    expect(started!.firstUserPrompt, '请帮我复盘今天。');
  });

  testWidgets('角色场景模板展示角色、项目、模型、工具和开场提示', (tester) async {
    const store = WorkflowTemplateStore();
    await store.save(const [
      WorkflowTemplate(
        id: 'role_airin',
        title: '艾琳 · 角色场景',
        category: '角色场景',
        projectName: '艾琳 角色场景',
        assistantName: '艾琳',
        providerCode: 'openai',
        modelId: 'gpt-4o',
        toolIds: ['knowledge_search'],
        systemPrompt: '保持克制而温柔',
        firstUserPrompt: '请以「艾琳」的角色设定开始本场景。',
      ),
    ]);
    WorkflowTemplate? started;
    WorkflowTemplate? opened;

    await tester.pumpWidget(
      MaterialApp(
        home: CapabilityCenterPage(
          onStartTemplate: (_, template) async => started = template,
          onOpenRoleTemplate: (_, template) async => opened = template,
        ),
      ),
    );

    expect(find.byIcon(Icons.theater_comedy_outlined), findsOneWidget);
    expect(find.text('艾琳 · 角色场景'), findsOneWidget);
    expect(find.text('角色：艾琳'), findsOneWidget);
    expect(find.text('项目：艾琳 角色场景'), findsOneWidget);
    expect(find.text('openai / gpt-4o'), findsOneWidget);
    expect(find.text('工具：knowledge_search'), findsOneWidget);
    expect(find.textContaining('开场提示：请以「艾琳」'), findsOneWidget);
    expect(find.text('查看角色资料'), findsOneWidget);

    await tester.tap(find.text('查看角色资料'));
    await tester.pump();

    expect(opened?.id, 'role_airin');

    await tester.tap(find.text('开始').first);
    await tester.pump();

    expect(started?.id, 'role_airin');
  });

  testWidgets('自定义角色场景模板可编辑并保留原 id', (tester) async {
    const store = WorkflowTemplateStore();
    await store.save(const [
      WorkflowTemplate(
        id: 'role_airin',
        title: '艾琳 · 角色场景',
        category: '角色场景',
        projectName: '艾琳 角色场景',
        assistantName: '艾琳',
        providerCode: 'openai',
        modelId: 'gpt-4o',
        toolIds: ['knowledge_search'],
        firstUserPrompt: '请以「艾琳」的角色设定开始本场景。',
      ),
    ]);

    await tester.pumpWidget(
      const MaterialApp(home: CapabilityCenterPage()),
    );

    await tester.tap(find.byTooltip('模板操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑工作流模板'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '艾琳 · 雨夜旧书店');
    await tester.enterText(fields.at(2), '艾琳故事');
    await tester.enterText(fields.at(6), 'knowledge_search, web_search');
    await tester.enterText(fields.at(8), '从雨夜旧书店开始。');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('艾琳 · 雨夜旧书店'), findsOneWidget);
    expect(find.text('项目：艾琳故事'), findsOneWidget);
    expect(find.text('工具：knowledge_search / web_search'), findsOneWidget);
    expect(find.textContaining('开场提示：从雨夜旧书店开始。'), findsOneWidget);
    expect(find.text('已更新「艾琳 · 雨夜旧书店」'), findsOneWidget);
    final saved = store.load().single;
    expect(saved.id, 'role_airin');
    expect(saved.title, '艾琳 · 雨夜旧书店');
    expect(saved.projectName, '艾琳故事');
    expect(saved.toolIds, ['knowledge_search', 'web_search']);
    expect(saved.firstUserPrompt, '从雨夜旧书店开始。');
  });

  testWidgets('自定义模板支持排序和删除', (tester) async {
    const store = WorkflowTemplateStore();
    await store.save(const [
      WorkflowTemplate(id: 'a', title: 'A 模板', category: '自定义'),
      WorkflowTemplate(id: 'b', title: 'B 模板', category: '自定义'),
    ]);

    await tester.pumpWidget(
      const MaterialApp(home: CapabilityCenterPage()),
    );

    expect(
      tester.getTopLeft(find.text('A 模板')).dy,
      lessThan(tester.getTopLeft(find.text('B 模板')).dy),
    );

    await tester.tap(find.byTooltip('模板操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下移'));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('B 模板')).dy,
      lessThan(tester.getTopLeft(find.text('A 模板')).dy),
    );

    await tester.tap(find.byTooltip('模板操作').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('A 模板'), findsNothing);
    expect(store.load().map((e) => e.title), ['B 模板']);
  });
}
