import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/translation_task_log_dialog.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

final _storyTemplateTranslationCoordinator =
    _StoryTemplateTranslationCoordinator();

class StoryRoomListPage extends StatefulWidget {
  const StoryRoomListPage({super.key});

  @override
  State<StoryRoomListPage> createState() => _StoryRoomListPageState();
}

class _StoryRoomListPageState extends State<StoryRoomListPage> {
  StoryRoomDao? _dao;
  StoryTemplateDao? _templateDao;
  List<StoryRoomModel> _rooms = const [];
  List<StoryTemplateModel> _templates = const [];
  int _tabIndex = 0;
  int _lastTemplateTranslationCompletedTick = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _storyTemplateTranslationCoordinator
        .addListener(_handleTemplateTranslationChanged);
    _load();
  }

  @override
  void dispose() {
    _storyTemplateTranslationCoordinator
        .removeListener(_handleTemplateTranslationChanged);
    super.dispose();
  }

  void _handleTemplateTranslationChanged() {
    if (!mounted) return;
    setState(() {});
    final completedTick = _storyTemplateTranslationCoordinator.completedTick;
    if (completedTick != _lastTemplateTranslationCompletedTick) {
      _lastTemplateTranslationCompletedTick = completedTick;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final db = await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryRoomDao.create(db);
    final templateDao = await StoryTemplateDao.create(db);
    final rooms = await dao.getRooms();
    final templates = await templateDao.getTemplates();
    if (!mounted) return;
    setState(() {
      _dao = dao;
      _templateDao = templateDao;
      _rooms = rooms;
      _templates = templates;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创作 / 酒馆')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.meeting_room_outlined),
                        label: Text('房间'),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.inventory_2_outlined),
                        label: Text('模板'),
                      ),
                    ],
                    selected: {_tabIndex},
                    onSelectionChanged: (value) {
                      setState(() => _tabIndex = value.first);
                    },
                  ),
                ),
                _buildTemplateTranslationJobs(),
                Expanded(
                  child:
                      _tabIndex == 0 ? _buildRoomList() : _buildTemplateList(),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _tabIndex == 0 ? _showCreateRoomSheet : _showTemplateHint,
        child: Icon(_tabIndex == 0 ? Icons.add : Icons.info_outline),
      ),
    );
  }

  Widget _buildTemplateTranslationJobs() {
    final jobs = _storyTemplateTranslationCoordinator.jobs;
    if (jobs.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final job in jobs.take(3))
          _StoryTemplateTranslationJobTile(
            job: job,
            onShowLog: () => _showTemplateTranslationLog(job),
            onDismiss: () => _storyTemplateTranslationCoordinator.dismiss(job),
          ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildRoomList() {
    if (_rooms.isEmpty) {
      return const Center(child: Text('暂无创作房间'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _rooms.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, index) {
          final room = _rooms[index];
          return ListTile(
            leading: CircleAvatar(
              child: Icon(room.mode == StoryRoomMode.tavern
                  ? Icons.forum_outlined
                  : Icons.theater_comedy_outlined),
            ),
            title:
                Text(room.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              room.publicContext.isEmpty
                  ? StoryRoomMode.labelOf(room.mode)
                  : '${StoryRoomMode.labelOf(room.mode)} · ${room.publicContext}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: '房间操作',
              onSelected: (value) {
                if (value == 'rename') {
                  _renameRoom(room);
                } else if (value == 'delete') {
                  _deleteRoom(room);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_rename_outline),
                      SizedBox(width: 8),
                      Text('重命名'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline),
                      SizedBox(width: 8),
                      Text('删除'),
                    ],
                  ),
                ),
              ],
            ),
            onTap: () => _openRoom(room),
          );
        },
      ),
    );
  }

  Widget _buildTemplateList() {
    if (_templates.isEmpty) {
      return const Center(child: Text('暂无酒馆模板'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _templates.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, index) {
          final template = _templates[index];
          final canTranslateCopy = _isMultiRoleTemplate(template);
          return ListTile(
            leading: const CircleAvatar(
              child: Icon(Icons.inventory_2_outlined),
            ),
            title: Text(
              template.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _templateSubtitle(template),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: '模板操作',
              onSelected: (value) {
                if (value == 'create') {
                  _createRoomFromTemplate(template);
                } else if (value == 'rename') {
                  _renameTemplate(template);
                } else if (value == 'opening') {
                  _editTemplateOpening(template);
                } else if (value == 'export') {
                  _exportTemplate(template);
                } else if (value == 'translate_copy') {
                  _translateTemplateAsSimplifiedCopy(template);
                } else if (value == 'delete') {
                  _deleteTemplate(template);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'create',
                  child: Row(
                    children: [
                      Icon(Icons.add_circle_outline),
                      SizedBox(width: 8),
                      Text('开新房间'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_rename_outline),
                      SizedBox(width: 8),
                      Text('重命名'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'opening',
                  child: Row(
                    children: [
                      Icon(Icons.edit_note_outlined),
                      SizedBox(width: 8),
                      Text('编辑开场'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'export',
                  child: Row(
                    children: [
                      Icon(Icons.ios_share_outlined),
                      SizedBox(width: 8),
                      Text('导出模板'),
                    ],
                  ),
                ),
                if (canTranslateCopy)
                  const PopupMenuItem(
                    value: 'translate_copy',
                    child: Row(
                      children: [
                        Icon(Icons.translate_outlined),
                        SizedBox(width: 8),
                        Text('生成中文副本'),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline),
                      SizedBox(width: 8),
                      Text('删除模板'),
                    ],
                  ),
                ),
              ],
            ),
            onTap: () => _createRoomFromTemplate(template),
          );
        },
      ),
    );
  }

  String _templateSubtitle(StoryTemplateModel template) {
    final parts = <String>[
      _templateRoleCountText(template),
      template.translated ? '已翻译' : '未翻译',
      _templateOpeningText(template),
      if (template.sourceTitle.trim().isNotEmpty) template.sourceTitle.trim(),
    ];
    return parts.join(' · ');
  }

  String _templateOpeningText(StoryTemplateModel template) {
    try {
      final opening =
          StoryRoomTemplatePayload.fromTemplate(template).initialOpening.trim();
      if (opening.isEmpty) return '无开场';
      return '开场 ${opening.length} 字';
    } catch (_) {
      return '开场异常';
    }
  }

  String _templateRoleCountText(StoryTemplateModel template) {
    try {
      final count = _templateRoleCount(template);
      if (count <= 0) return '无角色';
      return '$count 个角色';
    } catch (_) {
      return '模板数据异常';
    }
  }

  bool _isMultiRoleTemplate(StoryTemplateModel template) {
    try {
      return _templateRoleCount(template) > 1;
    } catch (_) {
      return false;
    }
  }

  int _templateRoleCount(StoryTemplateModel template) {
    final payload = StoryRoomTemplatePayload.fromTemplate(template);
    return StoryRoomRoleCardImporter.countTemplateParticipants(
      payload,
      title: template.title,
    );
  }

  void _showTemplateHint() {
    HiDialog.showSnackBar(context, '请从助手管理导入角色卡，选择「酒馆房间」后会自动保存模板');
  }

  Future<void> _showCreateRoomSheet() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.theater_comedy_outlined),
                ),
                title: const Text('新建创作房间'),
                subtitle: const Text('适合小说写作，默认包含作者和旁白'),
                onTap: () => Navigator.pop(ctx, StoryRoomMode.creation),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.forum_outlined),
                ),
                title: const Text('新建酒馆房间'),
                subtitle: const Text('适合角色扮演，只使用角色卡参与对话'),
                onTap: () => Navigator.pop(ctx, StoryRoomMode.tavern),
              ),
            ],
          ),
        ),
      ),
    );
    if (mode == null) return;
    await _createRoom(mode);
  }

  Future<void> _createRoom(String mode) async {
    final dao = _dao;
    if (dao == null) return;
    final isTavern = mode == StoryRoomMode.tavern;
    final room = StoryRoomModel(
      title: isTavern ? '新的酒馆房间' : '新的创作房间',
      mode: mode,
      replyMode: isTavern ? StoryReplyMode.autoSingle : StoryReplyMode.manual,
      maxAutoReplies: 1,
      publicContext: isTavern
          ? '在这里写角色关系、当前场景、已发生事件或对话规则。'
          : '在这里写公共世界观、当前章节、场景、时间线或写作要求。',
    );
    await dao.saveRoom(room);
    if (!isTavern) {
      await _seedDefaultParticipants(dao, room.id!);
    }
    if (!mounted) return;
    await _openRoom(room);
    await _load();
  }

  Future<void> _seedDefaultParticipants(StoryRoomDao dao, int roomId) async {
    await dao.saveParticipant(StoryParticipantModel(
      roomId: roomId,
      role: StoryParticipantRole.author,
      name: '作者',
      sortOrder: 0,
    ));
    await dao.saveParticipant(StoryParticipantModel(
      roomId: roomId,
      role: StoryParticipantRole.narrator,
      name: '旁白',
      sortOrder: 1,
    ));
  }

  Future<void> _renameRoom(StoryRoomModel room) async {
    final dao = _dao;
    final roomId = room.id;
    if (dao == null || roomId == null) return;
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameRoomDialog(initialTitle: room.title),
    );
    if (title == null || title.isEmpty || title == room.title) return;
    final updated = StoryRoomModel(
      id: roomId,
      title: title,
      mode: room.mode,
      replyMode: room.replyMode,
      maxAutoReplies: room.maxAutoReplies,
      publicContext: room.publicContext,
      createdAt: room.createdAt,
      updatedAt: room.updatedAt,
    );
    try {
      await dao.saveRoom(updated);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '重命名失败：$e');
    }
  }

  Future<void> _deleteRoom(StoryRoomModel room) async {
    final dao = _dao;
    final id = room.id;
    if (dao == null || id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除房间'),
        content: Text('确定删除「${room.title}」吗？房间内的角色和消息也会一起删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await dao.deleteRoom(id);
    if (!mounted) return;
    await _load();
  }

  Future<void> _createRoomFromTemplate(StoryTemplateModel template) async {
    final dao = _dao;
    if (dao == null) return;
    try {
      final existingTitles = (await dao.getRooms()).map((room) => room.title);
      final title = _uniqueName(template.title, existingTitles);
      final importer = StoryRoomRoleCardImportService(dao);
      final roomId = await importer.createRoomFromTemplate(
        template,
        title: title,
      );
      final room = await dao.getRoom(roomId);
      if (!mounted || room == null) return;
      await _openRoom(room);
      await _load();
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '从模板创建房间失败：$e');
    }
  }

  Future<void> _renameTemplate(StoryTemplateModel template) async {
    final dao = _templateDao;
    final id = template.id;
    if (dao == null || id == null) return;
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameRoomDialog(initialTitle: template.title),
    );
    if (title == null || title.isEmpty || title == template.title) return;
    template.title = title;
    try {
      await dao.saveTemplate(template);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '重命名模板失败：$e');
    }
  }

  Future<void> _editTemplateOpening(StoryTemplateModel template) async {
    final dao = _templateDao;
    final id = template.id;
    if (dao == null || id == null) return;
    late final StoryRoomTemplatePayload payload;
    try {
      payload = StoryRoomTemplatePayload.fromTemplate(template);
    } catch (e) {
      HiDialog.showSnackBar(context, '模板数据异常：$e');
      return;
    }
    final opening = await showDialog<String>(
      context: context,
      builder: (_) => _TemplateOpeningDialog(
        initialOpening: payload.initialOpening,
        candidates: _templateOpeningCandidates(payload),
      ),
    );
    if (opening == null) return;
    template.payload = StoryRoomTemplatePayload(
      results: payload.results,
      initialOpening: opening,
    )
        .toTemplate(
          title: template.title,
          sourceTitle: template.sourceTitle,
          translated: template.translated,
        )
        .payload;
    try {
      await dao.saveTemplate(template);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '保存开场失败：$e');
    }
  }

  Future<void> _exportTemplate(StoryTemplateModel template) async {
    try {
      final payload = jsonDecode(template.payload);
      final body = const JsonEncoder.withIndent('  ').convert({
        'format': 'chatai_deep_tavern_template',
        'formatVersion': 1,
        'template': {
          'title': template.title,
          'sourceTitle': template.sourceTitle,
          'kind': template.kind,
          'translated': template.translated,
          'createdAt': template.createdAt,
          'updatedAt': template.updatedAt,
          'payload': payload,
        },
      });
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${_templateExportFilename(template)}');
      await file.writeAsString(body);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
      ));
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '导出模板失败：$e');
    }
  }

  Future<void> _translateTemplateAsSimplifiedCopy(
    StoryTemplateModel template,
  ) async {
    late final StoryRoomTemplatePayload payload;
    try {
      payload = StoryRoomTemplatePayload.fromTemplate(template);
    } catch (e) {
      HiDialog.showSnackBar(context, '模板数据异常：$e');
      return;
    }
    if (_templateRoleCount(template) <= 1) {
      HiDialog.showSnackBar(context, '单角色模板不需要生成中文副本');
      return;
    }
    final settings = context.read<AISettingsProvider>().settings.clone();
    _storyTemplateTranslationCoordinator.start(
      template: template,
      payload: payload,
      settings: settings,
    );
    HiDialog.showSnackBar(context, '已加入后台任务，可在当前页面查看进度');
  }

  List<String> _templateOpeningCandidates(StoryRoomTemplatePayload payload) {
    final seen = <String>{};
    final candidates = <String>[];
    void add(String value) {
      final text = value.trim();
      if (text.isEmpty) return;
      final key = text.replaceAll(RegExp(r'\s+'), '');
      if (seen.add(key)) candidates.add(text);
    }

    add(payload.initialOpening);
    for (final result in payload.results) {
      add(result.assistant.openingMessage);
      for (final item in result.tavernMeta?.alternateGreetings ?? const []) {
        add(item);
      }
      for (final item in AssistantRoleCardService.alternateGreetings(
        result.assistant.exampleDialogs,
      )) {
        add(item);
      }
    }
    return candidates;
  }

  Future<void> _deleteTemplate(StoryTemplateModel template) async {
    final dao = _templateDao;
    final id = template.id;
    if (dao == null || id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('确定删除「${template.title}」吗？已创建的房间不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await dao.deleteTemplate(id);
    if (!mounted) return;
    await _load();
  }

  Future<void> _openRoom(StoryRoomModel room) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StoryRoomPage(room: room)),
    );
  }

  void _showTemplateTranslationLog(_StoryTemplateTranslationJob job) {
    showDialog<void>(
      context: context,
      builder: (ctx) => TranslationTaskLogDialog(
        title: '生成中文副本日志',
        log: job.log,
        error: job.error,
      ),
    );
  }

  static String _uniqueName(String base, Iterable<String> existing) {
    final cleanBase = base.trim().isEmpty ? '新的酒馆房间' : base.trim();
    final taken = existing.toSet();
    if (!taken.contains(cleanBase)) return cleanBase;
    var index = 2;
    while (taken.contains('$cleanBase ($index)')) {
      index++;
    }
    return '$cleanBase ($index)';
  }

  static String _templateExportFilename(StoryTemplateModel template) {
    final name =
        template.title.trim().isEmpty ? 'tavern_template' : template.title;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'tavern_template_$safe.json';
  }
}

