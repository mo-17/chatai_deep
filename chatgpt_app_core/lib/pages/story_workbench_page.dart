import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/story_ai_workflow_service.dart';
import 'package:chatgpt_app_core/chat/application/story_artifact_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_room_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/story_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
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
  UsageRecordService? _usageRecordService;
  List<StoryArtifactModel> _artifacts = const [];
  String? _filterType;
  bool _loading = true;
  StoryAiWorkflowKind? _runningWorkflow;
  String _workflowStatus = '';
  bool _stopRequested = false;
  StreamSubscription<StreamEvent>? _activeWorkflowSub;
  Completer<void>? _activeWorkflowDone;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    unawaited(_activeWorkflowSub?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryArtifactDao.create(storage);
    final roomDao = await StoryRoomDao.create(storage);
    final usageRecordService =
        UsageRecordService(await UsageDao.create(storage));
    final artifacts = await dao.getArtifacts(
      widget.room.id!,
      type: _filterType,
    );
    if (!mounted) return;
    setState(() {
      _dao = dao;
      _roomDao = roomDao;
      _usageRecordService = usageRecordService;
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
                _workflowBar,
                const Divider(height: 1),
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

  Widget get _workflowBar {
    final running = _runningWorkflow;
    final colorScheme = Theme.of(context).colorScheme;
    return StoryAdaptiveSurface(
      animeKey: const ValueKey('anime_story_workflow_bar'),
      animeMargin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      animePadding: const EdgeInsets.all(12),
      child: Padding(
        padding: storyUsesAnimeStyle(context)
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: running == null
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        _runWorkflow(StoryAiWorkflowKind.directorReview),
                    icon: const Icon(Icons.movie_filter_outlined),
                    label: const Text('剧情导演审阅'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _runWorkflow(StoryAiWorkflowKind.worldBookConsistency),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('世界书一致性检查'),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _workflowStatus.isEmpty
                              ? '${StoryAiWorkflowService.titleFor(running)}中...'
                              : _workflowStatus,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(color: colorScheme.primary),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '停止生成',
                    onPressed: _stopWorkflow,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                ],
              ),
      ),
    );
  }

  Widget get _typeFilter {
    return StoryAdaptiveSurface(
      animeKey: const ValueKey('anime_story_artifact_filters'),
      animeMargin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SizedBox(
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
      ),
    );
  }

  Widget get _artifactList {
    if (_artifacts.isEmpty) {
      final message = _filterType == null
          ? '暂无创作资料'
          : '暂无${StoryArtifactType.labelOf(_filterType!)}';
      return StoryAdaptiveEmptyState(
        classicChild: Center(
          child: Text(message),
        ),
        icon: Icons.dashboard_customize_outlined,
        title: '创作资料等待整理',
        subtitle: message,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        itemCount: _artifacts.length,
        separatorBuilder: (_, __) => storyUsesAnimeStyle(context)
            ? const SizedBox.shrink()
            : const Divider(height: 1),
        itemBuilder: (_, index) {
          final artifact = _artifacts[index];
          return StoryAdaptiveListItem(
            animeMargin: const EdgeInsets.symmetric(vertical: 5),
            child: ListTile(
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
            style: storyUsesAnimeStyle(ctx)
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  )
                : null,
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

  Future<void> _runWorkflow(StoryAiWorkflowKind kind) async {
    if (_runningWorkflow != null || _dao == null) return;
    setState(() {
      _runningWorkflow = kind;
      _workflowStatus = '${StoryAiWorkflowService.titleFor(kind)}准备中...';
      _stopRequested = false;
    });
    try {
      final artifacts = await _dao!.getArtifacts(widget.room.id!);
      if (!mounted) return;
      if (_stopRequested) return;
      final settings = StoryRoomSettingsResolver.apply(
        widget.room,
        context.read<AISettingsProvider>().settings,
      );
      final request = StoryAiWorkflowService.prepare(
        kind: kind,
        room: widget.room,
        artifacts: artifacts,
      );
      final buffer = StringBuffer();
      var promptTokens = 0;
      var cachedPromptTokens = 0;
      var completionTokens = 0;
      var hasUsage = false;
      Object? streamError;
      final done = Completer<void>();
      final createdAt = DateTime.now().millisecondsSinceEpoch;
      setState(() => _workflowStatus = '${request.title}中...');
      final stream = ChatService.from(settings).chatStreamEvents(
        prompt: request.prompt,
        history: request.history,
      );
      late final StreamSubscription<StreamEvent> sub;
      sub = stream.listen(
        (event) {
          if (_stopRequested) return;
          if (event.type == StreamEventType.usage) {
            hasUsage = true;
            promptTokens += event.promptTokens ?? 0;
            cachedPromptTokens += event.cachedPromptTokens ?? 0;
            completionTokens += event.completionTokens ?? 0;
            return;
          }
          if (event.type == StreamEventType.text) {
            buffer.write(event.delta);
            if (mounted) {
              setState(() => _workflowStatus = '${request.title}中...');
            }
          }
        },
        onError: (Object error) {
          streamError = error;
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );
      _activeWorkflowSub = sub;
      _activeWorkflowDone = done;
      await done.future;
      if (identical(_activeWorkflowSub, sub)) _activeWorkflowSub = null;
      if (identical(_activeWorkflowDone, done)) _activeWorkflowDone = null;

      final content = buffer.toString().trim();
      if (content.isNotEmpty) {
        await _recordWorkflowUsage(
          settings: settings,
          request: request,
          completion: content,
          promptTokens: hasUsage ? promptTokens : null,
          cachedPromptTokens: hasUsage ? cachedPromptTokens : null,
          completionTokens: hasUsage ? completionTokens : null,
          estimated: !hasUsage,
          createdAt: createdAt,
        );
        if (mounted) {
          setState(() => _workflowStatus =
              _stopRequested ? '已停止，正在预览已生成内容' : '审阅完成，正在预览结果');
          await _previewWorkflowResult(
            request: request,
            content: content,
            stopped: _stopRequested,
            createdAt: createdAt,
          );
        }
      } else if (streamError != null && mounted) {
        HiDialog.showSnackBar(context, '生成失败：$streamError');
      } else if (!_stopRequested && mounted) {
        HiDialog.showSnackBar(context, 'AI 未返回可保存的内容');
      }
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, '生成失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _runningWorkflow = null;
          _workflowStatus = '';
          _stopRequested = false;
        });
      }
    }
  }

  void _stopWorkflow() {
    if (_runningWorkflow == null) return;
    _stopRequested = true;
    final sub = _activeWorkflowSub;
    if (sub != null) unawaited(sub.cancel());
    final done = _activeWorkflowDone;
    if (done != null && !done.isCompleted) done.complete();
    if (mounted) setState(() => _workflowStatus = '正在停止...');
  }

  Future<void> _recordWorkflowUsage({
    required AISettings settings,
    required StoryAiWorkflowRequest request,
    required String completion,
    int? promptTokens,
    int? cachedPromptTokens,
    int? completionTokens,
    required bool estimated,
    required int createdAt,
  }) async {
    final recorder = _usageRecordService;
    final modelId = settings.effectiveModel.trim();
    if (recorder == null || modelId.isEmpty) return;
    try {
      await recorder.recordTurn(
        modelId: modelId,
        providerId:
            settings.mode == AIMode.local ? settings.activeProviderId : null,
        projectId: null,
        cid: null,
        prompt: request.usagePrompt,
        completion: completion,
        promptTokens: promptTokens,
        cachedPromptTokens: cachedPromptTokens,
        completionTokens: completionTokens,
        estimated: estimated,
        costConfig: settings.usageCostConfig,
        createdAt: createdAt,
      );
    } catch (_) {
      // 用量记录失败不能阻断工作流结果。
    }
  }

  Future<void> _previewWorkflowResult({
    required StoryAiWorkflowRequest request,
    required String content,
    required bool stopped,
    required int createdAt,
  }) async {
    final artifacts = await _dao?.getArtifacts(widget.room.id!) ?? _artifacts;
    if (!mounted) return;
    final maxOrder = artifacts.fold<int>(
      0,
      (value, item) => item.sortOrder > value ? item.sortOrder : value,
    );
    final initial = StoryAiWorkflowService.resultArtifact(
      request: request,
      roomId: widget.room.id!,
      sortOrder: maxOrder + 1,
      content: content,
      stopped: stopped,
      createdAt: createdAt,
    );
    final artifact = await showDialog<StoryArtifactModel>(
      context: context,
      builder: (ctx) => _StoryWorkflowResultDialog(
        initial: initial,
        stopped: stopped,
      ),
    );
    if (artifact == null) return;
    await _dao?.saveArtifact(artifact);
    await _syncRoomContext();
    await _load();
    if (mounted) HiDialog.showSnackBar(context, '已保存为创作资料');
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

class _StoryWorkflowResultDialog extends StatefulWidget {
  final StoryArtifactModel initial;
  final bool stopped;

  const _StoryWorkflowResultDialog({
    required this.initial,
    required this.stopped,
  });

  @override
  State<_StoryWorkflowResultDialog> createState() =>
      _StoryWorkflowResultDialogState();
}

class _StoryWorkflowResultDialogState
    extends State<_StoryWorkflowResultDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initial.title);
    _contentController = TextEditingController(text: widget.initial.content);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.stopped ? '预览已生成内容' : '预览审阅结果'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: '资料标题',
                  border: storyInputBorder(context),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _contentController,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    labelText: '审阅内容',
                    border: storyInputBorder(context),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () {
            final title = _titleController.text.trim();
            final content = _contentController.text.trim();
            if (title.isEmpty || content.isEmpty) return;
            Navigator.pop(
              context,
              widget.initial
                ..title = title
                ..content = content,
            );
          },
          child: const Text('保存为资料'),
        ),
      ],
    );
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
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: InputDecoration(
                  labelText: '类型',
                  border: storyInputBorder(context),
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
                decoration: InputDecoration(
                  labelText: '标题',
                  border: storyInputBorder(context),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _statusController,
                decoration: InputDecoration(
                  labelText: '状态',
                  hintText: '例如：草稿、进行中、已回收',
                  border: storyInputBorder(context),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                minLines: 8,
                maxLines: 16,
                decoration: InputDecoration(
                  labelText: '内容',
                  border: storyInputBorder(context),
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
