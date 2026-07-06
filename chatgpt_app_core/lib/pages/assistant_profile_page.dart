import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/capability/workflow_template_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_state_suggester.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_memory_page.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef SaveConversationRoleState = Future<void> Function({
  String? roleScene,
  String? roleRelationship,
  String? roleToneNote,
});

typedef AssistantProfileEditor = Future<bool?> Function(
  BuildContext context,
  AssistantModel assistant,
);

typedef AssistantWorkflowTemplateSaver = Future<void> Function(
  WorkflowTemplate template,
);

class AssistantProfilePage extends StatefulWidget {
  final AssistantModel assistant;
  final List<AssistantMemoryModel> memories;
  final ConversationModel? conversation;
  final SaveConversationRoleState? onSaveRoleState;
  final ConversationRoleStateDraft? suggestedRoleState;
  final VoidCallback? onStartConversation;
  final IAssistantMemory? memoryDao;
  final AssistantWorldBookSaver? worldBookSaver;
  final AssistantProfileEditor? openEditor;
  final AssistantWorkflowTemplateSaver? saveWorkflowTemplate;

  const AssistantProfilePage({
    super.key,
    required this.assistant,
    this.memories = const [],
    this.conversation,
    this.onSaveRoleState,
    this.suggestedRoleState,
    this.onStartConversation,
    this.memoryDao,
    this.worldBookSaver,
    this.openEditor,
    this.saveWorkflowTemplate,
  });

  @override
  State<AssistantProfilePage> createState() => _AssistantProfilePageState();
}

class _AssistantProfilePageState extends State<AssistantProfilePage> {
  String? _roleScene;
  String? _roleRelationship;
  String? _roleToneNote;
  late List<AssistantMemoryModel> _memories;

  @override
  void initState() {
    super.initState();
    _memories = List<AssistantMemoryModel>.of(widget.memories);
    _syncRoleStateFromWidget();
  }