enum _StoryTemplateTranslationJobStatus { queued, running, completed, failed }

class _StoryTemplateTranslationJob {
  final String sourceTitle;
  String displayName;
  String stage;
  String detail = '';
  double progress = 0;
  String error = '';
  String log = '';
  _StoryTemplateTranslationJobStatus status =
      _StoryTemplateTranslationJobStatus.queued;

  _StoryTemplateTranslationJob({
    required this.sourceTitle,
    required this.displayName,
    required this.stage,
  });

  bool get failed => status == _StoryTemplateTranslationJobStatus.failed;
  bool get completed => status == _StoryTemplateTranslationJobStatus.completed;
  bool get running => status == _StoryTemplateTranslationJobStatus.running;
}

class _StoryTemplateTranslationCoordinator extends ChangeNotifier {
  final List<_StoryTemplateTranslationJob> _jobs = [];
  int _completedTick = 0;

  List<_StoryTemplateTranslationJob> get jobs => List.unmodifiable(_jobs);
  int get completedTick => _completedTick;

  void start({
    required StoryTemplateModel template,
    required StoryRoomTemplatePayload payload,
    required AISettings settings,
  }) {
    final job = _StoryTemplateTranslationJob(
      sourceTitle: template.title,
      displayName: template.title.trim().isEmpty ? '未命名模板' : template.title,
      stage: '等待生成中文副本',
    );
    _jobs.insert(0, job);
    notifyListeners();
    unawaited(_run(
      job: job,
      template: template,
      payload: payload,
      settings: settings,
    ));
  }

