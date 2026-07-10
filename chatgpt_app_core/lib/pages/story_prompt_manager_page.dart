import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter/material.dart';

typedef StoryPromptManagerSaver = Future<void> Function(StoryRoomModel room);

class StoryPromptManagerPage extends StatefulWidget {
  final StoryRoomModel room;
  final StoryPromptManagerSaver onSave;

  const StoryPromptManagerPage({
    super.key,
    required this.room,
    required this.onSave,
  });

  @override
  State<StoryPromptManagerPage> createState() => _StoryPromptManagerPageState();
}

class _StoryPromptManagerPageState extends State<StoryPromptManagerPage> {
  static const _lockedKey = 'builtin.rules';
  late List<StoryPromptModule> _modules;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _modules = _modulesForEditor(StoryPromptConfigCodec.decode(_readConfig()));
  }

  @override
  Widget build(BuildContext context) {
    final fixedCount = _modules.where(_isBuiltIn).length;
    final customCount = _modules.length - fixedCount;
    final enabledCount = _modules.where((module) => module.enabled).length;
    final systemCount = _modules
        .where((module) =>
            module.enabled && module.placement == StoryPromptPlacement.system)
        .length;
    final historyCount = enabledCount - systemCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('提示词管理'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '保存',
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '固定 $fixedCount · 自定义 $customCount · 已启用 $enabledCount',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '预览摘要：系统 $systemCount 条 · 对话内 $historyCount 条',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: _modules.length,
              onReorder: _reorder,
              itemBuilder: (context, index) {
                final module = _modules[index];
                return _moduleTile(module, index);
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新增自定义模块',
        onPressed: _addCustomModule,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _moduleTile(StoryPromptModule module, int index) {
    final builtIn = _isBuiltIn(module);
    final locked = module.key == _lockedKey;
    final preview = _modulePreview(module);
    return Column(
      key: ValueKey(module.key),
      children: [
        ListTile(
          leading: Icon(
            builtIn ? Icons.extension_outlined : Icons.notes_outlined,
          ),
          title: Text(
            _moduleTitle(module),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${builtIn ? '固定' : '自定义'} · ${_roleLabel(module.role)} · '
            '${_placementLabel(module)}\n$preview',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          onTap: builtIn ? null : () => _editCustomModule(module),
          trailing: SizedBox(
            width: builtIn ? 92 : 132,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Switch(
                    key: ValueKey('prompt-toggle-${module.key}'),
                    value: locked ? true : module.enabled,
                    onChanged: locked
                        ? null
                        : (value) => _setEnabled(module.key, value),
                  ),
                ),
                if (!builtIn)
                  PopupMenuButton<_ModuleAction>(
                    tooltip: '模块操作',
                    onSelected: (action) {
                      if (action == _ModuleAction.edit) {
                        _editCustomModule(module);
                      } else {
                        _deleteCustomModule(module);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _ModuleAction.edit,
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('编辑'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: _ModuleAction.delete,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('删除'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                Tooltip(
                  message: '拖动重排',
                  child: ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Future<void> _addCustomModule() async {
    final created = await _showModuleEditor();
    if (created == null || !mounted) return;
    setState(() {
      _modules = _withSortOrders([..._modules, created]);
    });
  }

  Future<void> _editCustomModule(StoryPromptModule module) async {
    final edited = await _showModuleEditor(initial: module);
    if (edited == null || !mounted) return;
    final index = _modules.indexWhere((item) => item.key == module.key);
    if (index < 0) return;
    setState(() {
      _modules[index] = edited;
      _modules = _withSortOrders(_modules);
    });
  }

  Future<StoryPromptModule?> _showModuleEditor({
    StoryPromptModule? initial,
  }) {
    final key = initial?.key ??
        'custom-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    return showModalBottomSheet<StoryPromptModule>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _PromptModuleEditor(
        keyValue: key,
        initial: initial,
      ),
    );
  }

  Future<void> _deleteCustomModule(StoryPromptModule module) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除自定义模块'),
        content: Text(
          '“${_moduleTitle(module)}”将从提示词编排中移除。',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _modules = _withSortOrders(
        _modules.where((item) => item.key != module.key).toList(),
      );
    });
  }

  void _setEnabled(String key, bool enabled) {
    if (key == _lockedKey) return;
    final index = _modules.indexWhere((module) => module.key == key);
    if (index < 0) return;
    setState(() {
      _modules[index] = _modules[index].copyWith(enabled: enabled);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final module = _modules.removeAt(oldIndex);
      _modules.insert(newIndex, module);
      _modules = _withSortOrders(_modules);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = StoryPromptConfig(modules: _withSortOrders(_modules));
    _writeConfig(StoryPromptConfigCodec.encode(config));
    try {
      await widget.onSave(widget.room);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提示词编排已保存')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _readConfig() {
    return widget.room.promptConfigJson;
  }

  void _writeConfig(String value) {
    widget.room.promptConfigJson = value;
  }

  static List<StoryPromptModule> _modulesForEditor(StoryPromptConfig config) {
    final supplied = {for (final module in config.modules) module.key: module};
    final result = <StoryPromptModule>[];
    for (final fixed in StoryPromptConfigCodec.defaultModules) {
      final module = supplied.remove(fixed.key) ?? fixed;
      result.add(
        module.key == _lockedKey ? module.copyWith(enabled: true) : module,
      );
    }
    result.addAll(supplied.values.where((module) => !_isBuiltIn(module)));
    result.sort((a, b) {
      final order = a.sortOrder.compareTo(b.sortOrder);
      return order != 0 ? order : a.key.compareTo(b.key);
    });
    return _withSortOrders(result);
  }

  static List<StoryPromptModule> _withSortOrders(
    List<StoryPromptModule> modules,
  ) =>
      [
        for (var index = 0; index < modules.length; index++)
          modules[index].copyWith(sortOrder: (index + 1) * 10),
      ];

  static bool _isBuiltIn(StoryPromptModule module) =>
      StoryPromptConfigCodec.defaultModules
          .any((builtIn) => builtIn.key == module.key);

  static String _moduleTitle(StoryPromptModule module) {
    switch (module.builtInSlot) {
      case StoryPromptBuiltInSlot.rules:
        return '房间规则';
      case StoryPromptBuiltInSlot.room:
        return '房间上下文';
      case StoryPromptBuiltInSlot.continuity:
        return '长期剧情记忆';
      case StoryPromptBuiltInSlot.worldBookBefore:
        return '前置世界书';
      case StoryPromptBuiltInSlot.participants:
        return '参与者';
      case StoryPromptBuiltInSlot.roleStates:
        return '角色状态';
      case StoryPromptBuiltInSlot.speaker:
        return '当前发言者';
      case StoryPromptBuiltInSlot.worldBookAfter:
        return '后置世界书';
      case StoryPromptBuiltInSlot.history:
        return '对话历史';
      case StoryPromptBuiltInSlot.input:
        return '当前输入';
      default:
        return '自定义模块';
    }
  }

  static String _modulePreview(StoryPromptModule module) {
    final custom = module.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (custom.isNotEmpty) return custom;
    return '引用：${module.builtInSlot ?? module.key}';
  }

  static String _roleLabel(String role) {
    switch (role) {
      case StoryPromptRole.user:
        return '用户';
      case StoryPromptRole.assistant:
        return '助手';
      default:
        return '系统';
    }
  }

  static String _placementLabel(StoryPromptModule module) {
    if (module.placement == StoryPromptPlacement.historyDepth) {
      return '对话内 · 深度 ${module.depth}';
    }
    return '系统';
  }
}

enum _ModuleAction { edit, delete }

class _PromptModuleEditor extends StatefulWidget {
  final String keyValue;
  final StoryPromptModule? initial;

  const _PromptModuleEditor({
    required this.keyValue,
    required this.initial,
  });

  @override
  State<_PromptModuleEditor> createState() => _PromptModuleEditorState();
}

class _PromptModuleEditorState extends State<_PromptModuleEditor> {
  late final TextEditingController _contentCtl;
  late final TextEditingController _depthCtl;
  late String _role;
  late String _placement;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _contentCtl = TextEditingController(text: initial?.content ?? '');
    _depthCtl = TextEditingController(text: '${initial?.depth ?? 0}');
    _role = initial?.role ?? StoryPromptRole.system;
    _placement = initial?.placement ?? StoryPromptPlacement.system;
  }

  @override
  void dispose() {
    _contentCtl.dispose();
    _depthCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.initial == null ? '新增自定义模块' : '编辑自定义模块',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('prompt-module-content'),
                controller: _contentCtl,
                minLines: 5,
                maxLines: 10,
                maxLength: StoryPromptLimits.maxContentLength,
                decoration: const InputDecoration(
                  labelText: '模块内容',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 12),
              Text('角色', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: StoryPromptRole.system, label: Text('系统')),
                  ButtonSegment(value: StoryPromptRole.user, label: Text('用户')),
                  ButtonSegment(
                      value: StoryPromptRole.assistant, label: Text('助手')),
                ],
                selected: {_role},
                onSelectionChanged: (value) =>
                    setState(() => _role = value.first),
              ),
              const SizedBox(height: 16),
              Text('位置', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: StoryPromptPlacement.system, label: Text('系统')),
                  ButtonSegment(
                    value: StoryPromptPlacement.historyDepth,
                    label: Text('对话内'),
                  ),
                ],
                selected: {_placement},
                onSelectionChanged: (value) =>
                    setState(() => _placement = value.first),
              ),
              if (_placement == StoryPromptPlacement.historyDepth) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('prompt-module-depth'),
                  controller: _depthCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '历史深度',
                    helperText: '0 表示紧邻最新消息',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submit,
                    child: const Text('保存模块'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final content = _contentCtl.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '请填写模块内容');
      return;
    }
    final parsedDepth = int.tryParse(_depthCtl.text.trim()) ?? 0;
    final depth = parsedDepth.clamp(0, StoryPromptLimits.maxDepth).toInt();
    Navigator.pop(
      context,
      StoryPromptModule(
        key: widget.keyValue,
        content: content,
        enabled: widget.initial?.enabled ?? true,
        role: StoryPromptRole.normalize(_role),
        placement: StoryPromptPlacement.normalize(_placement),
        depth: depth,
        sortOrder: widget.initial?.sortOrder ?? 0,
      ),
    );
  }
}
