import 'dart:io';

import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

///助手新建 / 编辑页（阶段七）：名称、emoji、系统提示词、可选模型覆盖、工具开关。
///对应源项目 `src/screens/assistant/AssistantDetailScreen.tsx` 的精简版。
class AssistantEditPage extends StatefulWidget {
  ///null = 新建。
  final AssistantModel? assistant;

  const AssistantEditPage({super.key, this.assistant});

  @override
  State<AssistantEditPage> createState() => _AssistantEditPageState();
}

class _EditablePromptParts {
  final String prompt;
  final String personality;
  final String scenario;

  const _EditablePromptParts({
    required this.prompt,
    required this.personality,
    required this.scenario,
  });
}

class _AssistantEditPageState extends State<AssistantEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _emojiCtl;
  late final TextEditingController _promptCtl;
  late final TextEditingController _personalityCtl;
  late final TextEditingController _scenarioCtl;
  late final TextEditingController _descriptionCtl;
  late final TextEditingController _openingMessageCtl;
  late final TextEditingController _exampleDialogsCtl;
  late final TextEditingController _memoryBookCtl;

  ///模型覆盖（'' = 跟随全局设置）。
  String _providerId = '';
  String _model = '';
  String _defaultVoiceStyle = '';
  String? _avatarType;
  String? _avatarValue;
  bool _useTools = true;
  List<UserSherpaOnnxTtsModel> _userVoiceModels = const [];
  final _imagePicker = ImagePicker();

  /// 助手绑定的工具 id 集合（L1）。旧助手 toolIds 为 null 时按空集处理，
  /// 保存后变为显式列表（语义不变：未勾选 = 不绑定）。MCP 工具名（mcp__…）
  /// 也存进同一集合，与内置工具一视同仁（item 5）。
  late final Set<String> _toolIds;
  bool _saving = false;

  /// MCP 工具发现（item 5）：缓存 Future，避免每次 rebuild 重新发现。
  Future<List<McpToolBindSpec>>? _mcpSpecs;

  /// 「新建」以是否已有持久化 id 判定：从助手市场预填的模板 id 为 null，
  /// 同样视为新建（保存即插入），标题/按钮显示「新建/创建」（遗留项 9）。
  bool get _isNew => widget.assistant?.id == null;

  static final RegExp _tavernPromptSectionHeader =
      RegExp(r'^\[(系统提示|角色设定|性格|场景|后续指令)\]\s*$');

  @override
  void initState() {
    super.initState();
    final a = widget.assistant;
    final promptParts = _splitEditablePromptSections(a?.prompt ?? '');
    _nameCtl = TextEditingController(text: a?.name ?? '');
    _emojiCtl = TextEditingController(text: a?.emoji ?? '🤖');
    _promptCtl = TextEditingController(text: promptParts.prompt);
    _personalityCtl = TextEditingController(text: promptParts.personality);
    _scenarioCtl = TextEditingController(text: promptParts.scenario);
    _descriptionCtl = TextEditingController(text: a?.description ?? '');
    _openingMessageCtl = TextEditingController(text: a?.openingMessage ?? '');
    _exampleDialogsCtl = TextEditingController(text: a?.exampleDialogs ?? '');
    _memoryBookCtl = TextEditingController(text: a?.memoryBook ?? '');
    _providerId = a?.providerId ?? '';
    _model = a?.model ?? '';
    _defaultVoiceStyle = a?.defaultVoiceStyle ?? '';
    _avatarType = a?.avatarType;
    _avatarValue = a?.avatarValue;
    _useTools = a?.useTools ?? true;
    _toolIds = {...?a?.toolIds};
    _loadUserVoiceModels();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _emojiCtl.dispose();
    _promptCtl.dispose();
    _personalityCtl.dispose();
    _scenarioCtl.dispose();
    _descriptionCtl.dispose();
    _openingMessageCtl.dispose();
    _exampleDialogsCtl.dispose();
    _memoryBookCtl.dispose();
    super.dispose();
  }

  static _EditablePromptParts _splitEditablePromptSections(String raw) {
    final baseLines = <String>[];
    final personalityLines = <String>[];
    final scenarioLines = <String>[];

    String? currentSection;
    var buffer = <String>[];

    void appendLines(List<String> target, List<String> lines) {
      final text = _trimLines(lines);
      if (text.isEmpty) return;
      if (target.isNotEmpty) target.add('');
      target.addAll(text.split('\n'));
    }

    void flush() {
      if (currentSection == '性格') {
        appendLines(personalityLines, buffer);
      } else if (currentSection == '场景') {
        appendLines(scenarioLines, buffer);
      } else {
        if (currentSection != null) {
          if (baseLines.isNotEmpty) baseLines.add('');
          baseLines.add('[$currentSection]');
        }
        appendLines(baseLines, buffer);
      }
      buffer = <String>[];
    }

    for (final rawLine in raw.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final match = _tavernPromptSectionHeader.firstMatch(line.trim());
      if (match == null) {
        buffer.add(line);
        continue;
      }
      flush();
      currentSection = match.group(1);
    }
    flush();

    return _EditablePromptParts(
      prompt: _trimLines(baseLines),
      personality: _trimLines(personalityLines),
      scenario: _trimLines(scenarioLines),
    );
  }

  static String _composePromptWithEditableSections({
    required String prompt,
    required String personality,
    required String scenario,
  }) {
    final parts = <String>[
      prompt.trim(),
      if (personality.trim().isNotEmpty) '[性格]\n${personality.trim()}',
      if (scenario.trim().isNotEmpty) '[场景]\n${scenario.trim()}',
    ].where((part) => part.isNotEmpty).toList();
    return parts.join('\n\n').trim();
  }

  static String _trimLines(List<String> lines) => lines.join('\n').trim();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建助手' : '编辑助手'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
        children: [
          _buildIdentitySection(),
          const SizedBox(height: 12),
          _section(
            icon: Icons.psychology_alt_outlined,
            title: '核心人设',
            subtitle: '决定助手如何思考、说话和行动',
            child: Column(
              children: [
                _textArea(
                  controller: _promptCtl,
                  label: '系统提示词',
                  hint: '定义助手的人设与行为，发请求时作为 system 消息注入',
                  minLines: 5,
                  maxLines: 12,
                ),
                const SizedBox(height: 12),
                _textArea(
                  controller: _personalityCtl,
                  label: '性格',
                  hint: 'Tavern personality 字段，如：冷静、毒舌、外冷内热',
                  minLines: 2,
                  maxLines: 6,
                ),
                const SizedBox(height: 12),
                _textArea(
                  controller: _scenarioCtl,
                  label: '场景',
                  hint: 'Tavern scenario 字段，如：当前故事发生的地点、关系和开局处境',
                  minLines: 2,
                  maxLines: 6,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _advancedTile(
            icon: Icons.waving_hand_outlined,
            title: '开场与示例',
            subtitle: '固定第一印象、语气和回答风格',
            children: [
              _textArea(
                controller: _openingMessageCtl,
                label: '开场白',
                hint: '新会话开始时展示给用户的第一句话',
                minLines: 2,
                maxLines: 5,
              ),
              const SizedBox(height: 12),
              _textArea(
                controller: _exampleDialogsCtl,
                label: '示例对话',
                hint: '可填写 1-2 组示例，帮助固定角色语气',
                minLines: 3,
                maxLines: 8,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _advancedTile(
            icon: Icons.menu_book_outlined,
            title: '关键词记忆 / 世界书',
            subtitle: '按关键词注入设定，适合角色卡和创作模式',
            children: [
              _textArea(
                controller: _memoryBookCtl,
                label: '世界书条目',
                hint: '每行：关键词1,关键词2 => 设定内容\n未写箭头的行会作为常驻设定注入',
                minLines: 4,
                maxLines: 10,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _advancedTile(
            icon: Icons.tune_outlined,
            title: '模型与语音',
            subtitle: '需要单独指定服务商、模型或朗读声音时再调整',
            children: [
              _buildVoiceStyleDropdown(),
              _buildProviderDropdown(),
              _buildModelDropdown(),
            ],
          ),
          const SizedBox(height: 12),
          _advancedTile(
            icon: Icons.extension_outlined,
            title: '工具能力',
            subtitle: _useTools ? '已允许工具调用' : '工具调用已关闭',
            initiallyExpanded: _useTools && _toolIds.isNotEmpty,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('允许工具调用'),
                subtitle: const Text('关闭后此助手不会调用工具；联网能力走普通编排'),
                value: _useTools,
                onChanged: (v) => setState(() => _useTools = v),
              ),
              if (_useTools) _buildToolsSection(),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(top: BorderSide(color: Colors.grey.shade200)),
          ),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_isNew ? '创建助手' : '保存修改'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIdentitySection() {
    return _section(
      icon: Icons.badge_outlined,
      title: '身份信息',
      subtitle: '头像、名称和用户能看到的简介',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 360;
          final fields = Column(
            children: [
              TextField(
                controller: _nameCtl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '如：剧情导演 / 代码审查员',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.drive_file_rename_outline),
                ),
              ),
              const SizedBox(height: 12),
              _textArea(
                controller: _descriptionCtl,
                label: '角色简介',
                hint: '给用户看的简短介绍，如：温柔但严格的英语口语陪练',
                minLines: 2,
                maxLines: 4,
              ),
            ],
          );
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildAvatarEditor(expanded: true),
                const SizedBox(height: 12),
                fields,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAvatarEditor(),
              const SizedBox(width: 14),
              Expanded(child: fields),
            ],
          );
        },
      ),
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader(icon: icon, title: title, subtitle: subtitle),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _advancedTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          leading: Icon(icon),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle:
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          children: children,
        ),
      ),
    );
  }

  Widget _sectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: Theme.of(context).primaryColor),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _textArea({
    required TextEditingController controller,
    required String label,
    required String hint,
    required int minLines,
    required int maxLines,
  }) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      style: const TextStyle(fontSize: 15, height: 1.35),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintMaxLines: 3,
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
        floatingLabelBehavior: FloatingLabelBehavior.auto,
        contentPadding: const EdgeInsets.fromLTRB(12, 24, 12, 14),
      ),
    );
  }

  Widget _buildAvatarEditor({bool expanded = false}) {
    final hasImage = _avatarType == AvatarAssetService.imageType &&
        (_avatarValue?.trim().isNotEmpty ?? false);
    final colorScheme = Theme.of(context).colorScheme;
    final emoji = _emojiCtl.text.trim().isEmpty ? '🤖' : _emojiCtl.text.trim();
    return SizedBox(
      width: expanded ? double.infinity : 148,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomRight,
                children: [
                  Semantics(
                    label: '助手头像预览',
                    image: true,
                    child: AssistantAvatar.raw(
                      emoji: emoji,
                      avatarType: _avatarType,
                      avatarValue: _avatarValue,
                      radius: expanded ? 40 : 34,
                    ),
                  ),
                  Tooltip(
                    message: '上传头像',
                    child: Semantics(
                      button: true,
                      label: '上传头像图片',
                      child: Material(
                        color: colorScheme.primary,
                        shape: const CircleBorder(),
                        elevation: 1,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _pickAvatarImage,
                          child: const SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(
                              Icons.photo_camera_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                hasImage ? '图片头像' : 'Emoji 头像',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _emojiCtl,
                textAlign: TextAlign.center,
                maxLength: 2,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Emoji',
                  helperText: hasImage ? '删除图片后显示' : '未上传图片时显示',
                  counterText: '',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pickAvatarImage,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(hasImage ? '更换图片' : '上传图片'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ),
              if (hasImage) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: _removeAvatarImage,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除图片'),
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.error,
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 服务商覆盖下拉（仅本地模式）：''=跟随全局，非空表示固定服务商。
  Widget _buildProviderDropdown() {
    final settings = context.watch<AISettingsProvider>().settings;
    if (settings.mode == AIMode.backend) {
      return const SizedBox.shrink();
    }

    final providers = [
      for (final p in settings.providers.where((p) => p.enabled))
        DropdownMenuItem(
          value: p.id,
          child: Text(p.name.isEmpty ? p.id : p.name),
        )
    ];
    final value =
        providers.any((item) => item.value == _providerId) ? _providerId : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '服务商覆盖（可选）',
          border: OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isDense: true,
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('跟随全局服务商',
                    style: TextStyle(fontWeight: FontWeight.w500)),
              ),
              ...providers,
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _providerId = v;
                if (_model.isNotEmpty &&
                    !_modelInCurrentProvider(v, settings)) {
                  _model = '';
                }
              });
            },
          ),
        ),
      ),
    );
  }

  List<ModelOption> _modelOptionsOfActiveProvider(AISettings settings) {
    if (settings.mode == AIMode.backend) {
      return ModelCatalog.backendAll();
    }
    final targetId =
        _providerId.trim().isEmpty ? settings.activeProvider.id : _providerId;
    for (final p in settings.providers) {
      if (p.id == targetId) {
        return p.models
            .map((m) => ModelOption(m.id, m.description, displayLabel: m.name))
            .toList();
      }
    }
    return settings.activeProvider.models
        .map((m) => ModelOption(m.id, m.description, displayLabel: m.name))
        .toList();
  }

  bool _modelInCurrentProvider(String providerId, AISettings settings) {
    final pid =
        providerId.trim().isEmpty ? settings.activeProvider.id : providerId;
    final models = _providerModels(settings, pid);
    if (models.any((m) => m.id == _model)) {
      return true;
    }
    return false;
  }

  List<ModelOption> _providerModels(AISettings settings, String providerId) {
    for (final p in settings.providers) {
      if (p.id == providerId) {
        return p.models
            .map((m) => ModelOption(m.id, m.description, displayLabel: m.name))
            .toList();
      }
    }
    return settings.activeProvider.models
        .map((m) => ModelOption(m.id, m.description, displayLabel: m.name))
        .toList();
  }

  Widget _buildVoiceStyleDropdown() {
    final validUserVoice = _userVoiceModels
        .any((model) => model.voiceStyleId == _defaultVoiceStyle);
    final value = _defaultVoiceStyle.isEmpty ||
            TtsVoiceStyle.isValid(_defaultVoiceStyle) ||
            validUserVoice
        ? _defaultVoiceStyle
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '默认朗读声音（可选）',
          border: OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isDense: true,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: '', child: Text('跟随会话语音偏好')),
              for (final style in TtsVoiceStyle.all)
                DropdownMenuItem(value: style.id, child: Text(style.label)),
              for (final model in _userVoiceModels)
                DropdownMenuItem(
                  value: model.voiceStyleId,
                  child: Text('用户模型：${model.title}'),
                ),
            ],
            onChanged: (v) => setState(() => _defaultVoiceStyle = v ?? ''),
          ),
        ),
      ),
    );
  }

  /// 工具绑定多选（L1）：列出 [ToolRegistry.catalog]，勾选即写入助手 toolIds。
  /// 依赖搜索 key 的工具在未配置时置灰并提示；只有支持工具的模型 + 流式才会真正生效。
  Widget _buildToolsSection() {
    final settings = context.watch<AISettingsProvider>().settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 4),
          child: Text('可用工具（绑定后该助手始终向模型暴露）',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        for (final d in ToolRegistry.catalog)
          _buildToolTile(d, ToolRegistry.isAvailable(settings, d.id)),
        if (settings.mcpConfigured) _buildMcpToolsSection(settings),
      ],
    );
  }

  /// MCP 工具绑定（item 5）：发现当前设置下的 MCP 工具，勾选写入 toolIds。
  /// 未勾选的 MCP 工具不会暴露给该助手（与内置工具一致）。
  Widget _buildMcpToolsSection(AISettings settings) {
    _mcpSpecs ??= McpToolSource.listSpecs(settings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 4),
          child: Text('MCP 工具（来自已配置的 MCP 服务）',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        FutureBuilder<List<McpToolBindSpec>>(
          future: _mcpSpecs,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('正在发现 MCP 工具…',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ]),
              );
            }
            if (snap.hasError) {
              return Text('MCP 工具发现失败：${snap.error}',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.redAccent));
            }
            final specs = snap.data ?? const [];
            if (specs.isEmpty) {
              return const Text('未发现可用的 MCP 工具',
                  style: TextStyle(fontSize: 12, color: Colors.grey));
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final spec in specs) _buildMcpToolTile(spec)],
            );
          },
        ),
      ],
    );
  }

  Widget _buildMcpToolTile(McpToolBindSpec spec) {
    final selected = _toolIds.contains(spec.name);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Row(
        children: [
          const Icon(Icons.extension, size: 14, color: Colors.blueGrey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(spec.name,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      subtitle:
          spec.description.isEmpty ? null : Text(spec.description, maxLines: 2),
      onChanged: (v) => setState(() {
        if (v == true) {
          _toolIds.add(spec.name);
        } else {
          _toolIds.remove(spec.name);
        }
      }),
    );
  }

  Widget _buildToolTile(ToolDescriptor d, bool available) {
    final selected = _toolIds.contains(d.id);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Row(
        children: [
          Text(d.label),
          if (d.sideEffect)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.edit_note, size: 16, color: Colors.orange),
            ),
        ],
      ),
      subtitle: Text(
          available ? d.description : '${d.description}（需先在 AI 设置里配置搜索 key）'),
      // 未满足依赖时禁用勾选。
      onChanged: available
          ? (v) => setState(() {
                if (v == true) {
                  _toolIds.add(d.id);
                } else {
                  _toolIds.remove(d.id);
                }
              })
          : null,
    );
  }

  ///模型覆盖下拉：选项按当前全局设置的生效路径给（后端模式 -> 后端清单，
  ///本地模式 -> 当前服务商清单），保证覆盖的模型与服务商兼容。
  Widget _buildModelDropdown() {
    final settings = context.watch<AISettingsProvider>().settings;
    final options = _modelOptionsOfActiveProvider(settings);

    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: '',
        child: Text('跟随全局设置', style: TextStyle(fontWeight: FontWeight.w500)),
      ),
      for (final o in options)
        DropdownMenuItem(
          value: o.id,
          child: Text(o.displayLabel ?? o.id,
              style: const TextStyle(fontSize: 14)),
        ),
      if (_model.isNotEmpty && !options.any((o) => o.id == _model))
        DropdownMenuItem(value: _model, child: Text(_model)),
      const DropdownMenuItem(
        value: '__custom__',
        child: Text('自定义...', style: TextStyle(fontStyle: FontStyle.italic)),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '模型覆盖（可选）',
          border: OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: items.any((i) => i.value == _model) ? _model : '__custom__',
            isDense: true,
            isExpanded: true,
            items: items,
            onChanged: (v) {
              if (v == '__custom__') {
                _showCustomModelDialog();
              } else if (v != null) {
                setState(() => _model = v);
              }
            },
          ),
        ),
      ),
    );
  }

  void _showCustomModelDialog() async {
    final ctl = TextEditingController(text: _model);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义模型'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入 modelId'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (result != null) setState(() => _model = result);
  }

  void _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      HiDialog.showSnackBar(context, '请输入助手名称');
      return;
    }
    setState(() => _saving = true);
    final model = widget.assistant ?? AssistantModel(name: name);
    final memoryBook = _memoryBookCtl.text.trim();
    model
      ..name = name
      ..emoji = _emojiCtl.text.trim().isEmpty ? '🤖' : _emojiCtl.text.trim()
      ..prompt = _composePromptWithEditableSections(
        prompt: _promptCtl.text,
        personality: _personalityCtl.text,
        scenario: _scenarioCtl.text,
      )
      ..description = _descriptionCtl.text.trim()
      ..openingMessage = _openingMessageCtl.text.trim()
      ..exampleDialogs = _exampleDialogsCtl.text.trim()
      ..memoryBook = memoryBook
      ..worldBookJson = WorldBookCodec.encode(
        WorldBookCodec.decode(legacyText: memoryBook),
      )
      ..defaultVoiceStyle = _defaultVoiceStyle.trim()
      ..avatarType = _avatarType
      ..avatarValue = _avatarValue
      ..providerId = settingsAwareProviderId()
      ..model = _model.trim()
      ..useTools = _useTools
      ..toolIds = _toolIds.toList();
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await AssistantDao.create(dbManager);
    await dao.saveAssistant(model);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  void _pickAvatarImage() async {
    if (Platform.operatingSystem == 'ohos') {
      HiDialog.showSnackBar(context, '当前平台暂不支持选择图片头像');
      return;
    }
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (!mounted || picked == null) return;
      final name = _nameCtl.text.trim().isEmpty ? 'assistant' : _nameCtl.text;
      final oldPath = _avatarValue;
      final path = await AvatarAssetService.saveAssistantAvatar(
        sourcePath: picked.path,
        assistantName: name,
      );
      if (oldPath != path) {
        await AvatarAssetService.deleteAssistantAvatar(oldPath);
      }
      if (!mounted) return;
      setState(() {
        _avatarType = AvatarAssetService.imageType;
        _avatarValue = path;
      });
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取头像失败：$e');
    }
  }

  void _removeAvatarImage() async {
    final oldPath = _avatarValue;
    setState(() {
      _avatarType = null;
      _avatarValue = null;
    });
    await AvatarAssetService.deleteAssistantAvatar(oldPath);
  }

  String settingsAwareProviderId() {
    if (_providerId.trim().isEmpty) return '';
    return _providerId.trim();
  }

  void _loadUserVoiceModels() async {
    final models = await UserSherpaOnnxTtsModelStore().listModels();
    if (!mounted) return;
    setState(() => _userVoiceModels = models);
  }
}