  void dismiss(_StoryTemplateTranslationJob job) {
    if (!_jobs.remove(job)) return;
    notifyListeners();
  }

  Future<void> _run({
    required _StoryTemplateTranslationJob job,
    required StoryTemplateModel template,
    required StoryRoomTemplatePayload payload,
    required AISettings settings,
  }) async {
    try {
      _update(job,
          status: _StoryTemplateTranslationJobStatus.running,
          stage: '初始化翻译引擎',
          progress: 0.04);
      final chatService = ChatService.from(settings);
      final translatedResults = await TavernRoomImportPreparer.prepare(
        payload.results,
        translateToSimplifiedChinese: true,
        complete: (prompt) => chatService.chat(
          prompt: prompt,
          history: const [],
          timeout: const Duration(minutes: 2),
        ),
        onProgress: (value) {
          final ratio = _tavernTranslationProgressRatio(value);
          _update(
            job,
            displayName:
                value.name.trim().isEmpty ? job.sourceTitle : value.name,
            stage: value.stage,
            detail: _tavernImportDetail(value),
            progress: 0.06 + (0.72 * ratio),
          );
        },
      );

      var translatedOpening = payload.initialOpening;
      if (payload.initialOpening.trim().isNotEmpty) {
        _update(
          job,
          displayName: '模板开场',
          stage: '准备翻译模板开场',
          detail: '${payload.initialOpening.length} 字',
          progress: 0.8,
        );
        translatedOpening = await _translateOpening(
          payload.initialOpening,
          chatService,
          template.title,
          onProgress: (value) => _update(
            job,
            stage: value.stage,
            detail: _translationDetail(value),
            progress: 0.8 + (0.1 * value.current / value.total),
          ),
        );
      }

      _update(job, stage: '保存中文副本模板', detail: '', progress: 0.94);
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final dao = await StoryTemplateDao.create(dbManager);
      final existingTitles =
          (await dao.getTemplates()).map((item) => item.title);
      final title = _uniqueName('${template.title}（简中）', existingTitles);
      final copy = StoryRoomTemplatePayload(
        results: translatedResults,
        initialOpening: translatedOpening,
      ).toTemplate(
        title: title,
        sourceTitle: template.sourceTitle.trim().isEmpty
            ? template.title
            : template.sourceTitle,
        translated: true,
      );
      await dao.saveTemplate(copy);
      _update(
        job,
        status: _StoryTemplateTranslationJobStatus.completed,
        displayName: title,
        stage: '已生成中文副本',
        detail: '',
        progress: 1,
      );
      _completedTick += 1;
      notifyListeners();
    } catch (e, stackTrace) {
      _failJob(job, e, stackTrace);
    }
  }

