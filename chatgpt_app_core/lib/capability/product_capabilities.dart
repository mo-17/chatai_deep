import 'dart:math';

/// 产品能力 MVP 地基：把后续大能力收敛成可测试的纯业务模型。
///
/// 这些类不直接绑定 UI / DB / 网络，目的是先固定客户端侧合同：
/// 页面、DAO、后端同步、真实 embedding / ASR / 图片保存能力都可以逐步接入。

// ---------------------------------------------------------------------------
// 1. 用户侧用量 / 成本统计

class UsageSample {
  final String modelId;
  final String? projectId;
  final String? conversationId;
  final DateTime at;
  final int promptTokens;
  final int cachedPromptTokens;
  final int completionTokens;
  final double? cachedInputCostPer1K;
  final double inputCostPer1K;
  final double outputCostPer1K;
  final bool estimated;

  const UsageSample({
    required this.modelId,
    required this.at,
    this.projectId,
    this.conversationId,
    this.promptTokens = 0,
    this.cachedPromptTokens = 0,
    this.completionTokens = 0,
    this.cachedInputCostPer1K,
    this.inputCostPer1K = 0,
    this.outputCostPer1K = 0,
    this.estimated = false,
  });

  int get totalTokens => promptTokens + completionTokens;

  double get effectiveCachedInputCostPer1K =>
      cachedInputCostPer1K ?? inputCostPer1K;

  int get uncachedPromptTokens =>
      (promptTokens - cachedPromptTokens).clamp(0, promptTokens).toInt();

  double get cost =>
      cachedPromptTokens.clamp(0, promptTokens) /
          1000000 *
          effectiveCachedInputCostPer1K +
      uncachedPromptTokens / 1000000 * inputCostPer1K +
      completionTokens / 1000000 * outputCostPer1K;

  String dayKey() => '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}

class UsageBucket {
  final String key;
  final int promptTokens;
  final int completionTokens;
  final double cost;
  final int calls;
  final bool hasEstimated;

  const UsageBucket({
    required this.key,
    required this.promptTokens,
    required this.completionTokens,
    required this.cost,
    required this.calls,
    required this.hasEstimated,
  });

  int get totalTokens => promptTokens + completionTokens;
}

class UsageCostEstimator {
  /// 本地直连无 usage 时的保守估算：中英混合按约 4 字符 / token。
  static int estimateTokens(String text) {
    final n = text.trim().runes.length;
    if (n == 0) return 0;
    return max(1, (n / 4).ceil());
  }

  static UsageSample estimateTurn({
    required String modelId,
    required String prompt,
    required String completion,
    required DateTime at,
    String? projectId,
    String? conversationId,
    double inputCostPer1K = 0,
    double outputCostPer1K = 0,
  }) =>
      UsageSample(
        modelId: modelId,
        at: at,
        projectId: projectId,
        conversationId: conversationId,
        promptTokens: estimateTokens(prompt),
        completionTokens: estimateTokens(completion),
        inputCostPer1K: inputCostPer1K,
        outputCostPer1K: outputCostPer1K,
        estimated: true,
      );

  static List<UsageBucket> groupBy(
    Iterable<UsageSample> samples,
    String Function(UsageSample sample) keyOf,
  ) {
    final map = <String, List<UsageSample>>{};
    for (final sample in samples) {
      map.putIfAbsent(keyOf(sample), () => []).add(sample);
    }
    final buckets = <UsageBucket>[];
    for (final entry in map.entries) {
      var prompt = 0;
      var completion = 0;
      var cost = 0.0;
      var estimated = false;
      for (final sample in entry.value) {
        prompt += sample.promptTokens;
        completion += sample.completionTokens;
        cost += sample.cost;
        estimated = estimated || sample.estimated;
      }
      buckets.add(UsageBucket(
        key: entry.key,
        promptTokens: prompt,
        completionTokens: completion,
        cost: cost,
        calls: entry.value.length,
        hasEstimated: estimated,
      ));
    }
    buckets.sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    return buckets;
  }
}

// ---------------------------------------------------------------------------
// 2. 会话模板 / 工作流模板

class WorkflowTemplate {
  final String id;
  final String title;
  final String category;
  final String? projectName;
  final String? assistantName;
  final String? providerCode;
  final String? modelId;
  final bool webSearch;
  final List<String> toolIds;
  final List<String> knowledgeDocTitles;
  final String systemPrompt;
  final String firstUserPrompt;

