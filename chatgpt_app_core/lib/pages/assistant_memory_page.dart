import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
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

  @override
  void initState() {
    super.initState();
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
    if (widget.dao != null) {
      _dao = widget.dao;
      await _loadData();
      return;
    }
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    _dao = await AssistantMemoryDao.create(dbManager);
    await _loadData();
  }

  Future<void> _loadData() async {
    final id = widget.assistant.id;
    if (id == null || _dao == null) {
      if (mounted) setState(() => _memories = const []);
      return;
    }
    final list = await _dao!.getMemories(id, limit: 100);
    if (mounted) setState(() => _memories = list);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.assistant.name.trim().isEmpty
        ? '长期记忆'
        : '${widget.assistant.name} · 长期记忆';
    return Scaffold(
      appBar: AppBar(title: Text(title), centerTitle: true),
      body: _memories.isEmpty ? _emptyView : _contentView,
      floatingActionButton: widget.assistant.id == null
          ? null
          : FloatingActionButton(
              onPressed: () => _editMemory(null),
              tooltip: '新增记忆',
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget get _emptyView => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.assistant.id == null
                ? '请先保存助手，再添加长期记忆'
                : '还没有长期记忆。点右下角新增，或在会话中长按消息选择「记住」。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '共 ${_memories.length} 条 · 手动 $manualCount · 自动建议 $suggestionCount · 对话 $conversationCount',
            style: const TextStyle(fontSize: 13, color: Colors.black54),
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
  }

  Widget get _noSearchResultView => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有匹配的长期记忆',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: memories.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final memory = memories[index];
          return ListTile(
            title: Text(memory.content,
                maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text(_subtitle(memory)),
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
    return '$source · ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _editMemory(AssistantMemoryModel? memory) async {
    final assistantId = widget.assistant.id;
    if (assistantId == null || _dao == null) return;
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
    );
    if (mounted) {
      setState(() {
        final next = List<AssistantMemoryModel>.of(_memories);
        final index = next.indexWhere((item) => item.id == saved.id);
        if (index >= 0) {
          next[index] = saved;
        } else {
          next.insert(0, saved);
        }
        _memories = next;
      });
    }
    await _dao!.saveMemory(saved);
    if (!mounted) return;
    setState(() {
      final next = List<AssistantMemoryModel>.of(_memories);
      final index = next.indexWhere((item) => item.id == saved.id);
      if (index >= 0) {
        next[index] = saved;
      } else {
        next.insert(0, saved);
      }
      _memories = next;
    });
    if (!mounted) return;
    HiDialog.showSnackBar(context, memory == null ? '已新增长期记忆' : '已更新长期记忆');
  }

  Future<void> _deleteMemory(AssistantMemoryModel memory) async {
    final id = memory.id;
    if (id == null || _dao == null) return;
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
    if (!mounted) return;
    setState(() {
      _memories = _memories.where((item) => item.id != id).toList();
    });
    await _dao!.deleteMemory(id);
    if (!mounted) return;
    setState(() {
      _memories = _memories.where((item) => item.id != id).toList();
    });
    if (!mounted) return;
    HiDialog.showSnackBar(context, '已删除长期记忆');
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