  static Future<String> _translateOpening(
    String opening,
    ChatService chatService,
    String templateTitle, {
    RoleCardTranslationProgressCallback? onProgress,
  }) async {
    try {
      final assistant = await AssistantRoleCardTranslationService
          .translateToSimplifiedChinese(
        AssistantModel(
          name: templateTitle.trim().isEmpty ? '模板开场' : templateTitle,
          openingMessage: opening,
        ),
        complete: (prompt) => chatService.chat(
          prompt: prompt,
          history: const [],
          timeout: const Duration(minutes: 2),
        ),
        onProgress: onProgress,
      );
      final translated = assistant.openingMessage.trim();
      return translated.isEmpty ? opening : translated;
    } catch (_) {
      return opening;
    }
  }

  void _update(
    _StoryTemplateTranslationJob job, {
    _StoryTemplateTranslationJobStatus? status,
    String? displayName,
    String? stage,
    String? detail,
    double? progress,
  }) {
    if (!_jobs.contains(job)) return;
    if (status != null) job.status = status;
    if (displayName != null) job.displayName = displayName;
    if (stage != null) job.stage = stage;
    if (detail != null) job.detail = detail;
    if (progress != null) job.progress = progress.clamp(0, 1).toDouble();
    _appendLog(
      job,
      status: status,
      displayName: displayName,
      stage: stage,
      detail: detail,
      progress: progress,
    );
    notifyListeners();
  }