  const WorkflowTemplate({
    required this.id,
    required this.title,
    required this.category,
    this.projectName,
    this.assistantName,
    this.providerCode,
    this.modelId,
    this.webSearch = false,
    this.toolIds = const [],
    this.knowledgeDocTitles = const [],
    this.systemPrompt = '',
    this.firstUserPrompt = '',
  });

  bool get usesKnowledge => knowledgeDocTitles.isNotEmpty;
  bool get usesTools => toolIds.isNotEmpty;

  WorkflowTemplate copyWith({
    String? id,
    String? title,
    String? category,
    String? projectName,
    String? assistantName,
    String? providerCode,
    String? modelId,
    bool? webSearch,
    List<String>? toolIds,
    List<String>? knowledgeDocTitles,
    String? systemPrompt,
    String? firstUserPrompt,
  }) =>
      WorkflowTemplate(
        id: id ?? this.id,
        title: title ?? this.title,
        category: category ?? this.category,
        projectName: projectName ?? this.projectName,
        assistantName: assistantName ?? this.assistantName,
        providerCode: providerCode ?? this.providerCode,
        modelId: modelId ?? this.modelId,
        webSearch: webSearch ?? this.webSearch,
        toolIds: toolIds ?? this.toolIds,
        knowledgeDocTitles: knowledgeDocTitles ?? this.knowledgeDocTitles,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        firstUserPrompt: firstUserPrompt ?? this.firstUserPrompt,
      );

  factory WorkflowTemplate.fromJson(Map<String, dynamic> json) =>
      WorkflowTemplate(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        category: json['category'] as String? ?? '自定义',
        projectName: json['projectName'] as String?,
        assistantName: json['assistantName'] as String?,
        providerCode: json['providerCode'] as String?,
        modelId: json['modelId'] as String?,
        webSearch: json['webSearch'] as bool? ?? false,
        toolIds: (json['toolIds'] as List?)?.whereType<String>().toList() ??
            const [],
        knowledgeDocTitles: (json['knowledgeDocTitles'] as List?)
                ?.whereType<String>()
                .toList() ??
            const [],
        systemPrompt: json['systemPrompt'] as String? ?? '',
        firstUserPrompt: json['firstUserPrompt'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'projectName': projectName,
        'assistantName': assistantName,
        'providerCode': providerCode,
        'modelId': modelId,
        'webSearch': webSearch,
        'toolIds': toolIds,
        'knowledgeDocTitles': knowledgeDocTitles,
        'systemPrompt': systemPrompt,
        'firstUserPrompt': firstUserPrompt,
      };
}

class BuiltinWorkflowTemplates {
  static const all = [
    WorkflowTemplate(
      id: 'paper_reading',
      title: '论文阅读',
      category: '学习',
      projectName: '研究阅读',
      assistantName: '论文拆解助手',
      webSearch: true,
      toolIds: ['web_search', 'knowledge_search'],
      knowledgeDocTitles: ['论文原文', '研究笔记'],
      systemPrompt: '你擅长把论文拆成问题、方法、实验、结论和局限。',
      firstUserPrompt: '请按背景、方法、实验、结论、可复现风险总结这篇论文。',
    ),
    WorkflowTemplate(
      id: 'code_review',
      title: '代码审查',
      category: '编程',
      projectName: '代码项目',
      assistantName: '代码审查员',
      toolIds: ['search_chat_history', 'knowledge_search'],
      knowledgeDocTitles: ['项目设计文档', '变更说明'],
      systemPrompt: '你优先发现 bug、回归风险和缺失测试。',
      firstUserPrompt: '请审查这次改动，按严重程度列出问题。',
    ),
    WorkflowTemplate(
      id: 'weekly_report',
      title: '周报生成',
      category: '职场',
      assistantName: '周报助手',
      systemPrompt: '你把零散记录整理成清晰、克制、可交付的周报。',
      firstUserPrompt: '请根据以下要点生成本周周报。',
    ),
  ];

