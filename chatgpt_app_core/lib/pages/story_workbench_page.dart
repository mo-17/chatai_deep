import 'dart:io';

import 'package:chatgpt_app_core/chat/application/story_artifact_context_builder.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class StoryWorkbenchPage extends StatefulWidget {
  final StoryRoomModel room;

  const StoryWorkbenchPage({super.key, required this.room});

  @override
  State<StoryWorkbenchPage> createState() => _StoryWorkbenchPageState();
}

class _StoryWorkbenchPageState extends State<StoryWorkbenchPage> {
  StoryArtifactDao? _dao;
  StoryRoomDao? _roomDao;
  List<StoryArtifactModel> _artifacts = const [];
  String? _filterType;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryArtifactDao.create(storage);
    final roomDao = await StoryRoomDao.create(storage);
    final artifacts = await dao.getArtifacts(
      widget.room.id!,
      type: _filterType,
    );
    if (!mounted) return;
    setState(() {
      _dao = dao;
      _roomDao = roomDao;
      _artifacts = artifacts;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('创作工作台'),
        actions: [
          IconButton(
            tooltip: '导出创作资料',
            onPressed: _artifacts.isEmpty ? null : _export,
            icon: const Icon(Icons.ios_share_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _typeFilter,
                const Divider(height: 1),
                Expanded(child: _artifactList),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createArtifact,
        tooltip: '新增创作资料',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _typeFilter {
    return SizedBox(
      height: 58,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        scrollDirection: Axis.horizontal,
        children: [
          ChoiceChip(
            label: const Text('全部'),
            selected: _filterType == null,
            onSelected: (_) => _setFilter(null),
          ),
          const SizedBox(width: 8),
          for (final type in StoryArtifactType.values) ...[
            ChoiceChip(
              label: Text(StoryArtifactType.labelOf(type)),
              selected: _filterType == type,
              onSelected: (_) => _setFilter(type),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget get _artifactList {
    if (_artifacts.isEmpty) {
      return Center(
        child: Text(
          _filterType == null
              ? '暂无创作资料'
              : '暂无${StoryArtifactType.labelOf(_filterType!)}',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        itemCount: _artifacts.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, index) {
          final artifact = _artifacts[index];
          return ListTile(
            leading: CircleAvatar(child: Icon(_iconFor(artifact.type))),
            title: Text(
              artifact.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                StoryArtifactType.labelOf(artifact.type),
                if (artifact.status.trim().isNotEmpty) artifact.status.trim(),
                if (artifact.content.trim().isNotEmpty)
                  artifact.content.trim().replaceAll('\n', ' '),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _editArtifact(artifact),
            trailing: PopupMenuButton<String>(
              tooltip: '资料操作',
              onSelected: (value) {
                if (value == 'edit') _editArtifact(artifact);
                if (value == 'history') _showHistory(artifact);
                if (value == 'delete') _deleteArtifact(artifact);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'history', child: Text('版本历史')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          );
        },
      ),
    );
  }

  void _setFilter(String? type) {
    setState(() {
      _filterType = type;
      _loading = true;
    });
    _load();
  }

  Future<void> _createArtifact() async {
    final draft = await showDialog<_StoryArtifactDraft>(
      context: context,
      builder: (_) => _StoryArtifactEditorDialog(
        initialType: _filterType ?? StoryArtifactType.outline,
      ),
    );
    if (draft == null) return;
    final maxOrder = _artifacts.fold<int>(
      0,
      (value, item) => item.sortOrder > value ? item.sortOrder : value,
    );
    await _dao?.saveArtifact(StoryArtifactModel(
      roomId: widget.room.id!,
      type: draft.type,
      title: draft.title,
      content: draft.content,
      status: draft.status,
      sortOrder: maxOrder + 1,
    ));
    await _syncRoomContext();
    await _load();
  }

  Future<void> _editArtifact(StoryArtifactModel artifact) async {
    final draft = await showDialog<_StoryArtifactDraft>(
      context: context,
      builder: (_) => _StoryArtifactEditorDialog(artifact: artifact),
    );
    if (draft == null) return;
    artifact
      ..type = draft.type
      ..title = draft.title
      ..content = draft.content
      ..status = draft.status;
    await _dao?.saveArtifact(artifact);
    await _syncRoomContext();
    await _load();
  }

  Future<void> _showHistory(StoryArtifactModel artifact) async {
    final id = artifact.id;
    if (id == null) return;
    final revisions = await _dao?.getRevisions(id) ?? const [];
    if (!mounted) return;
    if (revisions.isEmpty) {
      HiDialog.showSnackBar(context, '暂无历史版本');
      return;
    }
    final revision = await showModalBottomSheet<StoryArtifactRevisionModel>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: revisions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, index) {
            final item = revisions[index];
            final time = DateTime.fromMillisecondsSinceEpoch(item.createdAt);
            return ListTile(
              leading: const Icon(Icons.history_outlined),
              title: Text(item.title),
              subtitle: Text(
                '${time.year}-${time.month.toString().padLeft(2, '0')}-'
                '${time.day.toString().padLeft(2, '0')} '
                '${time.hour.toString().padLeft(2, '0')}:'
                '${time.minute.toString().padLeft(2, '0')} · ${item.content}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.restore_outlined),
              onTap: () => Navigator.pop(ctx, item),
            );
          },
        ),
      ),
    );
    if (revision == null) return;
    await _dao?.restoreRevision(artifact, revision);
    await _syncRoomContext();
    await _load();
    if (mounted) HiDialog.showSnackBar(context, '已恢复历史版本');
  }

  Future<void> _deleteArtifact(StoryArtifactModel artifact) async {
    final id = artifact.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除创作资料'),
        content: Text('确定删除「${artifact.title}」及其版本历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao?.deleteArtifact(id);
    await _syncRoomContext();
    await _load();
  }

  Future<void> _syncRoomContext() async {
    final dao = _dao;
    final roomDao = _roomDao;
    if (dao == null || roomDao == null) return;
    final all = await dao.getArtifacts(widget.room.id!);
    widget.room.publicContext =
        StoryArtifactContextBuilder.mergeIntoPublicContext(
      widget.room.publicContext,
      all,
    );
    await roomDao.saveRoom(widget.room);
  }

  Future<void> _export() async {
    final all = await _dao?.getArtifacts(widget.room.id!) ?? const [];
    final body = StringBuffer('# ${widget.room.title}\n');
    for (final type in StoryArtifactType.values) {
      final items = all.where((item) => item.type == type).toList();
      if (items.isEmpty) continue;
      body.writeln('\n## ${StoryArtifactType.labelOf(type)}');
      for (final item in items) {
        body.writeln('\n### ${item.title}');
        if (item.status.trim().isNotEmpty) body.writeln('状态：${item.status}');
        body.writeln(item.content);
      }
    }
    try {
      final dir = await getTemporaryDirectory();
      final safeTitle =
          widget.room.title.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]+'), '_');
      final file = File('${dir.path}/$safeTitle-创作资料.md');
      await file.writeAsString(body.toString());
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导出失败：$e');
    }
  }

  static IconData _iconFor(String type) {
    switch (type) {
      case StoryArtifactType.chapter:
        return Icons.article_outlined;
      case StoryArtifactType.timeline:
        return Icons.timeline_outlined;
      case StoryArtifactType.relationship:
        return Icons.hub_outlined;
      case StoryArtifactType.foreshadowing:
        return Icons.lightbulb_outline;
      default:
        return Icons.account_tree_outlined;
    }
  }
}

class _StoryArtifactDraft {
  final String type;
  final String title;
  final String content;
  final String status;

  const _StoryArtifactDraft({
    required this.type,
    required this.title,
    required this.content,
    required this.status,
  });
}

class _StoryArtifactEditorDialog extends StatefulWidget {
  final StoryArtifactModel? artifact;
  final String initialType;

  const _StoryArtifactEditorDialog({
    this.artifact,
    this.initialType = StoryArtifactType.outline,
  });

  @override
  State<_StoryArtifactEditorDialog> createState() =>
      _StoryArtifactEditorDialogState();
}

class _StoryArtifactEditorDialogState
    extends State<_StoryArtifactEditorDialog> {
  late String _type;
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late final TextEditingController _statusController;

  @override
  void initState() {
    super.initState();
    _type = widget.artifact?.type ?? widget.initialType;
    _titleController =
        TextEditingController(text: widget.artifact?.title ?? '');
    _contentController =
        TextEditingController(text: widget.artifact?.content ?? '');
    _statusController =
        TextEditingController(text: widget.artifact?.status ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _statusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.artifact == null ? '新增创作资料' : '编辑创作资料'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: '类型',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final type in StoryArtifactType.values)
                    DropdownMenuItem(
                      value: type,
                      child: Text(StoryArtifactType.labelOf(type)),
                    ),
                ],
                onChanged: (value) => setState(() => _type = value ?? _type),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '标题',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _statusController,
                decoration: const InputDecoration(
                  labelText: '状态',
                  hintText: '例如：草稿、进行中、已回收',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                minLines: 8,
                maxLines: 16,
                decoration: const InputDecoration(
                  labelText: '内容',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final title = _titleController.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(
              context,
              _StoryArtifactDraft(
                type: _type,
                title: title,
                content: _contentController.text.trim(),
                status: _statusController.text.trim(),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