  void _appendLog(
    _StoryTemplateTranslationJob job, {
    _StoryTemplateTranslationJobStatus? status,
    String? displayName,
    String? stage,
    String? detail,
    double? progress,
  }) {
    final parts = <String>[
      _logTime(),
      if (status != null) _statusLabel(status),
      if (stage != null && stage.trim().isNotEmpty) stage.trim(),
      if (detail != null && detail.trim().isNotEmpty) detail.trim(),
      if (displayName != null && displayName.trim().isNotEmpty)
        '对象：${displayName.trim()}',
      if (progress != null) '进度：${(progress.clamp(0, 1) * 100).round()}%',
    ];
    if (parts.length <= 1) return;
    final line = parts.join(' · ');
    final lines = job.log.split('\n');
    if (lines.isNotEmpty && lines.last == line) return;
    job.log = job.log.trim().isEmpty ? line : '${job.log}\n$line';
    _trimLog(job);
  }

  void _failJob(
    _StoryTemplateTranslationJob job,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!_jobs.contains(job)) return;
    job.status = _StoryTemplateTranslationJobStatus.failed;
    job.stage = '生成中文副本失败';
    job.progress = 1;
    job.error = error is FormatException ? error.message : error.toString();
    final failure = [
      '生成中文副本失败',
      '模板：${job.sourceTitle}',
      '阶段：${job.stage}',
      '错误：$error',
      '',
      stackTrace.toString(),
    ].join('\n');
    job.log = job.log.trim().isEmpty ? failure : '${job.log}\n\n$failure';
    _trimLog(job);
    notifyListeners();
  }

  static void _trimLog(_StoryTemplateTranslationJob job) {
    const maxLines = 500;
    final lines = job.log.split('\n');
    if (lines.length <= maxLines) return;
    job.log = [
      '日志较长，已隐藏前 ${lines.length - maxLines} 行',
      ...lines.skip(lines.length - maxLines),
    ].join('\n');
  }

  static String _logTime() {
    final now = DateTime.now();
    return [
      now.hour.toString().padLeft(2, '0'),
      now.minute.toString().padLeft(2, '0'),
      now.second.toString().padLeft(2, '0'),
    ].join(':');
  }

  static String _statusLabel(_StoryTemplateTranslationJobStatus status) {
    switch (status) {
      case _StoryTemplateTranslationJobStatus.queued:
        return '排队中';
      case _StoryTemplateTranslationJobStatus.running:
        return '运行中';
      case _StoryTemplateTranslationJobStatus.completed:
        return '已完成';
      case _StoryTemplateTranslationJobStatus.failed:
        return '失败';
    }
  }

  static String _translationDetail(RoleCardTranslationProgress value) {
    final parts = <String>[
      if (value.fieldLabel.isNotEmpty) value.fieldLabel,
      if (value.total > 1) '${value.current}/${value.total}',
      if (value.detail.trim().isNotEmpty) value.detail.trim(),
    ];
    return parts.join(' · ');
  }

  static double _tavernTranslationProgressRatio(
    TavernRoomImportProgress value,
  ) {
    if (value.total <= 0) return 0;
    final roleBase = (value.current - 1).clamp(0, value.total) / value.total;
    final fieldRatio = value.fieldTotal <= 0
        ? 0.0
        : ((value.fieldCurrent - 1).clamp(0, value.fieldTotal) +
                value.fieldProgress.clamp(0, 1).toDouble()) /
            value.fieldTotal;
    return (roleBase + (fieldRatio / value.total)).clamp(0, 1).toDouble();
  }

  static String _tavernImportDetail(TavernRoomImportProgress value) {
    final parts = <String>[
      if (value.total > 1) '角色 ${value.current}/${value.total}',
      if (value.fieldLabel.isNotEmpty) value.fieldLabel,
      if (value.fieldTotal > 1) '${value.fieldCurrent}/${value.fieldTotal}',
      if (value.detail.trim().isNotEmpty) value.detail.trim(),
    ];
    return parts.join(' · ');
  }

  static String _uniqueName(String base, Iterable<String> existing) {
    final cleanBase = base.trim().isEmpty ? '酒馆模板（简中）' : base.trim();
    final taken = existing.toSet();
    if (!taken.contains(cleanBase)) return cleanBase;
    var index = 2;
    while (taken.contains('$cleanBase ($index)')) {
      index++;
    }
    return '$cleanBase ($index)';
  }
}