  static WorkflowTemplate? byId(String id) {
    for (final template in all) {
      if (template.id == id) return template;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// 3. 向量知识库 / RAG 升级地基（本地轻量向量；真实 embedding 可替换 vectorOf）

class RagDocument {
  final String id;
  final String title;
  final String content;

  const RagDocument({
    required this.id,
    required this.title,
    required this.content,
  });
}

class RagHit {
  final RagDocument document;
  final double score;
  final String snippet;

  const RagHit({
    required this.document,
    required this.score,
    required this.snippet,
  });
}

class LightweightVectorRag {
  static List<String> tokenize(String text) {
    final normalized = text.toLowerCase();
    final tokens = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(normalized)
        .map((m) => m.group(0)!)
        .where((t) => t.trim().isNotEmpty)
        .toList();
    final expanded = <String>[...tokens];
    for (final token in tokens) {
      final cjkChars = RegExp(r'[\u4e00-\u9fff]', unicode: true)
          .allMatches(token)
          .map((m) => m.group(0)!)
          .toList();
      for (var i = 0; i < cjkChars.length - 1; i++) {
        expanded.add('${cjkChars[i]}${cjkChars[i + 1]}');
      }
    }
    return expanded;
  }

  static Map<String, double> vectorOf(String text) {
    final counts = <String, double>{};
    for (final token in tokenize(text)) {
      counts[token] = (counts[token] ?? 0) + 1;
    }
    return counts;
  }

  static double cosine(Map<String, double> a, Map<String, double> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var dot = 0.0;
    var an = 0.0;
    var bn = 0.0;
    for (final entry in a.entries) {
      an += entry.value * entry.value;
      dot += entry.value * (b[entry.key] ?? 0);
    }
    for (final v in b.values) {
      bn += v * v;
    }
    if (an == 0 || bn == 0) return 0;
    return dot / (sqrt(an) * sqrt(bn));
  }

  static List<RagHit> search(
    String query,
    Iterable<RagDocument> docs, {
    int limit = 6,
  }) {
    final qv = vectorOf(query);
    final hits = <RagHit>[];
    for (final doc in docs) {
      final score = cosine(qv, vectorOf('${doc.title} ${doc.content}'));
      if (score <= 0) continue;
      hits.add(RagHit(
        document: doc,
        score: score,
        snippet: doc.content.length <= 120
            ? doc.content
            : '${doc.content.substring(0, 120)}...',
      ));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }
}

// ---------------------------------------------------------------------------
// 4. 跨设备云同步地基

enum SyncOp { upsert, delete }

class SyncChange {
  final String entity;
  final String id;
  final SyncOp op;
  final int updatedAt;
  final Map<String, dynamic> payload;

  const SyncChange({
    required this.entity,
    required this.id,
    required this.op,
    required this.updatedAt,
    this.payload = const {},
  });

  String get key => '$entity:$id';
}

class SyncMergeResult {
  final List<SyncChange> accepted;
  final List<SyncChange> rejectedStale;
  final List<String> conflicts;

  const SyncMergeResult({
    required this.accepted,
    required this.rejectedStale,
    required this.conflicts,
  });
}

class SyncPlanner {
  /// Last-write-wins MVP。相同 updatedAt 但 payload 不同记为冲突，交 UI 提示。
  static SyncMergeResult merge(
    Iterable<SyncChange> local,
    Iterable<SyncChange> remote,
  ) {
    final byKey = <String, SyncChange>{};
    final stale = <SyncChange>[];
    final conflicts = <String>[];

    void put(SyncChange change) {
      final current = byKey[change.key];
      if (current == null || change.updatedAt > current.updatedAt) {
        if (current != null) stale.add(current);
        byKey[change.key] = change;
        return;
      }
      if (change.updatedAt < current.updatedAt) {
        stale.add(change);
        return;
      }
      if (!_mapEquals(change.payload, current.payload) ||
          change.op != current.op) {
        conflicts.add(change.key);
      }
    }

    for (final change in local) {
      put(change);
    }
    for (final change in remote) {
      put(change);
    }
    return SyncMergeResult(
      accepted: byKey.values.toList()..sort((a, b) => a.key.compareTo(b.key)),
      rejectedStale: stale,
      conflicts: conflicts.toSet().toList()..sort(),
    );
  }

  static bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// 5. 附件与文件能力升级

class AttachmentPolicyDecision {
  final bool useFileApi;
  final bool backupOriginal;
  final bool restoreNeedsOriginalFile;
  final String reason;

  const AttachmentPolicyDecision({
    required this.useFileApi,
    required this.backupOriginal,
    required this.restoreNeedsOriginalFile,
    required this.reason,
  });
}

class AttachmentUpgradePolicy {
  static AttachmentPolicyDecision decide({
    required String filename,
    required int sizeBytes,
    required bool modelSupportsNativeFile,
    int inlineLimitBytes = 8 * 1024 * 1024,
  }) {
    final lower = filename.toLowerCase();
    final isPdf = lower.endsWith('.pdf');
    if (isPdf && modelSupportsNativeFile && sizeBytes > inlineLimitBytes) {
      return const AttachmentPolicyDecision(
        useFileApi: true,
        backupOriginal: true,
        restoreNeedsOriginalFile: true,
        reason: 'pdf_over_inline_limit',
      );
    }
    return AttachmentPolicyDecision(
      useFileApi: false,
      backupOriginal: sizeBytes <= inlineLimitBytes,
      restoreNeedsOriginalFile: false,
      reason:
          sizeBytes <= inlineLimitBytes ? 'inline_or_text' : 'metadata_only',
    );
  }
}

// ---------------------------------------------------------------------------
// 6. 图片生成与相册保存

class GeneratedImageSavePlan {
  final String source;
  final String albumName;
  final String filename;
  final bool needsPhotoPermission;

  const GeneratedImageSavePlan({
    required this.source,
    required this.albumName,
    required this.filename,
    required this.needsPhotoPermission,
  });
}

class ImageGenerationPolicy {
  static GeneratedImageSavePlan? planSave({
    required String source,
    String albumName = 'ChatAI Deep',
    DateTime? now,
  }) {
    if (source.isEmpty) return null;
    final valid = source.startsWith('data:image/') ||
        source.startsWith('http://') ||
        source.startsWith('https://') ||
        source.startsWith('/');
    if (!valid) return null;
    final t = now ?? DateTime.now();
    final stamp =
        '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}_'
        '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
    return GeneratedImageSavePlan(
      source: source,
      albumName: albumName,
      filename: 'chatai_$stamp.png',
      needsPhotoPermission: false,
    );
  }
}

// ---------------------------------------------------------------------------
// 7. 助手模型覆盖升级

class AssistantModelRoute {
  final String? providerCode;
  final String modelId;

  const AssistantModelRoute({this.providerCode, required this.modelId});

  bool get switchesProvider => providerCode != null && providerCode!.isNotEmpty;

  static AssistantModelRoute? parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final parts = value.split('/');
    if (parts.length >= 2 && parts.first.trim().isNotEmpty) {
      return AssistantModelRoute(
        providerCode: parts.first.trim(),
        modelId: parts.sublist(1).join('/').trim(),
      );
    }
    return AssistantModelRoute(modelId: value);
  }

  String encode() =>
      switchesProvider ? '${providerCode!.trim()}/${modelId.trim()}' : modelId;
}

// ---------------------------------------------------------------------------
// 8. MCP / 工具生态增强

enum ToolPermission { readOnly, confirmWrite, disabled }

class ToolPolicy {
  final String toolId;
  final ToolPermission permission;
  final Set<int> projectIds;

  const ToolPolicy({
    required this.toolId,
    this.permission = ToolPermission.readOnly,
    this.projectIds = const {},
  });

  bool isAllowed({int? projectId, bool confirmed = false}) {
    if (permission == ToolPermission.disabled) return false;
    if (projectIds.isNotEmpty && !projectIds.contains(projectId)) return false;
    if (permission == ToolPermission.confirmWrite && !confirmed) return false;
    return true;
  }
}

class ToolAuditEntry {
  final String toolId;
  final int at;
  final bool success;
  final String summary;

  const ToolAuditEntry({
    required this.toolId,
    required this.at,
    required this.success,
    this.summary = '',
  });
}

// ---------------------------------------------------------------------------
// 9. 语音输入 / 朗读

class VoiceConversationPrefs {
  final bool speechInputEnabled;
  final bool readAloudEnabled;
  final String locale;
  final double rate;
  final String voiceStyle;

  const VoiceConversationPrefs({
    this.speechInputEnabled = false,
    this.readAloudEnabled = false,
    this.locale = 'zh-CN',
    this.rate = 1.0,
    this.voiceStyle = 'system',
  });

  VoiceConversationPrefs copyWith({
    bool? speechInputEnabled,
    bool? readAloudEnabled,
    String? locale,
    double? rate,
    String? voiceStyle,
  }) =>
      VoiceConversationPrefs(
        speechInputEnabled: speechInputEnabled ?? this.speechInputEnabled,
        readAloudEnabled: readAloudEnabled ?? this.readAloudEnabled,
        locale: locale ?? this.locale,
        rate: rate ?? this.rate,
        voiceStyle: voiceStyle ?? this.voiceStyle,
      );
}

// ---------------------------------------------------------------------------
// 10. 可靠性与自动化回归

class ReliabilityScenario {
  final String id;
  final String title;
  final List<String> steps;

  const ReliabilityScenario({
    required this.id,
    required this.title,
    required this.steps,
  });
}

class ReliabilityEvidence {
  final String scenarioId;
  final List<String> testFiles;
  final List<String> assertions;
  final String command;

  const ReliabilityEvidence({
    required this.scenarioId,
    required this.testFiles,
    required this.assertions,
    this.command = 'flutter test',
  });
}

class ReliabilityBacklog {
  static const scenarios = [
    ReliabilityScenario(
      id: 'send_message',
      title: '发送消息与流式收尾',
      steps: ['新建会话', '发送用户消息', '等待 assistant 流式完成', '校验落库 blocks'],
    ),
    ReliabilityScenario(
      id: 'switch_model',
      title: '会话内切换模型',
      steps: ['打开模型选择器', '筛选可用模型', '切换模型', '校验底部状态刷新'],
    ),
    ReliabilityScenario(
      id: 'usage_stats',
      title: '用量统计与成本汇总',
      steps: ['记录聊天 usage', '按模型/服务商/日期/项目/会话聚合', '配置成本单价', '复制汇总文本'],
    ),
    ReliabilityScenario(
      id: 'workflow_templates',
      title: '会话模板与工作流启动',
      steps: ['复制或新增模板', '创建/复用模板项目和助手', '绑定同名知识库', '打开预填提示的新会话'],
    ),
    ReliabilityScenario(
      id: 'assistant_market',
      title: '助手市场与模板克隆',
      steps: ['浏览内置助手模板', '搜索名称/分类/提示词', '克隆模板为我的助手', '校验克隆后可独立编辑'],
    ),
    ReliabilityScenario(
      id: 'backup_restore',
      title: '备份导出与导入',
      steps: ['导出备份', '导入空库', '校验会话/知识库/头像资源数量'],
    ),
    ReliabilityScenario(
      id: 'tool_confirm',
      title: '写工具确认弹窗',
      steps: ['启用写工具', '触发工具调用', '拒绝确认', '校验本地数据未变'],
    ),
    ReliabilityScenario(
      id: 'knowledge_import',
      title: '知识库导入与检索',
      steps: ['多选导入文件', '跳过空内容或不支持文件', '检索命中文档片段', '校验失败明细'],
    ),
    ReliabilityScenario(
      id: 'knowledge_rag_index',
      title: 'RAG 索引重建',
      steps: ['导入知识库文档', '清空或缺失本地向量索引', '重建检索索引', '校验检索仍可命中'],
    ),
    ReliabilityScenario(
      id: 'generated_image_album',
      title: '生成图片保存与相册',
      steps: ['保存生成图片到应用目录', '打开生成图片相册', '刷新相册列表', '确认删除本地图片'],
    ),
    ReliabilityScenario(
      id: 'voice_prefs',
      title: '语音偏好与朗读执行',
      steps: ['保存会话语音偏好', '恢复识别语言和朗读速率', 'assistant 回复完成触发 flutter_tts 朗读'],
    ),
    ReliabilityScenario(
      id: 'cloud_sync',
      title: '跨设备云同步',
      steps: ['导出本地增量变更', '分页拉取远端变更', '上传本地变更', '展示冲突与同步游标'],
    ),
    ReliabilityScenario(
      id: 'conversation_search',
      title: '会话搜索与命中定位',
      steps: ['搜索会话标题/最近消息/历史消息', '展开多处命中片段', '点击历史命中定位到原消息'],
    ),
  ];

  static const evidence = [
    ReliabilityEvidence(
      scenarioId: 'send_message',
      testFiles: [
        'test/block_message_test.dart',
        'test/tool_history_test.dart',
        'test/usage_record_test.dart',
      ],
      assertions: [
        '流式事件可沉淀为 typed blocks',
        '工具调用历史可跨轮重建',
        '聊天收尾可记录真实或估算 usage，并按 provider/model 单价估算成本',
      ],
      command:
          'flutter test test/block_message_test.dart test/tool_history_test.dart test/usage_record_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'switch_model',
      testFiles: [
        'test/assistant_test.dart',
        'test/model_picker_presenter_test.dart',
        'test/model_capabilities_test.dart',
        'test/project_dao_test.dart',
      ],
      assertions: [
        '助手 provider/model 覆盖可持久化',
        '会话模型选择器可按最近使用、搜索、可用状态和能力位过滤模型',
        '模型能力位合并保持加法语义',
        '会话级模型覆盖可恢复跟随全局',
      ],
      command:
          'flutter test test/assistant_test.dart test/model_picker_presenter_test.dart test/model_capabilities_test.dart test/project_dao_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'usage_stats',
      testFiles: [
        'test/usage_record_test.dart',
        'test/usage_stats_page_test.dart',
      ],
      assertions: [
        '聊天 usage 可落库并按模型、服务商、日期、项目、会话聚合',
        '项目维度可识别项目名、未分类和项目表缺失兜底',
        '成本单价可保存，复制汇总文本覆盖总览与五类聚合明细',
      ],
      command:
          'flutter test test/usage_record_test.dart test/usage_stats_page_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'workflow_templates',
      testFiles: [
        'test/workflow_template_store_test.dart',
        'test/workflow_template_launcher_test.dart',
        'test/capability_center_page_test.dart',
      ],
      assertions: [
        '自定义模板可新增、复制、排序、删除并持久化',
        '模板启动会创建/复用项目和助手，写入默认 provider/model/联网/工具配置',
        '模板列出的同名知识库文档会绑定到项目范围，首条提示会携带模板上下文',
      ],
      command:
          'flutter test test/workflow_template_store_test.dart test/workflow_template_launcher_test.dart test/capability_center_page_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'assistant_market',
      testFiles: [
        'test/builtin_assistants_test.dart',
        'test/assistant_market_page_test.dart',
      ],
      assertions: [
        '内置助手目录字段完整、名称唯一且按分类分组不丢条目',
        '模板克隆为 AssistantModel 后是独立新实例，可落库并再次编辑',
        '助手市场可按名称、分类和提示词搜索模板，无命中时展示空态',
      ],
      command:
          'flutter test test/builtin_assistants_test.dart test/assistant_market_page_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'backup_restore',
      testFiles: [
        'test/backup_test.dart',
        'test/backup_restore_page_test.dart',
        'test/generated_image_save_service_test.dart',
      ],
      assertions: [
        '备份导入导出覆盖会话/知识库/头像资源 assets/avatars、附件原始文件 assets/files、生成图片资源 assets/generated_images',
        '导入预览页可展示冲突摘要并选择覆盖全部、仅项目会话、仅助手、仅知识库、合并导入模式',
        '合并导入会保留本地数据并重映射 cid/id 与关联引用',
        '缺少头像资源时会降级默认头像，合并导入生成图片同名时会追加唯一文件名',
      ],
      command:
          'flutter test test/backup_test.dart test/backup_restore_page_test.dart test/generated_image_save_service_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'tool_confirm',
      testFiles: [
        'test/assistant_write_tools_test.dart',
        'test/mcp_test.dart',
        'test/tool_audit_dao_test.dart',
        'test/tool_calling_test.dart',
      ],
      assertions: [
        '写工具拒绝确认时不修改本地数据',
        'MCP 非信任源无确认时拒绝执行',
        '工具调用审计可持久化查询',
        '动态工具抛错可按策略重试后回灌结果',
        'MCP 工具可按项目白名单过滤，只读权限仅暴露资源/提示词工具',
      ],
      command:
          'flutter test test/assistant_write_tools_test.dart test/mcp_test.dart test/tool_audit_dao_test.dart test/tool_calling_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'knowledge_import',
      testFiles: [
        'test/knowledge_file_importer_test.dart',
        'test/knowledge_base_test.dart',
      ],
      assertions: [
        '知识库文件导入支持多选且单个失败不中断其它文件',
        '空内容或不可识别文件会返回逐文件失败原因',
        '知识库 DAO 可完成导入、检索和删除全链路',
      ],
      command:
          'flutter test test/knowledge_file_importer_test.dart test/knowledge_base_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'knowledge_rag_index',
      testFiles: [
        'test/knowledge_base_test.dart',
      ],
      assertions: [
        '轻量向量索引随文档导入自动写入，删除文档会同步清理',
        '索引缺失或损坏时检索会退回现场计算，不阻断旧数据搜索',
        'rebuildVectorIndex 可单文档或全量重建，并通过 vectorIndexStats 暴露缺失数量',
      ],
      command: 'flutter test test/knowledge_base_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'generated_image_album',
      testFiles: [
        'test/generated_image_save_service_test.dart',
        'test/generated_image_album_page_test.dart',
        'test/my_page_test.dart',
      ],
      assertions: [
        '生成图片可从 data URI、HTTP、本地文件保存到 generated_images 目录',
        '相册列表只展示图片并按修改时间倒序，页面可展示空态、图片信息和刷新',
        '删除图片有 generated_images 目录边界保护，页面需确认后删除并刷新',
        '个人中心新增入口后小屏仍可滚动且无底部溢出',
      ],
      command:
          'flutter test test/generated_image_save_service_test.dart test/generated_image_album_page_test.dart test/my_page_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'voice_prefs',
      testFiles: [
        'test/project_dao_test.dart',
        'test/message_input_widget_test.dart',
        'test/read_aloud_service_test.dart',
        'test/product_capabilities_test.dart',
      ],
      assertions: [
        '会话语音偏好可持久化 speechInputEnabled/readAloudEnabled/voiceLocale/voiceRate/voiceStyle',
        '旧表会自动补齐语音偏好列，恢复默认时字段置空',
        '识别语言为空或插件返回空 localeId 时不会把空字符串传给 speech_to_text',
        'FlutterTtsReadAloudService 会调用 flutter_tts engine，应用语言、语音风格、音量、音调和语速；VoiceConversationPrefs copyWith 保留未修改字段',
      ],
      command:
          'flutter test test/project_dao_test.dart test/message_input_widget_test.dart test/read_aloud_service_test.dart test/product_capabilities_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'cloud_sync',
      testFiles: [
        'test/local_sync_service_test.dart',
        'test/cloud_sync_client_test.dart',
        'test/cloud_sync_page_test.dart',
      ],
      assertions: [
        '本地核心表可导出增量变更并按 LWW 应用远端更新',
        '客户端可分页拉取、上传本地变更并推进 cursor/lastPushAt/lastSyncAt',
        '云同步页面可展示手动/自动来源、云端游标、中文冲突原因和同步中禁用状态',
      ],
      command:
          'flutter test test/local_sync_service_test.dart test/cloud_sync_client_test.dart test/cloud_sync_page_test.dart',
    ),
    ReliabilityEvidence(
      scenarioId: 'conversation_search',
      testFiles: [
        'test/project_dao_test.dart',
        'test/conversation_search_page_test.dart',
      ],
      assertions: [
        '搜索按标题、最近消息、历史消息相关性排序并标注来源',
        '全局搜索入口会以全部会话范围打开搜索页',
        '历史消息命中会携带 targetMessageCreatedAt 并可跳回原消息',
        '同一会话多处历史命中可展开显示多个片段，每个片段可单独定位且保持关键词高亮',
      ],
      command:
          'flutter test test/project_dao_test.dart test/conversation_search_page_test.dart',
    ),
  ];

  static ReliabilityEvidence? evidenceFor(String scenarioId) {
    for (final item in evidence) {
      if (item.scenarioId == scenarioId) return item;
    }
    return null;
  }
}
