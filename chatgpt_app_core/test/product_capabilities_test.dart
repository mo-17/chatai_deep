import 'dart:io';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsageCostEstimator', () {
    test('估算 token 并按模型聚合成本', () {
      final at = DateTime(2026, 6, 30, 10);
      final samples = [
        UsageCostEstimator.estimateTurn(
          modelId: 'gpt-a',
          prompt: '12345678',
          completion: '1234',
          at: at,
          inputCostPer1K: 1,
          outputCostPer1K: 2,
        ),
        UsageSample(
          modelId: 'gpt-a',
          at: at,
          promptTokens: 10,
          cachedPromptTokens: 4,
          completionTokens: 20,
          cachedInputCostPer1K: 0.5,
          inputCostPer1K: 1,
          outputCostPer1K: 2,
        ),
      ];

      final buckets = UsageCostEstimator.groupBy(samples, (s) => s.modelId);
      expect(buckets, hasLength(1));
      expect(buckets.single.calls, 2);
      expect(buckets.single.promptTokens, 12);
      expect(buckets.single.completionTokens, 21);
      expect(buckets.single.cost, closeTo(0.000052, 0.000000001));
      expect(buckets.single.hasEstimated, isTrue);
    });
  });

  group('WorkflowTemplate', () {
    test('内置模板能表达工具和知识库工作流', () {
      final paper = BuiltinWorkflowTemplates.byId('paper_reading')!;
      expect(paper.webSearch, isTrue);
      expect(paper.usesTools, isTrue);
      expect(paper.usesKnowledge, isTrue);
      expect(paper.toolIds, contains('knowledge_search'));
      expect(paper.knowledgeDocTitles, contains('论文原文'));
      expect(BuiltinWorkflowTemplates.byId('missing'), isNull);
    });

    test('支持 JSON 往返，便于持久化自定义模板', () {
      const template = WorkflowTemplate(
        id: 'custom_review',
        title: '自定义审查',
        category: '自定义',
        projectName: '项目 A',
        assistantName: '审查助手',
        providerCode: 'openai',
        modelId: 'gpt-4o',
        webSearch: true,
        toolIds: ['web_search', 'knowledge_search'],
        knowledgeDocTitles: ['设计文档'],
        systemPrompt: '优先找风险。',
        firstUserPrompt: '请审查以下内容。',
      );

      final restored = WorkflowTemplate.fromJson(template.toJson());

      expect(restored.id, template.id);
      expect(restored.title, template.title);
      expect(restored.category, template.category);
      expect(restored.projectName, template.projectName);
      expect(restored.assistantName, template.assistantName);
      expect(restored.providerCode, template.providerCode);
      expect(restored.modelId, template.modelId);
      expect(restored.webSearch, isTrue);
      expect(restored.toolIds, template.toolIds);
      expect(restored.knowledgeDocTitles, template.knowledgeDocTitles);
      expect(restored.systemPrompt, template.systemPrompt);
      expect(restored.firstUserPrompt, template.firstUserPrompt);
    });
  });

  group('LightweightVectorRag', () {
    test('轻量向量检索按相关性返回命中文档', () {
      final hits = LightweightVectorRag.search('flutter sqlite', const [
        RagDocument(
          id: '1',
          title: 'Flutter storage',
          content: 'Use sqflite and sqlite for local database.',
        ),
        RagDocument(
          id: '2',
          title: 'Cooking',
          content: 'Salt and sugar.',
        ),
      ]);
      expect(hits, hasLength(1));
      expect(hits.single.document.id, '1');
      expect(hits.single.score, greaterThan(0));
    });
  });

  group('SyncPlanner', () {
    test('last-write-wins，并标记同时间不同 payload 的冲突', () {
      final result = SyncPlanner.merge(
        const [
          SyncChange(
            entity: 'conversation',
            id: '1',
            op: SyncOp.upsert,
            updatedAt: 10,
            payload: {'title': 'old'},
          ),
          SyncChange(
            entity: 'conversation',
            id: '2',
            op: SyncOp.upsert,
            updatedAt: 20,
            payload: {'title': 'local'},
          ),
        ],
        const [
          SyncChange(
            entity: 'conversation',
            id: '1',
            op: SyncOp.upsert,
            updatedAt: 11,
            payload: {'title': 'new'},
          ),
          SyncChange(
            entity: 'conversation',
            id: '2',
            op: SyncOp.upsert,
            updatedAt: 20,
            payload: {'title': 'remote'},
          ),
        ],
      );
      expect(result.accepted.firstWhere((c) => c.id == '1').payload['title'],
          'new');
      expect(result.rejectedStale.single.id, '1');
      expect(result.conflicts, ['conversation:2']);
    });
  });

  group('AttachmentUpgradePolicy', () {
    test('超限 PDF 走 File API 并纳入原始文件备份', () {
      final decision = AttachmentUpgradePolicy.decide(
        filename: 'paper.pdf',
        sizeBytes: 12 * 1024 * 1024,
        modelSupportsNativeFile: true,
      );
      expect(decision.useFileApi, isTrue);
      expect(decision.backupOriginal, isTrue);
      expect(decision.reason, 'pdf_over_inline_limit');
    });

    test('非直连能力或超限 PDF 不走 File API 时保持告警边界', () {
      final decision = AttachmentUpgradePolicy.decide(
        filename: 'paper.pdf',
        sizeBytes: 12 * 1024 * 1024,
        modelSupportsNativeFile: false,
      );
      expect(decision.useFileApi, isFalse);
      expect(decision.backupOriginal, isFalse);
      expect(decision.reason, 'metadata_only');
    });
  });

  group('ImageGenerationPolicy', () {
    test('为模型生成图生成相册保存计划', () {
      final plan = ImageGenerationPolicy.planSave(
        source: 'data:image/png;base64,AA==',
        now: DateTime(2026, 6, 30, 12, 1, 2),
      )!;
      expect(plan.filename, 'chatai_20260630_120102.png');
      expect(plan.needsPhotoPermission, isFalse);
      expect(ImageGenerationPolicy.planSave(source: 'ftp://x'), isNull);
    });
  });

  group('AssistantModelRoute', () {
    test('解析 provider/model 组合并保留旧 modelId 兼容', () {
      final routed = AssistantModelRoute.parse('openai/gpt-4.1')!;
      expect(routed.providerCode, 'openai');
      expect(routed.modelId, 'gpt-4.1');
      expect(routed.switchesProvider, isTrue);
      expect(routed.encode(), 'openai/gpt-4.1');

      final legacy = AssistantModelRoute.parse('deepseek-chat')!;
      expect(legacy.providerCode, isNull);
      expect(legacy.modelId, 'deepseek-chat');
      expect(legacy.switchesProvider, isFalse);
    });
  });

  group('ToolPolicy', () {
    test('按项目和写入确认控制工具可用性', () {
      const policy = ToolPolicy(
        toolId: 'save_favorite',
        permission: ToolPermission.confirmWrite,
        projectIds: {7},
      );
      expect(policy.isAllowed(projectId: 7), isFalse);
      expect(policy.isAllowed(projectId: 7, confirmed: true), isTrue);
      expect(policy.isAllowed(projectId: 8, confirmed: true), isFalse);
    });
  });

  group('VoiceConversationPrefs', () {
    test('支持会话级语音偏好复制', () {
      const prefs = VoiceConversationPrefs();
      final next = prefs.copyWith(
        readAloudEnabled: true,
        rate: 1.2,
        voiceStyle: 'female',
      );
      expect(next.locale, 'zh-CN');
      expect(next.readAloudEnabled, isTrue);
      expect(next.rate, 1.2);
      expect(next.voiceStyle, 'female');
    });
  });

  group('ReliabilityBacklog', () {
    test('覆盖核心自动化回归场景', () {
      final ids = ReliabilityBacklog.scenarios.map((s) => s.id).toSet();
      expect(
          ids,
          containsAll([
            'send_message',
            'switch_model',
            'usage_stats',
            'workflow_templates',
            'assistant_market',
            'backup_restore',
            'tool_confirm',
            'knowledge_import',
            'knowledge_rag_index',
            'generated_image_album',
            'voice_prefs',
            'cloud_sync',
            'conversation_search',
          ]));
      expect(ReliabilityBacklog.scenarios.every((s) => s.steps.isNotEmpty),
          isTrue);
    });

    test('每个回归场景都绑定真实测试证据文件', () {
      final evidenceIds =
          ReliabilityBacklog.evidence.map((e) => e.scenarioId).toSet();
      final scenarioIds = ReliabilityBacklog.scenarios.map((s) => s.id).toSet();
      expect(evidenceIds, scenarioIds);
      for (final evidence in ReliabilityBacklog.evidence) {
        expect(evidence.testFiles, isNotEmpty);
        expect(evidence.assertions, isNotEmpty);
        expect(evidence.command, startsWith('flutter test'));
        for (final path in evidence.testFiles) {
          expect(File(path).existsSync(), isTrue, reason: path);
        }
      }
    });

    test('模型切换证据覆盖模型选择器列表行为', () {
      final evidence = ReliabilityBacklog.evidenceFor('switch_model')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('模型选择器'));
      expect(assertions, contains('最近使用'));
      expect(assertions, contains('能力位过滤'));
      expect(evidence.testFiles,
          contains('test/model_picker_presenter_test.dart'));
      expect(
          evidence.command, contains('test/model_picker_presenter_test.dart'));
    });

    test('备份恢复证据覆盖合并导入的关键回归', () {
      final evidence = ReliabilityBacklog.evidenceFor('backup_restore')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('合并导入'));
      expect(assertions, contains('重映射 cid/id'));
      expect(assertions, contains('assets/avatars'));
      expect(assertions, contains('assets/files'));
      expect(assertions, contains('assets/generated_images'));
      expect(assertions, contains('降级默认头像'));
      expect(assertions, contains('唯一文件名'));
      expect(
          evidence.testFiles, contains('test/backup_restore_page_test.dart'));
      expect(evidence.command, contains('test/backup_test.dart'));
    });

    test('用量统计证据覆盖项目维度、成本单价和复制汇总', () {
      final evidence = ReliabilityBacklog.evidenceFor('usage_stats')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('项目'));
      expect(assertions, contains('未分类'));
      expect(assertions, contains('成本单价'));
      expect(assertions, contains('复制汇总'));
      expect(evidence.testFiles, contains('test/usage_record_test.dart'));
      expect(evidence.testFiles, contains('test/usage_stats_page_test.dart'));
      expect(evidence.command, contains('test/usage_stats_page_test.dart'));
    });

    test('工作流模板证据覆盖自定义管理、项目化启动和知识库绑定', () {
      final evidence = ReliabilityBacklog.evidenceFor('workflow_templates')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('新增、复制、排序、删除'));
      expect(assertions, contains('创建/复用项目和助手'));
      expect(assertions, contains('同名知识库文档'));
      expect(assertions, contains('首条提示'));
      expect(evidence.testFiles,
          contains('test/workflow_template_store_test.dart'));
      expect(evidence.testFiles,
          contains('test/workflow_template_launcher_test.dart'));
      expect(evidence.testFiles,
          contains('test/capability_center_page_test.dart'));
      expect(evidence.command,
          contains('test/workflow_template_launcher_test.dart'));
    });

    test('助手市场证据覆盖模板搜索和克隆落库', () {
      final evidence = ReliabilityBacklog.evidenceFor('assistant_market')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('名称唯一'));
      expect(assertions, contains('独立新实例'));
      expect(assertions, contains('搜索模板'));
      expect(evidence.testFiles, contains('test/builtin_assistants_test.dart'));
      expect(
          evidence.testFiles, contains('test/assistant_market_page_test.dart'));
      expect(
          evidence.command, contains('test/assistant_market_page_test.dart'));
    });

    test('RAG 索引证据覆盖自动索引、缺失回退和重建', () {
      final evidence = ReliabilityBacklog.evidenceFor('knowledge_rag_index')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('自动写入'));
      expect(assertions, contains('退回现场计算'));
      expect(assertions, contains('rebuildVectorIndex'));
      expect(assertions, contains('vectorIndexStats'));
      expect(evidence.testFiles, contains('test/knowledge_base_test.dart'));
      expect(evidence.command, 'flutter test test/knowledge_base_test.dart');
    });

    test('生成图片相册证据覆盖保存、查看、删除和个人中心入口', () {
      final evidence = ReliabilityBacklog.evidenceFor('generated_image_album')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('data URI'));
      expect(assertions, contains('generated_images'));
      expect(assertions, contains('修改时间倒序'));
      expect(assertions, contains('目录边界保护'));
      expect(assertions, contains('小屏'));
      expect(evidence.testFiles,
          contains('test/generated_image_save_service_test.dart'));
      expect(evidence.testFiles,
          contains('test/generated_image_album_page_test.dart'));
      expect(evidence.testFiles, contains('test/my_page_test.dart'));
      expect(evidence.command,
          contains('test/generated_image_album_page_test.dart'));
    });

    test('语音偏好证据覆盖持久化、补列和 flutter_tts 朗读', () {
      final evidence = ReliabilityBacklog.evidenceFor('voice_prefs')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('speechInputEnabled'));
      expect(assertions, contains('readAloudEnabled'));
      expect(assertions, contains('voiceLocale'));
      expect(assertions, contains('voiceRate'));
      expect(assertions, contains('voiceStyle'));
      expect(assertions, contains('speech_to_text'));
      expect(assertions, contains('空字符串'));
      expect(assertions, contains('FlutterTtsReadAloudService'));
      expect(assertions, contains('flutter_tts engine'));
      expect(assertions, contains('语音风格'));
      expect(evidence.testFiles, contains('test/project_dao_test.dart'));
      expect(
          evidence.testFiles, contains('test/message_input_widget_test.dart'));
      expect(evidence.testFiles, contains('test/read_aloud_service_test.dart'));
      expect(
          evidence.testFiles, contains('test/product_capabilities_test.dart'));
      expect(evidence.command, contains('test/message_input_widget_test.dart'));
      expect(evidence.command, contains('test/read_aloud_service_test.dart'));
    });

    test('云同步证据覆盖本地合并、协议和页面反馈', () {
      final evidence = ReliabilityBacklog.evidenceFor('cloud_sync')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('LWW'));
      expect(assertions, contains('cursor/lastPushAt/lastSyncAt'));
      expect(assertions, contains('中文冲突原因'));
      expect(evidence.testFiles, contains('test/local_sync_service_test.dart'));
      expect(evidence.testFiles, contains('test/cloud_sync_client_test.dart'));
      expect(evidence.testFiles, contains('test/cloud_sync_page_test.dart'));
      expect(evidence.command, contains('test/cloud_sync_page_test.dart'));
    });

    test('会话搜索证据覆盖消息定位和多片段展开', () {
      final evidence = ReliabilityBacklog.evidenceFor('conversation_search')!;
      final assertions = evidence.assertions.join('\n');

      expect(assertions, contains('全局搜索入口'));
      expect(assertions, contains('targetMessageCreatedAt'));
      expect(assertions, contains('多处历史命中'));
      expect(evidence.testFiles, contains('test/project_dao_test.dart'));
      expect(evidence.testFiles,
          contains('test/conversation_search_page_test.dart'));
      expect(evidence.command,
          contains('test/conversation_search_page_test.dart'));
    });
  });
}