class _StoryTemplateTranslationJobTile extends StatelessWidget {
  final _StoryTemplateTranslationJob job;
  final VoidCallback onShowLog;
  final VoidCallback onDismiss;

  const _StoryTemplateTranslationJobTile({
    required this.job,
    required this.onShowLog,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final failed = job.failed;
    final completed = job.completed;
    final color = failed
        ? Colors.red[700]
        : completed
            ? Colors.green[700]
            : Colors.blueGrey[700];
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        backgroundColor: failed
            ? Colors.red[50]
            : completed
                ? Colors.green[50]
                : Colors.blueGrey[50],
        child: Icon(
          failed
              ? Icons.error_outline
              : completed
                  ? Icons.check
                  : Icons.translate_outlined,
          color: color,
        ),
      ),
      title: Text(
        job.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              job.stage,
              if (job.detail.trim().isNotEmpty) job.detail.trim(),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: failed ? 1 : job.progress.clamp(0, 1).toDouble(),
            minHeight: 3,
            backgroundColor: Colors.black12,
            color: failed ? Colors.red[300] : Colors.blueGrey[400],
          ),
          if (failed && job.error.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              job.error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '任务操作',
        onSelected: (value) {
          if (value == 'log') onShowLog();
          if (value == 'dismiss') onDismiss();
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'log',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.article_outlined),
              title: Text('查看日志'),
            ),
          ),
          if (failed || completed)
            const PopupMenuItem(
              value: 'dismiss',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.close),
                title: Text('移除记录'),
              ),
            ),
        ],
      ),
    );
  }
}

