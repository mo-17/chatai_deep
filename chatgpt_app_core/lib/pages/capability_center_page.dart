import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/capability/workflow_template_launcher.dart';
import 'package:chatgpt_app_core/capability/workflow_template_store.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:flutter/material.dart';

/// 能力中心：把已落地的客户端能力合同展示给用户。
///
/// 真实云同步 / embedding / 相册 / ASR/TTS 等外部能力接入前，这里先提供
/// 可见入口与状态说明，避免能力只停留在代码层。
class CapabilityCenterPage extends StatefulWidget {
  final Future<void> Function(BuildContext context, WorkflowTemplate template)?
      onStartTemplate;
  final Future<void> Function(BuildContext context, WorkflowTemplate template)?
      onOpenRoleTemplate;
  final WorkflowTemplateStore templateStore;

  const CapabilityCenterPage({
    super.key,
    this.onStartTemplate,
    this.onOpenRoleTemplate,
    this.templateStore = const WorkflowTemplateStore(),
  });

  @override
  State<CapabilityCenterPage> createState() => _CapabilityCenterPageState();
}

class _CapabilityCenterPageState extends State<CapabilityCenterPage> {
  List<WorkflowTemplate> _customTemplates = const [];

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  void _loadTemplates() {
    setState(() => _customTemplates = widget.templateStore.load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 能力中心'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '新增模板',
            icon: const Icon(Icons.add),
            onPressed: _addTemplate,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('工作流模板'),
          for (final template in _customTemplates)
            _WorkflowTemplateCard(
              template: template,
              custom: true,
              onStart: () => _startTemplate(template),
              onOpenRole: _isRoleSceneTemplate(template)
                  ? () => _openRoleTemplate(template)
                  : null,
              onEdit: () => _editTemplate(template),
              onDuplicate: () => _duplicateTemplate(template),
              onMoveUp: () => _moveTemplate(template, -1),
              onMoveDown: () => _moveTemplate(template, 1),
              onDelete: () => _deleteTemplate(template),
            ),
          for (final template in BuiltinWorkflowTemplates.all)
            _WorkflowTemplateCard(
              template: template,
              onStart: () => _startTemplate(template),
              onOpenRole: _isRoleSceneTemplate(template)
                  ? () => _openRoleTemplate(template)
                  : null,
              onDuplicate: () => _duplicateTemplate(template),
            ),
          const SizedBox(height: 16),
          _sectionTitle('能力地基'),
          const _CapabilityTile(
            icon: Icons.insights_outlined,
            title: '用量 / 成本统计',
            status: '已接入 token 记录、可配置成本、项目维度与复制汇总',
            detail: '按服务商、模型、日期、项目、会话统计；成本按 provider/model 单价口径估算。',
          ),
          const _CapabilityTile(
            icon: Icons.hub_outlined,
            title: '向量知识库 / RAG',
            status: '已具备轻量向量检索合同',
            detail: '真实 embedding provider 可替换 LightweightVectorRag.vectorOf。',
          ),
          const _CapabilityTile(
            icon: Icons.sync_outlined,
            title: '跨设备云同步',
            status: '已接入增量传输、账号游标与 LWW 合并',
            detail: '已支持分页拉取、上次同步时间和冲突原因展示；多设备联调与加密策略仍待真实环境验证。',
          ),
          const _CapabilityTile(
            icon: Icons.attach_file,
            title: '附件与 File API',
            status: '头像、附件原始文件和生成图片资源已进入备份',
            detail:
                'assets/avatars、assets/files、assets/generated_images 均可恢复；超限 PDF 原生上传仍待服务商 File API。',
          ),
          const _CapabilityTile(
            icon: Icons.image_outlined,
            title: '图片生成保存',
            status: '图片块已可保存到应用内相册并纳入备份',
            detail: '应用目录保存、查看、删除和备份恢复均无需相册权限；系统相册写入仍待平台插件和真机验证。',
          ),
          const _CapabilityTile(
            icon: Icons.record_voice_over_outlined,
            title: '语音输入 / 朗读',
            status: '已具备语音输入入口与朗读执行合同',
            detail: '会话偏好会触发可注入朗读服务；系统 TTS 发声仍待平台插件和真机验证。',
          ),
          const _CapabilityTile(
            icon: Icons.security_outlined,
            title: 'MCP / 工具审计',
            status: 'MCP 已支持审计、失败重试和项目/权限策略',
            detail: '可按项目白名单下发工具；只读权限仅暴露资源/提示词工具。',
          ),
          const SizedBox(height: 16),
          _sectionTitle('自动化回归清单'),
          for (final scenario in ReliabilityBacklog.scenarios)
            _ScenarioTile(scenario: scenario),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      );

  Future<void> _startTemplate(WorkflowTemplate template) {
    return (widget.onStartTemplate ?? WorkflowTemplateLauncher.start)(
      context,
      template,
    );
  }

  bool _isRoleSceneTemplate(WorkflowTemplate template) =>
      template.category.trim() == '角色场景';

  Future<void> _openRoleTemplate(WorkflowTemplate template) {
    return (widget.onOpenRoleTemplate ?? _openRoleTemplateDefault)(
      context,
      template,
    );
  }

  Future<void> _openRoleTemplateDefault(
    BuildContext context,
    WorkflowTemplate template,
  ) async {
    final assistant = await _findAssistantForRoleTemplate(template);
    if (!context.mounted) return;
    if (assistant == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到对应角色，请先在助手管理中确认角色仍存在')),
      );
      return;
    }
    final memories = await _loadAssistantMemories(assistant);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantProfilePage(
          assistant: assistant,
          memories: memories,
        ),
      ),
    );
  }

  Future<AssistantModel?> _findAssistantForRoleTemplate(
    WorkflowTemplate template,
  ) async {
    final name = template.assistantName?.trim();
    if (name == null || name.isEmpty) return null;
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await AssistantDao.create(storage);
    final assistants = await dao.getAssistants();
    final prompt = template.systemPrompt.trim();
    AssistantModel? nameOnly;
    for (final assistant in assistants) {
      if (assistant.name.trim() != name) continue;
      nameOnly ??= assistant;
      if (prompt.isEmpty || assistant.prompt.trim() == prompt) {
        return assistant;
      }
    }
    return nameOnly;
  }

  Future<List<AssistantMemoryModel>> _loadAssistantMemories(
      AssistantModel assistant) async {
    final id = assistant.id;
    if (id == null) return const [];
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await AssistantMemoryDao.create(storage);
    return dao.getMemories(id, limit: 8);
  }

  Future<void> _addTemplate() async {
    final template = await _showTemplateDialog();
    if (template == null) return;
    final list = await widget.templateStore.add(template);
    if (!mounted) return;
    setState(() => _customTemplates = list);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已新增「${template.title}」')),
    );
  }

  Future<void> _editTemplate(WorkflowTemplate template) async {
    final next = await _showTemplateDialog(existing: template);
    if (next == null) return;
    final list = await widget.templateStore.update(next);
    if (!mounted) return;
    setState(() => _customTemplates = list);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已更新「${next.title}」')),
    );
  }

  Future<void> _duplicateTemplate(WorkflowTemplate template) async {
    final list = await widget.templateStore.duplicate(template);
    if (!mounted) return;
    setState(() => _customTemplates = list);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制「${template.title}」')),
    );
  }

  Future<void> _moveTemplate(WorkflowTemplate template, int delta) async {
    final list = await widget.templateStore.move(template.id, delta);
    if (!mounted) return;
    setState(() => _customTemplates = list);
  }

  Future<void> _deleteTemplate(WorkflowTemplate template) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('确定删除「${template.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final list = await widget.templateStore.delete(template.id);
    if (!mounted) return;
    setState(() => _customTemplates = list);
  }

  Future<WorkflowTemplate?> _showTemplateDialog({
    WorkflowTemplate? existing,
  }) async {
    final titleCtl = TextEditingController(text: existing?.title ?? '');
    final categoryCtl =
        TextEditingController(text: existing?.category ?? '自定义');
    final projectCtl = TextEditingController(text: existing?.projectName ?? '');
    final assistantCtl =
        TextEditingController(text: existing?.assistantName ?? '');
    final providerCtl =
        TextEditingController(text: existing?.providerCode ?? '');
    final modelCtl = TextEditingController(text: existing?.modelId ?? '');
    final toolsCtl =
        TextEditingController(text: existing?.toolIds.join(', ') ?? '');
    final systemCtl = TextEditingController(text: existing?.systemPrompt ?? '');
    final firstPromptCtl =
        TextEditingController(text: existing?.firstUserPrompt ?? '');
    var webSearch = existing?.webSearch ?? false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? '新增工作流模板' : '编辑工作流模板'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtl,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                TextField(
                  controller: categoryCtl,
                  decoration: const InputDecoration(labelText: '分类'),
                ),
                TextField(
                  controller: projectCtl,
                  decoration: const InputDecoration(labelText: '项目名'),
                ),
                TextField(
                  controller: assistantCtl,
                  decoration: const InputDecoration(labelText: '助手名'),
                ),
                TextField(
                  controller: providerCtl,
                  decoration: const InputDecoration(labelText: '服务商'),
                ),
                TextField(
                  controller: modelCtl,
                  decoration: const InputDecoration(labelText: '模型'),
                ),
                TextField(
                  controller: toolsCtl,
                  decoration: const InputDecoration(
                    labelText: '工具 ID',
                    hintText: '多个工具用逗号分隔，例如 knowledge_search',
                  ),
                ),
                TextField(
                  controller: systemCtl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '系统提示'),
                ),
                TextField(
                  controller: firstPromptCtl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: '首条提示词'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用联网搜索'),
                  value: webSearch,
                  onChanged: (value) => setDialogState(() => webSearch = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    final title = titleCtl.text.trim();
    if (title.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模板标题不能为空')),
        );
      }
      return null;
    }
    final assistantName = assistantCtl.text.trim();
    return WorkflowTemplate(
      id: existing?.id ?? '',
      title: title,
      category:
          categoryCtl.text.trim().isEmpty ? '自定义' : categoryCtl.text.trim(),
      projectName: _emptyToNull(projectCtl.text),
      assistantName: assistantName.isEmpty ? title : assistantName,
      providerCode: _emptyToNull(providerCtl.text),
      modelId: _emptyToNull(modelCtl.text),
      webSearch: webSearch,
      toolIds: _splitList(toolsCtl.text),
      knowledgeDocTitles: existing?.knowledgeDocTitles ?? const [],
      systemPrompt: systemCtl.text.trim(),
      firstUserPrompt: firstPromptCtl.text.trim(),
    );
  }

  String? _emptyToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  List<String> _splitList(String value) {
    return value
        .split(RegExp(r'[,，\n]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}

class _WorkflowTemplateCard extends StatelessWidget {
  final WorkflowTemplate template;
  final VoidCallback onStart;
  final VoidCallback? onOpenRole;
  final VoidCallback? onEdit;
  final VoidCallback? onDuplicate;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onDelete;
  final bool custom;

  const _WorkflowTemplateCard({
    required this.template,
    required this.onStart,
    this.onOpenRole,
    this.onEdit,
    this.onDuplicate,
    this.onMoveUp,
    this.onMoveDown,
    this.onDelete,
    this.custom = false,
  });

  @override
  Widget build(BuildContext context) {
    final isRoleScene = template.category.trim() == '角色场景';
    final assistantName = _trimOrNull(template.assistantName);
    final projectName = _trimOrNull(template.projectName);
    final modelLabel = _modelLabel();
    final toolLabel =
        template.toolIds.isEmpty ? null : template.toolIds.join(' / ');
    final chips = <String>[
      template.category,
      if (template.webSearch) '联网',
      if (template.usesTools) '工具 ${template.toolIds.length}',
      if (template.usesKnowledge) '知识库 ${template.knowledgeDocTitles.length}',
      if (modelLabel != null) modelLabel,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onStart,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isRoleScene) ...[
                    const Icon(Icons.theater_comedy_outlined, size: 22),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(template.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  if (custom)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.edit_note_outlined, size: 20),
                    ),
                  FilledButton.icon(
                    onPressed: onStart,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始'),
                  ),
                  PopupMenuButton<_TemplateAction>(
                    tooltip: '模板操作',
                    onSelected: (action) {
                      switch (action) {
                        case _TemplateAction.edit:
                          onEdit?.call();
                        case _TemplateAction.duplicate:
                          onDuplicate?.call();
                        case _TemplateAction.moveUp:
                          onMoveUp?.call();
                        case _TemplateAction.moveDown:
                          onMoveDown?.call();
                        case _TemplateAction.delete:
                          onDelete?.call();
                      }
                    },
                    itemBuilder: (context) => [
                      if (onEdit != null)
                        const PopupMenuItem(
                          value: _TemplateAction.edit,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.edit_outlined),
                            title: Text('编辑'),
                          ),
                        ),
                      if (onDuplicate != null)
                        const PopupMenuItem(
                          value: _TemplateAction.duplicate,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.copy_outlined),
                            title: Text('复制'),
                          ),
                        ),
                      if (onMoveUp != null)
                        const PopupMenuItem(
                          value: _TemplateAction.moveUp,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.arrow_upward),
                            title: Text('上移'),
                          ),
                        ),
                      if (onMoveDown != null)
                        const PopupMenuItem(
                          value: _TemplateAction.moveDown,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.arrow_downward),
                            title: Text('下移'),
                          ),
                        ),
                      if (onDelete != null)
                        const PopupMenuItem(
                          value: _TemplateAction.delete,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.delete_outline),
                            title: Text('删除'),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              if (assistantName != null) ...[
                const SizedBox(height: 4),
                Text('${isRoleScene ? '角色' : '助手'}：$assistantName',
                    style: const TextStyle(color: Colors.black54)),
              ],
              if (projectName != null) ...[
                const SizedBox(height: 4),
                Text('项目：$projectName',
                    style: const TextStyle(color: Colors.black54)),
              ],
              if (toolLabel != null) ...[
                const SizedBox(height: 4),
                Text('工具：$toolLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black54)),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final chip in chips)
                    Chip(
                        label: Text(chip),
                        visualDensity: VisualDensity.compact),
                ],
              ),
              if (template.firstUserPrompt.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                    '${isRoleScene ? '开场提示' : '首条提示'}：${template.firstUserPrompt}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black87)),
              ],
              if (onOpenRole != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: onOpenRole,
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: const Text('查看角色资料'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _modelLabel() {
    final parts = [
      _trimOrNull(template.providerCode),
      _trimOrNull(template.modelId),
    ].whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(' / ');
  }

  String? _trimOrNull(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}

enum _TemplateAction { edit, duplicate, moveUp, moveDown, delete }

class _CapabilityTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String status;
  final String detail;

  const _CapabilityTile({
    required this.icon,
    required this.title,
    required this.status,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: Text('$status\n$detail'),
      isThreeLine: true,
    );
  }
}

class _ScenarioTile extends StatelessWidget {
  final ReliabilityScenario scenario;

  const _ScenarioTile({required this.scenario});

  @override
  Widget build(BuildContext context) {
    final evidence = ReliabilityBacklog.evidenceFor(scenario.id);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(scenario.title),
      subtitle:
          Text(evidence == null ? scenario.id : '${scenario.id} · 已绑定测试证据'),
      children: [
        for (var i = 0; i < scenario.steps.length; i++)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 12, child: Text('${i + 1}')),
            title: Text(scenario.steps[i]),
          ),
        if (evidence != null) ...[
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('覆盖测试'),
            subtitle: Text(evidence.testFiles.join('\n')),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.rule_outlined),
            title: const Text('关键断言'),
            subtitle: Text(evidence.assertions.join('\n')),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.terminal_outlined),
            title: const Text('运行命令'),
            subtitle: SelectableText(evidence.command),
          ),
        ],
      ],
    );
  }
}