  @override
  void didUpdateWidget(covariant AssistantProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.conversation, widget.conversation)) {
      _syncRoleStateFromWidget();
    }
    if (!identical(oldWidget.memories, widget.memories)) {
      _memories = List<AssistantMemoryModel>.of(widget.memories);
    }
  }

  void _syncRoleStateFromWidget() {
    _roleScene = widget.conversation?.roleScene;
    _roleRelationship = widget.conversation?.roleRelationship;
    _roleToneNote = widget.conversation?.roleToneNote;
  }

  @override
  Widget build(BuildContext context) {
    final assistant = widget.assistant;
    final memories = _memories;
    final summary = AssistantRoleCardService.summarize(assistant);
    final alternateGreetings =
        AssistantRoleCardService.alternateGreetings(assistant.exampleDialogs);
    return Scaffold(
      appBar: AppBar(
        title: const Text('角色资料'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '编辑角色',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _openEdit(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(assistant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      assistant.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (assistant.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        assistant.description.trim(),
                        style: TextStyle(color: Colors.grey[700]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (widget.onStartConversation != null) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onStartConversation,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('开始对话'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.conversation != null) ...[
            _navTile(
              context,
              icon: Icons.theater_comedy_outlined,
              title: '当前会话状态',
              subtitle: _roleStateSummary(),
              onTap: widget.onSaveRoleState == null
                  ? () {}
                  : () => _editRoleState(context),
            ),
            if (_hasRoleState())
              _section(context, '当前会话状态摘要', [
                _kv(
                    '场景',
                    _roleScene?.trim().isNotEmpty == true
                        ? _roleScene!.trim()
                        : '未设置'),
                _kv(
                  '关系',
                  _roleRelationship?.trim().isNotEmpty == true
                      ? _roleRelationship!.trim()
                      : '未设置',
                ),
                _kv(
                  '语气',
                  _roleToneNote?.trim().isNotEmpty == true
                      ? _roleToneNote!.trim()
                      : '未设置',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _copyRoleStateSummary(context),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('复制会话状态摘要'),
                  ),
                ),
              ]),
          ],
          _navTile(
            context,
            icon: Icons.preview_outlined,
            title: '上下文预览',
            subtitle: '查看角色卡、世界书、会话状态和长期记忆',
            onTap: () => _showContextPreview(context),
          ),
          _section(context, '下一轮上下文影响', [
            _kv('角色卡', _roleCardImpactText(summary)),
            _kv('世界书', _worldBookImpactText(summary)),
            _kv('会话状态', _roleStateImpactText()),
            _kv('长期记忆', _longTermMemoryImpactText(memories)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _copyContextImpactSummary(context),
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('复制影响摘要'),
              ),
            ),
          ]),
          _navTile(
            context,
            icon: Icons.copy_all_outlined,
            title: '复制角色卡摘要',
            subtitle: '复制人设、开场白、示例对话和世界书摘要',
            onTap: () => _copyRoleCardSummary(context),
          ),
          _navTile(
            context,
            icon: Icons.dashboard_customize_outlined,
            title: '保存为会话模板',
            subtitle: '复用当前角色、模型、工具和开场白',
            onTap: () => _saveAsWorkflowTemplate(context),
          ),
          _section(context, '角色卡', [
            _kv('系统提示词', '${summary.promptChars} 字'),
            _kv('开场白',
                summary.openingChars == 0 ? '无' : '${summary.openingChars} 字'),
            if (assistant.openingMessage.trim().isNotEmpty)
              _textPreview('开场白内容', assistant.openingMessage, maxLines: 4),
            _kv(
                '示例对话',
                summary.exampleDialogLines == 0
                    ? '无'
                    : '${summary.exampleDialogLines} 行'),
            if (AssistantRoleCardService.exampleDialogPromptText(
                    assistant.exampleDialogs)
                .isNotEmpty)
              _textPreview(
                '示例对话内容',
                AssistantRoleCardService.exampleDialogPromptText(
                  assistant.exampleDialogs,
                ),
                maxLines: 8,
              ),
            if (summary.alternateGreetingCount > 0)
              _kv('备选开场', '${summary.alternateGreetingCount} 条'),
            if (alternateGreetings.isNotEmpty)
              _alternateGreetingPreview(alternateGreetings),
            _kv(
                '模型覆盖',
                summary.hasModelOverride
                    ? [
                        if (assistant.providerId.trim().isNotEmpty)
                          assistant.providerId.trim(),
                        if (assistant.model.trim().isNotEmpty)
                          assistant.model.trim(),
                      ].join(' / ')
                    : '跟随全局'),
            _kv(
                '默认语音',
                summary.hasDefaultVoice
                    ? assistant.defaultVoiceStyle.trim()
                    : '跟随会话'),
          ]),
          _navTile(
            context,
            icon: Icons.menu_book_outlined,
            title: '世界书',
            subtitle: _worldBookSummaryText(summary),
            onTap: () => _openWorldBook(context),
          ),
          if (summary.memoryEntries.isNotEmpty)
            _section(context, '世界书预览', [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _copyWorldBookSummary(context),
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制世界书摘要'),
                ),
              ),
              for (final entry in summary.memoryEntries.take(3))
                _memoryEntryPreview(entry),
              if (summary.memoryEntries.length > 3)
                Text(
                  '还有 ${summary.memoryEntries.length - 3} 条可在世界书中查看',
                  style: const TextStyle(fontSize: 12, color: Colors.black45),
                ),
            ]),
          _navTile(
            context,
            icon: Icons.psychology_alt_outlined,
            title: '长期记忆',
            subtitle: _memorySummaryText(memories),
            onTap: () => _openMemories(context),
          ),
          if (memories.isNotEmpty)
            _section(context, '最近长期记忆', [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _copyLongTermMemorySummary(context),
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制长期记忆摘要'),
                ),
              ),
              for (final memory in memories.take(5))
                _longTermMemoryPreview(memory),
            ]),
          _section(context, '工具', [
            _kv('工具开关', assistant.useTools ? '开启' : '关闭'),
            _kv(
                '绑定工具',
                (assistant.toolIds ?? const []).isEmpty
                    ? '无'
                    : assistant.toolIds!.join(' / ')),
          ]),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  String _worldBookSummaryText(AssistantRoleCardSummary summary) {
    if (summary.memoryCount == 0) return '未配置';
    final parts = <String>[
      '常驻 ${summary.alwaysOnMemoryCount}',
      '关键词 ${summary.keywordMemoryCount}',
      if (summary.disabledMemoryCount > 0) '禁用 ${summary.disabledMemoryCount}',
    ];
    return '${summary.memoryCount} 条（${parts.join(' / ')}）';
  }

  String _memorySummaryText(List<AssistantMemoryModel> memories) {
    if (memories.isEmpty) return '未保存';
    final manualCount =
        memories.where((memory) => memory.source == 'manual').length;
    final suggestionCount =
        memories.where((memory) => memory.source == 'suggestion').length;
    final conversationCount = memories.length - manualCount - suggestionCount;
    final parts = <String>[
      '手动 $manualCount',
      if (suggestionCount > 0) '自动建议 $suggestionCount',
      if (conversationCount > 0) '对话 $conversationCount',
    ];
    return '${memories.length} 条最近记忆（${parts.join(' / ')}）';
  }

  String _roleCardImpactText(AssistantRoleCardSummary summary) {
    if (summary.promptChars == 0) return '系统提示词未配置';
    return '系统提示词 ${summary.promptChars} 字会注入';
  }

  String _worldBookImpactText(AssistantRoleCardSummary summary) {
    if (summary.memoryCount == 0) return '未配置';
    final parts = <String>[
      if (summary.alwaysOnMemoryCount > 0)
        '常驻 ${summary.alwaysOnMemoryCount} 条会注入',
      if (summary.keywordMemoryCount > 0)
        '关键词 ${summary.keywordMemoryCount} 条按用户输入命中',
      if (summary.disabledMemoryCount > 0)
        '禁用 ${summary.disabledMemoryCount} 条不注入',
    ];
    return parts.join('，');
  }

  String _roleStateImpactText() {
    return _roleStateSummary() == '未设置' ? '未设置' : '会注入当前会话状态';
  }

  String _longTermMemoryImpactText(List<AssistantMemoryModel> memories) {
    if (memories.isEmpty) return '未保存';
    return '最近 ${memories.length} 条会注入';
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.black54)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _memoryEntryPreview(AssistantMemoryEntryPreview entry) {
    final color = entry.enabled ? Colors.black87 : Colors.black38;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        AssistantRoleCardService.memoryHitPreviewLine(entry),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          height: 1.35,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _longTermMemoryPreview(AssistantMemoryModel memory) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _memorySourceLabel(memory),
            style: const TextStyle(
              fontSize: 12,
              color: Colors.black45,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _normalizeMemoryText(memory.content),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _alternateGreetingPreview(List<String> greetings) {
    final visible = greetings.take(3).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '备选开场内容',
            style: TextStyle(fontSize: 12, color: Colors.black45),
          ),
          const SizedBox(height: 4),
          for (final greeting in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                greeting,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ),
          if (greetings.length > visible.length)
            Text(
              '还有 ${greetings.length - visible.length} 条未展示',
              style: const TextStyle(fontSize: 12, color: Colors.black38),
            ),
        ],
      ),
    );
  }

  String _memorySourceLabel(AssistantMemoryModel memory) {
    return switch (memory.source) {
      'user_message' => '来自用户消息',
      'reply' => '来自助手回复',
      'suggestion' => '来自自动建议',
      _ => '手动添加',
    };
  }

  Widget _textPreview(String label, String value, {required int maxLines}) {
    final text = value.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 78, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black45),
          ),
          const SizedBox(height: 3),
          Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  Widget _avatar(AssistantModel assistant) {
    return AssistantAvatar(assistant: assistant, radius: 28);
  }

  void _openEdit(BuildContext context) async {
    final openEditor = widget.openEditor;
    if (openEditor == null) {
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => AssistantEditPage(assistant: widget.assistant)),
      );
    } else {
      await openEditor(context, widget.assistant);
    }
    if (!mounted) return;
    setState(() {});
  }

  void _openWorldBook(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AssistantWorldBookPage(
                assistant: widget.assistant,
                onSave: widget.worldBookSaver,
              )),
    );
    if (!mounted) return;
    setState(() {});
  }

  void _openMemories(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AssistantMemoryPage(
                assistant: widget.assistant,
                dao: widget.memoryDao,
              )),
    );
    await _reloadMemories();
  }

  String _roleStateSummary() {
    final values = [
      _roleScene?.trim(),
      _roleRelationship?.trim(),
      _roleToneNote?.trim(),
    ].where((e) => e != null && e.isNotEmpty).cast<String>().toList();
    if (values.isEmpty) return '未设置';
    return values.join(' / ');
  }

  bool _hasRoleState() {
    return [_roleScene, _roleRelationship, _roleToneNote]
        .any((value) => value != null && value.trim().isNotEmpty);
  }

  Future<void> _editRoleState(BuildContext context) async {
    final conversation = widget.conversation;
    final save = widget.onSaveRoleState;
    if (conversation == null || save == null) return;
    final result = await showDialog<_RoleStateDraft>(
      context: context,
      builder: (_) => _RoleStateDialog(
        scene: _roleScene ?? '',
        relationship: _roleRelationship ?? '',
        toneNote: _roleToneNote ?? '',
        suggested: widget.suggestedRoleState,
      ),
    );
    if (result == null) return;
    final roleScene = _emptyToNull(result.scene);
    final roleRelationship = _emptyToNull(result.relationship);
    final roleToneNote = _emptyToNull(result.toneNote);
    await save(
      roleScene: roleScene,
      roleRelationship: roleRelationship,
      roleToneNote: roleToneNote,
    );
    if (!mounted) return;
    setState(() {
      _roleScene = roleScene;
      _roleRelationship = roleRelationship;
      _roleToneNote = roleToneNote;
    });
  }

  String? _emptyToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  void _showContextPreview(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ContextPreviewSheet(
        buildPreview: _buildContextPreview,
        buildMatchSummary: _buildContextMatchSummary,
        buildMatchedWorldBook: _buildMatchedWorldBookText,
      ),
    );
  }

  Future<void> _copyRoleCardSummary(BuildContext context) async {
    final text = _buildRoleCardSummary().trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('角色卡摘要已复制')),
    );
  }

  Future<void> _copyContextImpactSummary(BuildContext context) async {
    final text = _buildContextImpactSummary().trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('上下文影响摘要已复制')),
    );
  }

  Future<void> _copyWorldBookSummary(BuildContext context) async {
    final text = _buildWorldBookSummary().trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('世界书摘要已复制')),
    );
  }

  Future<void> _copyLongTermMemorySummary(BuildContext context) async {
    final text = _buildLongTermMemorySummary().trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('长期记忆摘要已复制')),
    );
  }

  Future<void> _copyRoleStateSummary(BuildContext context) async {
    final text = _buildRoleStateSummary().trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('会话状态摘要已复制')),
    );
  }

  Future<void> _saveAsWorkflowTemplate(BuildContext context) async {
    final template = _buildWorkflowTemplate();
    try {
      final saver = widget.saveWorkflowTemplate;
      if (saver == null) {
        await const WorkflowTemplateStore().add(template);
      } else {
        await saver(template);
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存到会话模板')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存会话模板失败：$e')),
      );
    }
  }

  WorkflowTemplate _buildWorkflowTemplate() {
    final assistant = widget.assistant;
    final name =
        assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
    final toolIds = assistant.useTools
        ? [...(assistant.toolIds ?? const <String>[])]
        : const <String>[];
    return WorkflowTemplate(
      id: '${_templateIdBase(name)}_${DateTime.now().millisecondsSinceEpoch}',
      title: '$name · 角色场景',
      category: '角色场景',
      projectName: '$name 角色场景',
      assistantName: name,
      providerCode: _emptyToNull(assistant.providerId),
      modelId: _emptyToNull(assistant.model),
      toolIds: toolIds,
      systemPrompt: assistant.prompt.trim(),
      firstUserPrompt: _templateFirstUserPrompt(name),
    );
  }

  String _templateFirstUserPrompt(String name) {
    final opening = widget.assistant.openingMessage.trim();
    final alternateGreetings = AssistantRoleCardService.alternateGreetings(
      widget.assistant.exampleDialogs,
    );
    final lines = <String>[
      '请以「$name」的角色设定开始本场景。',
      if (opening.isNotEmpty) ...[
        '角色开场白：',
        opening,
      ] else
        '请先给出一句自然的开场白。',
      if (alternateGreetings.isNotEmpty) ...[
        '',
        '可选备选开场白：',
        for (final greeting in alternateGreetings) '- $greeting',
      ],
    ];
    return lines.join('\n');
  }

  String _templateIdBase(String name) {
    final normalized = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return normalized.isEmpty ? 'role_scene' : 'role_scene_$normalized';
  }

  String _buildContextImpactSummary() {
    final assistant = widget.assistant;
    final summary = AssistantRoleCardService.summarize(assistant);
    final name =
        assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
    return [
      '# $name · 下一轮上下文影响',
      '角色卡：${_roleCardImpactText(summary)}',
      '世界书：${_worldBookImpactText(summary)}',
      '会话状态：${_roleStateImpactText()}',
      '长期记忆：${_longTermMemoryImpactText(_memories)}',
    ].join('\n');
  }

  String _buildRoleStateSummary() {
    if (!_hasRoleState()) return '';
    final assistant = widget.assistant;
    final name =
        assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
    return ConversationModel(
      cid: widget.conversation?.cid ?? 0,
      icon: widget.conversation?.icon ?? '',
      roleScene: _roleScene,
      roleRelationship: _roleRelationship,
      roleToneNote: _roleToneNote,
    ).roleStateCopyText(title: '$name · 当前会话状态');
  }

  String _buildLongTermMemorySummary() {
    if (_memories.isEmpty) return '';
    final assistant = widget.assistant;
    final name =
        assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
    return [
      '# $name · 最近长期记忆',
      _memorySummaryText(_memories),
      for (final memory in _memories)
        '- ${_memorySourceLabel(memory)}：${_normalizeMemoryText(memory.content)}',
    ].join('\n');
  }

  String _buildWorldBookSummary() {
    final assistant = widget.assistant;
    final summary = AssistantRoleCardService.summarize(assistant);
    if (summary.memoryEntries.isEmpty) return '';
    final name =
        assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
    return [
      '# $name · 世界书',
      _worldBookSummaryText(summary),
      for (final entry in summary.memoryEntries)
        '- ${AssistantRoleCardService.memoryEntryCopyLine(entry)}',
    ].join('\n');
  }

  String _buildRoleCardSummary() {
    final assistant = widget.assistant;
    final summary = AssistantRoleCardService.summarize(assistant);
    final buffer = StringBuffer()
      ..writeln(
          '# ${assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim()}');
    final description = assistant.description.trim();
    if (description.isNotEmpty) buffer.writeln('\n简介：$description');
    final prompt = assistant.prompt.trim();
    if (prompt.isNotEmpty) buffer.writeln('\n[系统提示词]\n$prompt');
    final opening = assistant.openingMessage.trim();
    if (opening.isNotEmpty) buffer.writeln('\n[开场白]\n$opening');
    final examples = AssistantRoleCardService.exampleDialogPromptText(
        assistant.exampleDialogs);
    if (examples.isNotEmpty) buffer.writeln('\n[示例对话]\n$examples');
    final alternateGreetings =
        AssistantRoleCardService.alternateGreetings(assistant.exampleDialogs);
    if (alternateGreetings.isNotEmpty) {
      buffer.writeln('\n[备选开场白]');
      for (final greeting in alternateGreetings) {
        buffer.writeln(greeting);
      }
    }
    if (summary.memoryEntries.isNotEmpty) {
      buffer.writeln('\n[世界书]');
      for (final entry in summary.memoryEntries) {
        buffer.writeln(
            '- ${AssistantRoleCardService.memoryEntryCopyLine(entry)}');
      }
    }
    final voice = assistant.defaultVoiceStyle.trim();
    if (voice.isNotEmpty) buffer.writeln('\n默认语音：$voice');
    final modelParts = [
      if (assistant.providerId.trim().isNotEmpty) assistant.providerId.trim(),
      if (assistant.model.trim().isNotEmpty) assistant.model.trim(),
    ];
    if (modelParts.isNotEmpty) buffer.writeln('模型覆盖：${modelParts.join(' / ')}');
    final toolIds = assistant.toolIds ?? const <String>[];
    if (assistant.useTools && toolIds.isNotEmpty) {
      buffer.writeln('工具：${toolIds.join(' / ')}');
    }
    return buffer.toString();
  }

  String _normalizeMemoryText(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _buildContextPreview(String userInput) {
    final base = widget.assistant.systemPromptFor(userInput).trim();
    final roleState = ConversationModel(
      cid: widget.conversation?.cid ?? 0,
      icon: widget.conversation?.icon ?? '',
      roleScene: _roleScene,
      roleRelationship: _roleRelationship,
      roleToneNote: _roleToneNote,
    ).roleStateContext();
    final memory = AssistantMemoryDao.buildSystemContext(_memories);
    final parts = [
      if (base.isNotEmpty) base,
      if (roleState.isNotEmpty) roleState,
      if (memory.isNotEmpty) memory,
    ];
    return parts.isEmpty ? '暂无可注入上下文' : parts.join('\n\n');
  }

  String _buildContextMatchSummary(String userInput) {
    final summary = AssistantRoleCardService.summarize(widget.assistant);
    if (summary.memoryCount == 0) return '世界书未配置';
    final matched = AssistantRoleCardService.matchMemoryEntries(
      widget.assistant.memoryBook,
      userInput,
      maxEntries: 50,
    );
    if (matched.isEmpty) return '当前输入未命中世界书';
    final previewLines = matched.take(3).map((entry) {
      return AssistantRoleCardService.memoryHitPreviewLine(entry);
    }).join('；');
    final remaining = matched.length > 3 ? '；还有 ${matched.length - 3} 条' : '';
    final hitSummary = AssistantRoleCardService.memoryHitSummary(matched)
        .replaceFirst('命中角色记忆', '当前输入会注入世界书');
    return '$hitSummary\n命中：$previewLines$remaining';
  }

  String _buildMatchedWorldBookText(String userInput) {
    final matched = AssistantRoleCardService.matchMemoryEntries(
      widget.assistant.memoryBook,
      userInput,
      maxEntries: 50,
    );
    if (matched.isEmpty) return '';
    final name = widget.assistant.name.trim().isEmpty
        ? '未命名角色'
        : widget.assistant.name.trim();
    final hitSummary = AssistantRoleCardService.memoryHitSummary(matched)
        .replaceFirst('命中角色记忆', '当前输入会注入世界书');
    return [
      '# $name · 命中世界书',
      hitSummary,
      for (final entry in matched)
        '- ${AssistantRoleCardService.memoryEntryCopyLine(entry)}',
    ].join('\n');
  }

  Future<void> _reloadMemories() async {
    final assistantId = widget.assistant.id;
    if (assistantId == null) return;
    final dao = widget.memoryDao ?? await _createMemoryDao();
    final memories = await dao.getMemories(assistantId, limit: 8);
    if (!mounted) return;
    setState(() => _memories = memories);
  }

  Future<IAssistantMemory> _createMemoryDao() async {
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    return AssistantMemoryDao.create(dbManager);
  }
}