class _RenameRoomDialog extends StatefulWidget {
  final String initialTitle;

  const _RenameRoomDialog({required this.initialTitle});

  @override
  State<_RenameRoomDialog> createState() => _RenameRoomDialogState();
}

class _RenameRoomDialogState extends State<_RenameRoomDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名房间'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '房间名称',
          border: OutlineInputBorder(),
        ),
        onSubmitted: _submit,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _submit(String value) => Navigator.pop(context, value.trim());
}

class _TemplateOpeningDialog extends StatefulWidget {
  final String initialOpening;
  final List<String> candidates;

  const _TemplateOpeningDialog({
    required this.initialOpening,
    required this.candidates,
  });

  @override
  State<_TemplateOpeningDialog> createState() => _TemplateOpeningDialogState();
}

class _TemplateOpeningDialogState extends State<_TemplateOpeningDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialOpening);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑模板开场'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.candidates.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < widget.candidates.length; i++)
                      ActionChip(
                        label: Text('备选 ${i + 1}'),
                        tooltip: widget.candidates[i],
                        onPressed: () {
                          _controller.text = widget.candidates[i];
                          _controller.selection = TextSelection.collapsed(
                            offset: _controller.text.length,
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 6,
                maxLines: 12,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  labelText: '开场内容',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
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
        TextButton(
          onPressed: () => _controller.clear(),
          child: const Text('清空'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
