import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AssistantMemoryPage extends StatefulWidget {
  final AssistantModel assistant;
  final IAssistantMemory? dao;

  const AssistantMemoryPage({super.key, required this.assistant, this.dao});

  @override
  State<AssistantMemoryPage> createState() => _AssistantMemoryPageState();
}

class _AssistantMemoryPageState extends State<AssistantMemoryPage> {
  IAssistantMemory? _dao;
  List<AssistantMemoryModel> _memories = const [];
  late final TextEditingController _searchCtl;
  bool _loading = true;
  late final String? _account;
  int _loadGeneration = 0;
  bool get _current =>
      mounted &&
      (_account == null
          ? widget.dao != null
          : LoginDao.getAccountHash() == _account);
  void _guard(int tick) {
    if (!_current || tick != BackupService.restoreTick.value) {
      throw StateError('账号或恢复状态已变化');
    }
  }

  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _account = LoginDao.getAccountHash();
    _searchCtl = TextEditingController()..addListener(_onSearchChanged);
    _doInit();
  }

  @override
  void dispose() {
    _searchCtl
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _doInit() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      if (widget.dao != null) {
        _dao = widget.dao;
      } else {
        final dbManager = await HiDBManager.instance(
            dbName: _account ?? (throw StateError('账号未初始化')));
        _dao = await AssistantMemoryDao.create(dbManager);
      }
      await _loadData();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadData() async {
    final id = widget.assistant.id;
    if (id == null || _dao == null) {
      if (mounted) setState(() => _memories = const []);
      return;
    }
    final generation = ++_loadGeneration;
    final list = await _dao!.getMemories(id, limit: 100);
    if (_current && generation == _loadGeneration) {
      setState(() => _memories = list);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.assistant.name.trim().isEmpty
        ? '长期记忆'
        : '${widget.assistant.name} · 长期记忆';
    return Scaffold(
      appBar: AppBar(title: Text(title), centerTitle: true),
      body: _body,
      floatingActionButton: widget.assistant.id == null
          ? null
          : FloatingActionButton(
              onPressed:
                  _loading || _dao == null ? null : () => _editMemory(null),
              tooltip: '新增记忆',
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget get _body {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppVisualEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '长期记忆加载失败',
        message: _loadError.toString(),
        action: FilledButton.icon(
          onPressed: _doInit,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    return _memories.isEmpty ? _emptyView : _contentView;
  }

  Widget get _emptyView {
    final message = widget.assistant.id == null
        ? '请先保存助手，再添加长期记忆'
        : '点右下角新增，或在会话中长按消息选择「记为助手记忆」。';
    return AppVisualEmptyState(
      icon: Icons.psychology_alt_outlined,
      title: widget.assistant.id == null ? '还不能添加记忆' : '还没有长期记忆',
      message: message,
      classic: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.assistant.id == null
                ? '请先保存助手，再添加长期记忆'
                : '还没有长期记忆。点右下角新增，或在会话中长按消息选择「记为助手记忆」。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget get _contentView {
    final filtered = _filteredMemories;
    return Column(
      children: [
        _summaryHeader,
        Expanded(
          child: filtered.isEmpty ? _noSearchResultView : _listView(filtered),
        ),
      ],
    );
  }

  Widget get _summaryHeader {
    final manualCount =
        _memories.where((memory) => memory.source == 'manual').length;
    final suggestionCount =
        _memories.where((memory) => memory.source == 'suggestion').length;
    final conversationCount = _memories.length - manualCount - suggestionCount;
    final colorScheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('仅供当前助手使用；不属于个人跨会话记忆。'),
          Text(
            '共 ${_memories.length} 条 · 手动 $manualCount · 自动建议 $suggestionCount · 对话 $conversationCount',
            style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchCtl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(Icons.clear),
                      onPressed: _searchCtl.clear,
                    ),
              hintText: '搜索记忆内容或来源',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
    return AppVisualSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: content,
    );
  }

  Widget get _noSearchResultView => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有匹配的长期记忆',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );

  List<AssistantMemoryModel> get _filteredMemories {
    final query = _searchCtl.text.trim().toLowerCase();
    if (query.isEmpty) return _memories;
    return _memories.where((memory) {
      return memory.content.toLowerCase().contains(query) ||
          _subtitle(memory).toLowerCase().contains(query);
    }).toList();
  }

  Widget _listView(List<AssistantMemoryModel> memories) => ListView.separated(
        padding: AppVisualTheme.of(context).isAnime
            ? const EdgeInsets.fromLTRB(12, 6, 12, 20)
            : const EdgeInsets.symmetric(vertical: 8),
        itemCount: memories.length,
        separatorBuilder: (_, __) => AppVisualTheme.of(context).isAnime
            ? const SizedBox(height: 8)
            : const Divider(height: 1),
        itemBuilder: (context, index) {
          final memory = memories[index];
          final tile = ListTile(
            title: Text(memory.content,
                maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_subtitle(memory)),
              TextButton(
                  onPressed: _loading ? null : () => _toggleStatus(memory),
                  child: Text(memory.status == AssistantMemoryStatus.active &&
                          memory.confirmedByUser
                      ? '停用记忆'
                      : memory.status == AssistantMemoryStatus.pending
                          ? '确认并启用记忆'
                          : '启用记忆')),
            ]),
            onTap: () => _editMemory(memory),
            trailing: SizedBox(
              width: 96,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '复制记忆',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () => _copyMemory(memory),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteMemory(memory),
                  ),
                ],
              ),
            ),
          );
          return AppVisualSurface(
            padding: EdgeInsets.zero,
            child: tile,
          );
        },
      );

  void _onSearchChanged() => setState(() {});

  String _subtitle(AssistantMemoryModel memory) {
    final source = switch (memory.source) {
      'user_message' => '来自用户消息',
      'reply' => '来自助手回复',
      'suggestion' => '来自自动建议',
      _ => '手动添加',
    };
    final date = DateTime.fromMillisecondsSinceEpoch(
        memory.updatedAt > 0 ? memory.updatedAt : memory.createdAt);
    final state =
        memory.status == AssistantMemoryStatus.active && memory.confirmedByUser
            ? '生效'
            : memory.status == AssistantMemoryStatus.pending
                ? '待确认'
                : '停用';
    final origin = memory.sourceConversationId.isEmpty
        ? ''
        : ' · 会话 ${memory.sourceConversationId} · 消息 ${memory.sourceMessageId}';
    return '$state · $source$origin · ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _editMemory(AssistantMemoryModel? memory) async {
    final assistantId = widget.assistant.id;
    if (assistantId == null || _dao == null) return;
    final tick = BackupService.restoreTick.value;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _AssistantMemoryEditDialog(
        initialText: memory?.content ?? '',
        isNew: memory == null,
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    final existing = _memories.where((item) => item.id != memory?.id).toList();
    if (AssistantMemoryDao.hasDuplicateContent(existing, result)) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '这条长期记忆已存在');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final saved = AssistantMemoryModel(
      id: memory?.id,
      assistantId: assistantId,
      content: result,
      source: memory?.source ?? 'manual',
      createdAt: memory?.createdAt ?? now,
      updatedAt: now,
      memoryId: memory?.memoryId ?? '',
      assistantSyncId: memory?.assistantSyncId ?? '',
      sourceType: memory?.sourceType ?? 'manual',
      sourceConversationId: memory?.sourceConversationId ?? '',
      sourceMessageId: memory?.sourceMessageId ?? '',
      status: memory?.status ?? AssistantMemoryStatus.active,
      confirmedByUser: memory?.confirmedByUser ?? true,
      revision: memory?.revision ?? 1,
    );
    await _mutate(tick, () async {
      final dao = _dao!;
      final id = dao is AssistantMemoryDao
          ? await dao.saveMemoryChecked(saved)
          : await dao.saveMemory(saved);
      if (id == null) throw StateError('记忆已删除或修改，请刷新');
    }, memory == null ? '已新增长期记忆' : '已更新长期记忆');
  }

  Future<void> _mutate(
      int tick, Future<void> Function() action, String notice) async {
    if (!_current || _loading) return;
    setState(() => _loading = true);
    try {
      Future<void> write() async {
        _guard(tick);
        await action();
      }

      if (_account == null) {
        await write();
      } else {
        await LoginDao.runWithStableAccount(
            expectedAccountHash: _account, action: write);
      }
      if (!mounted) return;
      _guard(tick);
      await _loadData();
      if (!mounted || !_current) return;
      HiDialog.showSnackBar(context, notice);
    } catch (e) {
      if (mounted && _current) HiDialog.showSnackBar(context, '记忆保存失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleStatus(AssistantMemoryModel memory) async {
    final tick = BackupService.restoreTick.value;
    final active =
        memory.status == AssistantMemoryStatus.active && memory.confirmedByUser;
    if (!active) {
      final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('启用助手记忆'),
                  content: Text('确认后此内容仅供当前助手使用：\n${memory.content}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('确认启用'))
                  ]));
      if (ok != true) return;
    }
    final next = AssistantMemoryModel.fromJson(memory.toJson())
      ..status =
          active ? AssistantMemoryStatus.archived : AssistantMemoryStatus.active
      ..confirmedByUser = !active;
    await _mutate(tick, () async {
      final dao = _dao!;
      final id = dao is AssistantMemoryDao
          ? await dao.saveMemoryChecked(next)
          : await dao.saveMemory(next);
      if (id == null) throw StateError('记忆已变化');
    }, active ? '助手记忆已停用' : '助手记忆已启用');
  }

  Future<void> _deleteMemory(AssistantMemoryModel memory) async {
    final id = memory.id;
    if (id == null || _dao == null) return;
    final tick = BackupService.restoreTick.value;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除长期记忆'),
        content: Text(memory.content),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await _mutate(tick, () async {
      final dao = _dao!;
      final count = dao is AssistantMemoryDao
          ? await dao.deleteMemoryChecked(memory)
          : await dao.deleteMemory(id);
      if (count != 1) throw StateError('记忆已删除或修改');
    }, '已删除长期记忆');
  }

  Future<void> _copyMemory(AssistantMemoryModel memory) async {
    final text = memory.content.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HiDialog.showSnackBar(context, '长期记忆已复制');
  }
}

class _AssistantMemoryEditDialog extends StatefulWidget {
  final String initialText;
  final bool isNew;

  const _AssistantMemoryEditDialog({
    required this.initialText,
    required this.isNew,
  });

  @override
  State<_AssistantMemoryEditDialog> createState() =>
      _AssistantMemoryEditDialogState();
}

class _AssistantMemoryEditDialogState
    extends State<_AssistantMemoryEditDialog> {
  late final TextEditingController _controller;
  String? _contentError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? '新增长期记忆' : '编辑长期记忆'),
      content: TextField(
        controller: _controller,
        minLines: 4,
        maxLines: 8,
        decoration: const InputDecoration(
          labelText: '记忆内容',
          hintText: '写下希望这个助手长期记住的事实、偏好或关系状态',
          border: OutlineInputBorder(),
        ).copyWith(errorText: _contentError),
        onChanged: (_) {
          if (_contentError != null) {
            setState(() => _contentError = null);
          }
        },
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _contentError = '请填写记忆内容');
      return;
    }
    Navigator.pop(context, text);
  }
}