class _RoleStateDraft {
  final String scene;
  final String relationship;
  final String toneNote;

  const _RoleStateDraft({
    required this.scene,
    required this.relationship,
    required this.toneNote,
  });
}

class _RoleStateDialog extends StatefulWidget {
  final String scene;
  final String relationship;
  final String toneNote;
  final ConversationRoleStateDraft? suggested;

  const _RoleStateDialog({
    required this.scene,
    required this.relationship,
    required this.toneNote,
    this.suggested,
  });

  @override
  State<_RoleStateDialog> createState() => _RoleStateDialogState();
}

class _RoleStateDialogState extends State<_RoleStateDialog> {
  late final TextEditingController _sceneCtl;
  late final TextEditingController _relationshipCtl;
  late final TextEditingController _toneCtl;

  @override
  void initState() {
    super.initState();
    _sceneCtl = TextEditingController(text: widget.scene);
    _relationshipCtl = TextEditingController(text: widget.relationship);
    _toneCtl = TextEditingController(text: widget.toneNote);
  }

  @override
  void dispose() {
    _sceneCtl.dispose();
    _relationshipCtl.dispose();
    _toneCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('当前会话状态'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.suggested != null && !widget.suggested!.isEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _applySuggested,
                  icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                  label: const Text('从最近对话填入'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _sceneCtl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '当前场景',
                hintText: '例如：雨夜的旧书店，刚刚重逢',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _relationshipCtl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '关系备注',
                hintText: '例如：熟悉但仍保持距离',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _toneCtl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '语气备注',
                hintText: '例如：克制、温柔，避免过度解释',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            const _RoleStateDraft(scene: '', relationship: '', toneNote: ''),
          ),
          child: const Text('清空'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _RoleStateDraft(
              scene: _sceneCtl.text,
              relationship: _relationshipCtl.text,
              toneNote: _toneCtl.text,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _applySuggested() {
    final suggested = widget.suggested;
    if (suggested == null) return;
    setState(() {
      _sceneCtl.text = suggested.scene;
      _relationshipCtl.text = suggested.relationship;
      _toneCtl.text = suggested.toneNote;
    });
  }
}

class _ContextPreviewSheet extends StatefulWidget {
  final String Function(String userInput) buildPreview;
  final String Function(String userInput) buildMatchSummary;
  final String Function(String userInput) buildMatchedWorldBook;

  const _ContextPreviewSheet({
    required this.buildPreview,
    required this.buildMatchSummary,
    required this.buildMatchedWorldBook,
  });

  @override
  State<_ContextPreviewSheet> createState() => _ContextPreviewSheetState();
}

class _ContextPreviewSheetState extends State<_ContextPreviewSheet> {
  late final TextEditingController _inputCtl;

  @override
  void initState() {
    super.initState();
    _inputCtl = TextEditingController();
    _inputCtl.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _inputCtl
      ..removeListener(_onInputChanged)
      ..dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final preview = widget.buildPreview(_inputCtl.text);
    final matchSummary = widget.buildMatchSummary(_inputCtl.text);
    final matchedWorldBook = widget.buildMatchedWorldBook(_inputCtl.text);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '上下文预览',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '复制上下文',
                  onPressed: preview.trim().isEmpty
                      ? null
                      : () => _copyPreview(context, preview),
                  icon: const Icon(Icons.copy_outlined),
                ),
                IconButton(
                  tooltip: '复制命中世界书',
                  onPressed: matchedWorldBook.trim().isEmpty
                      ? null
                      : () => _copyMatchedWorldBook(context, matchedWorldBook),
                  icon: const Icon(Icons.menu_book_outlined),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _inputCtl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '模拟用户输入',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              matchSummary,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.58,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  preview,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyPreview(BuildContext context, String preview) async {
    final text = preview.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('上下文已复制')),
    );
  }

  Future<void> _copyMatchedWorldBook(
    BuildContext context,
    String matchedWorldBook,
  ) async {
    final text = matchedWorldBook.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('命中世界书已复制')),
    );
  }
}
