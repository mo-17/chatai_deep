import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/widget/backend_selection_picker.dart';
import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_management_session.dart';
import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';

import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar_preset_picker.dart';
import 'package:chatgpt_app_core/widget/starcore_tool_icon.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

///助手新建 / 编辑页（阶段七）：名称、emoji、系统提示词、可选模型覆盖、工具开关。
///对应源项目 `src/screens/assistant/AssistantDetailScreen.tsx` 的精简版。
typedef AssistantEditSaver = Future<void> Function(AssistantModel assistant);

class AssistantEditPage extends StatefulWidget {
  ///null = 新建。
  final AssistantModel? assistant;
  final AssistantEditSaver? saveAssistant;
  final AssistantOperationScope? operationScope;

  const AssistantEditPage({
    super.key,
    this.assistant,
    this.saveAssistant,
    this.operationScope,
  });

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
  BackendSelection? _backendSelection;
  AiCatalogIdentity? _backendEditIdentity;
  bool _backendSelectionEdited = false;
  bool _localSelectionEdited = false;
  String _defaultVoiceStyle = '';
  String? _avatarType;
  String? _avatarValue;
  final Set<String> _obsoleteAvatarPaths = {};
  final Set<String> _ownedAvatarPaths = {};
  bool _useTools = true;
  List<UserSherpaOnnxTtsModel> _userVoiceModels = const [];
  final _imagePicker = ImagePicker();

  /// 助手绑定的工具 id 集合（L1）。旧助手 toolIds 为 null 时按空集处理，
  /// 保存后变为显式列表（语义不变：未勾选 = 不绑定）。MCP 工具名（mcp__…）
  /// 也存进同一集合，与内置工具一视同仁（item 5）。
  late final Set<String> _toolIds;
  bool _saving = false;
  AssistantOperationScope? _scope;
  late Future<AssistantManagementSession?> _session;
  Object? _sessionError;
  late AssistantModel _worldBookDraft;

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
    _worldBookDraft =
        AssistantModel.fromJson((a ?? AssistantModel(name: '')).toJson());
    _session = _openSession();
    final promptParts = _splitEditablePromptSections(a?.prompt ?? '');
    _nameCtl = TextEditingController(text: a?.name ?? '');
    _emojiCtl = TextEditingController(text: a?.emoji ?? '🤖');
    _promptCtl = TextEditingController(text: promptParts.prompt);
    _personalityCtl = TextEditingController(text: promptParts.personality);
    _scenarioCtl = TextEditingController(text: promptParts.scenario);
    _descriptionCtl = TextEditingController(text: a?.description ?? '');
    _openingMessageCtl = TextEditingController(text: a?.openingMessage ?? '');
    _exampleDialogsCtl = TextEditingController(text: a?.exampleDialogs ?? '');
    _memoryBookCtl = TextEditingController(
        text:
            AssistantRoleCardService.memoryBookForRuntime(a?.memoryBook ?? ''));
    _providerId = a?.providerId ?? '';
    _model = a?.model ?? '';
    _backendSelection = a?.backendSelection;
    _defaultVoiceStyle = a?.defaultVoiceStyle ?? '';
    _avatarType = a?.avatarType;
    _avatarValue = a?.avatarValue;
    _useTools = a?.useTools ?? true;
    _toolIds = {...?a?.toolIds};
    _loadUserVoiceModels();
  }

  @override
  void dispose() {
    if (!_saving) unawaited(_discardOwnedAvatars());
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
                readOnly: _worldBookDraft.worldBookJson.trim().isNotEmpty,
                label: '世界书条目',
                hint: '每行：关键词1,关键词2 => 设定内容\n未写箭头的行会作为常驻设定注入',
                minLines: 4,
                maxLines: 10,
              ),
              if (_worldBookDraft.worldBookJson.trim().isNotEmpty)
                TextButton.icon(
                    onPressed: _saving ? null : _editStructuredWorldBook,
                    icon: const Icon(Icons.auto_stories_outlined),
                    label: const Text('编辑结构化世界书')),
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
        child: Builder(
          builder: (context) {
            final visual = AppVisualTheme.of(context);
            final colorScheme = Theme.of(context).colorScheme;
            return Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: visual.isAnime
                    ? visual.elevatedSurface.withValues(alpha: 0.96)
                    : Theme.of(context).scaffoldBackgroundColor,
                border:
                    Border(top: BorderSide(color: colorScheme.outlineVariant)),
                boxShadow: visual.isAnime
                    ? [
                        BoxShadow(
                          color: visual.glowPrimary,
                          blurRadius: 18,
                          offset: const Offset(0, -4),
                        ),
                      ]
                    : null,
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
            );
          },
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
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: visual.isAnime
            ? visual.elevatedSurface.withValues(alpha: 0.94)
            : colorScheme.surface,
        borderRadius:
            BorderRadius.circular(visual.isAnime ? visual.cardRadius : 12),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: visual.isAnime
            ? [
                BoxShadow(color: visual.glowPrimary, blurRadius: 16),
              ]
            : null,
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
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: visual.isAnime
            ? visual.elevatedSurface.withValues(alpha: 0.94)
            : colorScheme.surface,
        borderRadius:
            BorderRadius.circular(visual.isAnime ? visual.cardRadius : 12),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: visual.isAnime
            ? [
                BoxShadow(color: visual.glowSecondary, blurRadius: 16),
              ]
            : null,
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
    final colorScheme = Theme.of(context).colorScheme;
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
          child: Icon(icon, size: 20, color: colorScheme.primary),
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
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
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
    bool readOnly = false,
    required int maxLines,
  }) {
    return TextField(
      controller: controller,
      readOnly: readOnly,
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
    final selectedAssetId = _avatarType == AvatarAssetService.assetType
        ? _avatarValue?.trim()
        : null;
    final emojiSelected =
        _avatarType != AvatarAssetService.assetType && !hasImage;
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final emoji = _emojiCtl.text.trim().isEmpty ? '🤖' : _emojiCtl.text.trim();
    final caption = switch (selectedAssetId) {
      StarcoreIconAssets.assistantExplorerId => '探索向导',
      StarcoreIconAssets.assistantCreatorId => '创作搭档',
      _ => hasImage ? '图片头像' : 'Emoji 头像',
    };
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
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(
                              Icons.photo_camera_outlined,
                              color: colorScheme.onPrimary,
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
                caption,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (visual.isAnime) ...[
                const SizedBox(height: 10),
                AssistantAvatarPresetPicker(
                  selectedAssetId: selectedAssetId,
                  emojiSelected: emojiSelected,
                  onSelected: _selectAvatarPreset,
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('assistant-avatar-emoji-field'),
                controller: _emojiCtl,
                textAlign: TextAlign.center,
                maxLength: 2,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_avatarType == AvatarAssetService.assetType) {
                    _selectAvatarPreset(null);
                  } else {
                    setState(() {});
                  }
                },
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
                _localSelectionEdited = true;
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
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text('可用工具（绑定后该助手始终向模型暴露）',
              style:
                  TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text('MCP 工具（来自已配置的 MCP 服务）',
              style:
                  TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
        ),
        FutureBuilder<List<McpToolBindSpec>>(
          future: _mcpSpecs,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('正在发现 MCP 工具…',
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.onSurfaceVariant)),
                ]),
              );
            }
            if (snap.hasError) {
              return Text('MCP 工具发现失败：${snap.error}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppStatusPalette.of(context, AppStatusKind.error)
                        .foreground,
                  ));
            }
            final specs = snap.data ?? const [];
            if (specs.isEmpty) {
              return Text('未发现可用的 MCP 工具',
                  style: TextStyle(
                      fontSize: 12, color: colorScheme.onSurfaceVariant));
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
    final info = AppStatusPalette.of(context, AppStatusKind.info);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Row(
        children: [
          Icon(Icons.extension, size: 16, color: info.foreground),
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
    final warning = AppStatusPalette.of(context, AppStatusKind.warning);
    final isStarcoreTool = AppVisualTheme.of(context).isAnime &&
        (d.id == ToolRegistry.webSearchId ||
            d.id == ToolRegistry.knowledgeSearchId);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Row(
        children: [
          if (isStarcoreTool) ...[
            StarcoreToolIcon(
              toolName: d.id,
              fallback: Icon(Icons.build_outlined,
                  size: 18, color: warning.foreground),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: Text(d.label)),
          if (d.sideEffect)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.edit_note, size: 16, color: warning.foreground),
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
    if (settings.mode == AIMode.backend) {
      return ListTile(
          key: const ValueKey('assistant_backend_selection'),
          title: const Text('助手后端选择'),
          subtitle: Text(backendSelectionLabel(_backendSelection,
              legacyModelId: _model, followLabel: '跟随全局')),
          onTap: _saving ? null : _pickBackendOverride);
    }
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
                setState(() {
                  _model = v;
                  _localSelectionEdited = true;
                });
              }
            },
          ),
        ),
      ),
    );
  }

  Future<void> _pickBackendOverride() async {
    try {
      final session = await _session;
      if (!mounted) return;
      if (session == null || _backendEditIdentity == null) {
        throw const AssistantOperationExpired();
      }
      session.scope.verify();
      final identity = _backendEditIdentity!;
      if (identity.account != session.scope.accountHash || !identity.current) {
        throw const BackendSelectionEditorExpired();
      }
      final selected = await pickBackendSelection(context,
          identity: identity,
          selected: _backendSelection,
          legacyModelId: _model,
          followLabel: '跟随全局');
      session.scope.verify();
      if (!mounted || !identity.current || selected == null) return;
      setState(() {
        _backendSelection = selected;
        _backendSelectionEdited = true;
      });
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '编辑环境已变化，请重新打开助手编辑');
    }
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
    if (result != null && mounted) {
      setState(() {
        _model = result;
        _localSelectionEdited = true;
      });
    }
  }

  Future<AssistantManagementSession?> _openSession() async {
    try {
      _scope = (widget.operationScope ?? AssistantOperationScope.capture())
          .forPage(() => mounted);
      _backendEditIdentity = AiCatalogIdentity.capture();
      return await AssistantManagementSession.open(
          source: widget.assistant,
          scope: _scope!,
          injectedPersistence: widget.saveAssistant != null);
    } catch (error) {
      _sessionError = error;
      return null;
    }
  }

  Future<void> _editStructuredWorldBook() async {
    if (_saving) return;
    try {
      final draft = AssistantModel.fromJson(_worldBookDraft.toJson())
        ..name = _nameCtl.text;
      final session = await _session;
      if (!mounted || session == null) return;
      session.scope.verify();
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => AssistantWorldBookPage(
                    assistant: draft,
                    operationScope: session.scope,
                    onSave: (saved) async {
                      session.scope.verify();
                      if (!mounted) throw const AssistantOperationExpired();
                      setState(() {
                        _worldBookDraft =
                            AssistantModel.fromJson(saved.toJson());
                        _memoryBookCtl.text =
                            AssistantRoleCardService.memoryBookForRuntime(
                                saved.memoryBook);
                      });
                    },
                  )));
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '无法打开世界书：$error');
    }
  }

  void _save() async {
    if (_saving) return;
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      HiDialog.showSnackBar(context, '请输入助手名称');
      return;
    }
    final editingLocal =
        context.read<AISettingsProvider>().settings.mode == AIMode.local;
    setState(() => _saving = true);
    try {
      final session = await _session;
      if (session == null) {
        throw _sessionError ?? const AssistantOperationExpired();
      }
      session.scope.verify();
      if (widget.assistant != null) {
        AssistantRoleCardService.exportJson(widget.assistant!);
        AssistantRoleCardService.exportTavernV2Json(widget.assistant!);
      }
      var model = AssistantModel.fromJson(
          (widget.assistant ?? AssistantModel(name: name)).toJson());
      final body = _memoryBookCtl.text.trim();
      final previous = AssistantRoleCardService.memoryBookForRuntime(
          _worldBookDraft.memoryBook);
      if (body == previous) {
        model.memoryBook = _worldBookDraft.memoryBook;
        model.worldBookJson = _worldBookDraft.worldBookJson;
      } else {
        // 无结构化源的旧卡仍支持文本编辑；结构化卡通过专用编辑器保留元数据。
        model = AssistantRoleCardService.withWorldBook(model,
            WorldBookCodec.encode(WorldBookCodec.decode(legacyText: body)));
      }
      model
        ..name = name
        ..emoji = _emojiCtl.text.trim().isEmpty ? '🤖' : _emojiCtl.text.trim()
        ..prompt = _composePromptWithEditableSections(
            prompt: _promptCtl.text,
            personality: _personalityCtl.text,
            scenario: _scenarioCtl.text)
        ..description = _descriptionCtl.text.trim()
        ..openingMessage = _openingMessageCtl.text.trim()
        ..exampleDialogs = _exampleDialogsCtl.text.trim()
        ..defaultVoiceStyle = _defaultVoiceStyle.trim()
        ..avatarType = _avatarType
        ..avatarValue = _avatarValue
        ..useTools = _useTools
        ..toolIds = _toolIds.toList();
      // 后端编辑只声明新业务字段；共享旧model/providerId仍属于本地/legacy。
      if (_backendSelectionEdited) {
        model.backendSelection = _backendSelection;
      }
      if (editingLocal && (!_backendSelectionEdited || _localSelectionEdited)) {
        model.providerId = settingsAwareProviderId();
        model.model = _model.trim();
      }
      AssistantRoleCardService.exportTavernV2Json(model);
      AssistantRoleCardService.exportJson(model);
      final saved = await session.save(model,
          override: widget.saveAssistant,
          additionallyCurrent: _backendSelectionEdited
              ? () =>
                  _backendEditIdentity?.current == true &&
                  _backendEditIdentity?.account == session.scope.accountHash
              : null);
      // 已提交的头像从自有临时集合移出；页面已离开也不能删除有效文件。
      _ownedAvatarPaths.remove(saved.avatarValue);
      await _discardOwnedAvatars();
      if (!mounted || !session.scope.isCurrent) return;
      if (widget.assistant != null) {
        acceptSavedAssistant(widget.assistant!, saved);
      }
      await _retainObsoleteAvatarImages(
          finalAvatarType: saved.avatarType,
          finalAvatarValue: saved.avatarValue,
          session: session);
      if (mounted && session.scope.isCurrent) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '保存失败：$error');
    } finally {
      if (!mounted) await _discardOwnedAvatars();
      if (mounted) setState(() => _saving = false);
    }
  }

  void _selectAvatarPreset(String? assetId) {
    _queueCurrentImageForCleanup();
    setState(() {
      _avatarType = assetId == null ? null : AvatarAssetService.assetType;
      _avatarValue = assetId;
    });
  }

  void _pickAvatarImage() async {
    String? owned;
    try {
      final session = await _session;
      if (session == null) {
        throw _sessionError ?? const AssistantOperationExpired();
      }
      session.scope.verify();
      final picked = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 80,
          maxWidth: 512,
          maxHeight: 512);
      session.scope.verify();
      if (!mounted || picked == null) return;
      final bytes = await readFileBytesBounded(File(picked.path),
          maxBytes: AssistantRoleCardService.maxImportBytes, label: '角色头像');
      session.scope.verify();
      // 每次选择只创建自己的文件，不复用选择器给出的其他账号托管路径。
      final path = await AvatarAssetService.saveAssistantAvatarBytes(
          bytes: bytes,
          assistantName: 'operation_${generateUuidV4()}',
          extension:
              picked.path.toLowerCase().endsWith('.png') ? '.png' : '.jpg',
          accountHash: session.scope.accountHash);
      owned = path;
      _ownedAvatarPaths.add(path);
      session.scope.verify();
      if (!mounted) throw const AssistantOperationExpired();
      _queueCurrentImageForCleanup();
      setState(() {
        _avatarType = AvatarAssetService.imageType;
        _avatarValue = path;
      });
    } catch (e) {
      if (owned != null) {
        _ownedAvatarPaths.remove(owned);
        await AvatarAssetService.deleteAssistantAvatar(owned);
      }
      if (mounted) HiDialog.showSnackBar(context, '选取头像失败：$e');
    }
  }

  Future<void> _discardOwnedAvatars() async {
    final paths = _ownedAvatarPaths.toList();
    _ownedAvatarPaths.clear();
    for (final path in paths) {
      await AvatarAssetService.deleteAssistantAvatar(path);
    }
  }

  void _removeAvatarImage() {
    _queueCurrentImageForCleanup();
    setState(() {
      _avatarType = null;
      _avatarValue = null;
    });
  }

  void _queueCurrentImageForCleanup() {
    if (_avatarType != AvatarAssetService.imageType) return;
    _queueManagedImagePath(_avatarValue);
  }

  void _queueManagedImagePath(String? path) {
    final value = path?.trim() ?? '';
    if (value.isEmpty || !AvatarAssetService.isManagedPath(value)) return;
    _obsoleteAvatarPaths.add(value);
  }

  Future<void> _retainObsoleteAvatarImages({
    required String? finalAvatarType,
    required String? finalAvatarValue,
    required AssistantManagementSession session,
  }) async {
    if (_obsoleteAvatarPaths.isEmpty) return;
    if (session.dao != null) {
      try {
        await session.scope.runStable(() async {
          session.scope.verify();
          await session.dao!.storage.db
              .query(session.dao!.tableName, columns: ['avatarValue']);
          session.scope.verify();
          // 已发布头像可能被其它入口引用，查询不能授权删除。
        });
      } catch (_) {/* 维护核查失败不改变已经保存的结果。 */}
    }
    _obsoleteAvatarPaths.clear();
    if (mounted && session.scope.isCurrent) {
      HiDialog.showSnackBar(context, '已保存；旧头像资源已保留，会继续占用磁盘空间');
    }
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
