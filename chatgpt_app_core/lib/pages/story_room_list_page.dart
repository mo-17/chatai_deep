import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/translation_task_log_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

final _storyTemplateTranslationCoordinator =
    StoryTemplateTranslationCoordinator.instance;

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
  final Set<int> _observedCompletedTemplateTaskIds = <int>{};
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
    final newCompleted = _storyTemplateTranslationCoordinator.tasks
        .where((task) =>
            task.status == StoryTemplateTranslationTaskStatus.completed &&
            task.id != null)
        .map((task) => task.id!)
        .where(_observedCompletedTemplateTaskIds.add)
        .isNotEmpty;
    if (newCompleted) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final db = await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryRoomDao.create(db);
    final templateDao = await StoryTemplateDao.create(db);
    await _storyTemplateTranslationCoordinator.initialize(
      db,
      accountHash: HiDBManager.getAccountHash(),
    );
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
      appBar: AppBar(
        title: const Text('创作 / 酒馆'),
        actions: [
          if (_tabIndex == 1 && Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: '导入本 App 导出的酒馆模板',
              onPressed: _importTemplate,
            ),
        ],
      ),
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
        onPressed: _tabIndex == 0 ? _showCreateRoomSheet : _showTemplateActions,
        tooltip: _tabIndex == 0 ? '新建房间' : '模板操作',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildTemplateTranslationJobs() {
    final jobs = _storyTemplateTranslationCoordinator.tasks;
    if (jobs.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final job in jobs.take(3))
          _StoryTemplateTranslationJobTile(
            job: job,
            onShowLog: () => _showTemplateTranslationLog(job),
            onRetry: job.canRetry ? () => _retryTemplateTranslation(job) : null,
            onCancel: job.isRunning
                ? () => _storyTemplateTranslationCoordinator.cancel(job)
                : null,
            onDismiss: job.isTerminal
                ? () => _storyTemplateTranslationCoordinator.dismiss(job)
                : null,
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
                } else if (value == 'edit') {
                  _editTemplate(template);
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
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.tune_outlined),
                      SizedBox(width: 8),
                      Text('完整编辑'),
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
            onTap: () => _editTemplate(template),
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

  Future<void> _showTemplateActions() async {
    final action = await showModalBottomSheet<String>(
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
                  child: Icon(Icons.note_add_outlined),
                ),
                title: const Text('新建酒馆模板'),
                subtitle: const Text('从一个空白角色开始配置'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
              if (Platform.operatingSystem != 'ohos')
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.file_upload_outlined),
                  ),
                  title: const Text('导入酒馆模板'),
                  subtitle: const Text('仅支持本 App 导出的 JSON 文件'),
                  onTap: () => Navigator.pop(ctx, 'import'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == 'new') await _createEmptyTemplate();
    if (action == 'import') await _importTemplate();
  }

  Future<void> _createEmptyTemplate() async {
    final template = StoryRoomTemplatePayload(
      results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: '新角色'),
        ),
      ],
    ).toTemplate(title: '未命名酒馆模板');
    await _editTemplate(template, creating: true);
  }

  Future<void> _importTemplate() async {
    final dao = _templateDao;
    if (dao == null) return;
    if (Platform.operatingSystem == 'ohos') {
      HiDialog.showSnackBar(context, '鸿蒙版本暂不支持模板文件选择');
      return;
    }
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: '选择本 App 导出的酒馆模板',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final file = picked?.files.single;
      if (file == null) return;
      final bytes = file.bytes;
      final content = bytes != null
          ? utf8.decode(bytes)
          : file.path != null
              ? await File(file.path!).readAsString()
              : null;
      if (content == null) {
        throw const FormatException('无法读取选中的模板文件');
      }
      final imported = StoryTemplateTransfer.importJson(content);
      final originalTitle = imported.title;
      imported.title = StoryTemplateTransfer.uniqueTitle(
        originalTitle,
        (await dao.getTemplates()).map((item) => item.title),
      );
      await dao.saveTemplate(imported);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      final renamed = imported.title != originalTitle;
      HiDialog.showSnackBar(
        context,
        renamed ? '模板重名，已导入为「${imported.title}」' : '已导入模板「${imported.title}」',
      );
    } catch (error) {
      if (!mounted) return;
      final message =
          error is FormatException ? error.message : '导入模板失败：$error';
      HiDialog.showSnackBar(context, message);
    }
  }

  Future<void> _editTemplate(
    StoryTemplateModel template, {
    bool creating = false,
  }) async {
    final dao = _templateDao;
    if (dao == null) return;
    try {
      final payload = StoryRoomTemplatePayload.fromTemplate(template);
      if (payload.results.isEmpty) {
        throw const FormatException('酒馆模板至少需要一个角色');
      }
      final result = await Navigator.push<StoryTemplateModel>(
        context,
        MaterialPageRoute(
          builder: (_) => _StoryTemplateEditorPage(
            template: template,
            payload: payload,
          ),
        ),
      );
      if (result == null) return;
      if (creating) {
        result.title = StoryTemplateTransfer.uniqueTitle(
          result.title,
          (await dao.getTemplates()).map((item) => item.title),
        );
      }
      await dao.saveTemplate(result);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      HiDialog.showSnackBar(context, creating ? '已创建模板' : '模板已保存');
    } catch (error) {
      if (!mounted) return;
      final message =
          error is FormatException ? error.message : '编辑模板失败：$error';
      HiDialog.showSnackBar(context, message);
    }
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
      modelProviderId: room.modelProviderId,
      modelId: room.modelId,
      temperature: room.temperature,
      maxOutputTokens: room.maxOutputTokens,
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
      promptConfigJson: payload.promptConfigJson,
      quickRepliesJson: payload.quickRepliesJson,
      regexScriptsJson: payload.regexScriptsJson,
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
      final body = StoryTemplateTransfer.exportJson(template);
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
    try {
      StoryRoomTemplatePayload.fromTemplate(template);
    } catch (e) {
      HiDialog.showSnackBar(context, '模板数据异常：$e');
      return;
    }
    if (_templateRoleCount(template) <= 1) {
      HiDialog.showSnackBar(context, '单角色模板不需要生成中文副本');
      return;
    }
    final settings = context.read<AISettingsProvider>().settings.clone();
    final chatService = ChatService.from(settings);
    try {
      await _storyTemplateTranslationCoordinator.start(
        template,
        complete: (prompt) async {
          final response = await chatService.chat(
            prompt: prompt,
            history: const [],
            timeout: const Duration(minutes: 2),
          );
          if (response == null || response.trim().isEmpty) {
            throw StateError('翻译服务未返回内容');
          }
          return response;
        },
      );
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已加入后台任务，可在当前页面查看进度');
    } catch (error) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '创建翻译任务失败：$error');
    }
  }

  Future<void> _retryTemplateTranslation(
    StoryTemplateTranslationTaskModel task,
  ) async {
    final settings = context.read<AISettingsProvider>().settings.clone();
    final chatService = ChatService.from(settings);
    await _storyTemplateTranslationCoordinator.retry(
      task,
      complete: (prompt) async {
        final response = await chatService.chat(
          prompt: prompt,
          history: const [],
          timeout: const Duration(minutes: 2),
        );
        if (response == null || response.trim().isEmpty) {
          throw StateError('翻译服务未返回内容');
        }
        return response;
      },
    );
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

  void _showTemplateTranslationLog(StoryTemplateTranslationTaskModel job) {
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

// ignore: unused_element
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
        promptConfigJson: payload.promptConfigJson,
        quickRepliesJson: payload.quickRepliesJson,
        regexScriptsJson: payload.regexScriptsJson,
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

// ignore: unused_element
class _LegacyStoryTemplateTranslationJobTile extends StatelessWidget {
  final _StoryTemplateTranslationJob job;
  final VoidCallback onShowLog;
  final VoidCallback onDismiss;

  const _LegacyStoryTemplateTranslationJobTile({
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

class _StoryTemplateTranslationJobTile extends StatelessWidget {
  final StoryTemplateTranslationTaskModel job;
  final VoidCallback onShowLog;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onDismiss;

  const _StoryTemplateTranslationJobTile({
    required this.job,
    required this.onShowLog,
    this.onRetry,
    this.onCancel,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final failed = job.status == StoryTemplateTranslationTaskStatus.failed;
    final completed =
        job.status == StoryTemplateTranslationTaskStatus.completed;
    final cancelled =
        job.status == StoryTemplateTranslationTaskStatus.cancelled;
    final color = failed
        ? Colors.red[700]
        : completed
            ? Colors.green[700]
            : cancelled
                ? Colors.grey[700]
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
                  : cancelled
                      ? Icons.cancel_outlined
                      : Icons.translate_outlined,
          color: color,
        ),
      ),
      title: Text(
        job.outputTitle.trim().isEmpty ? job.sourceTitle : job.outputTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              StoryTemplateTranslationTaskStatus.labelOf(job.status),
              job.stage,
              if (job.detail.trim().isNotEmpty) job.detail.trim(),
            ].where((item) => item.trim().isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: job.progress.clamp(0, 1).toDouble(),
            minHeight: 3,
            backgroundColor: Colors.black12,
            color: color,
          ),
          if (job.fieldLabel.trim().isNotEmpty)
            Text(
              [
                if (job.roleName.trim().isNotEmpty) job.roleName.trim(),
                job.fieldLabel.trim(),
                if (job.fieldTotal > 1) '${job.fieldIndex}/${job.fieldTotal}',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '任务操作',
        onSelected: (value) {
          if (value == 'log') onShowLog();
          if (value == 'retry') onRetry?.call();
          if (value == 'cancel') onCancel?.call();
          if (value == 'dismiss') onDismiss?.call();
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'log',
            child: Row(
              children: [
                Icon(Icons.article_outlined),
                SizedBox(width: 8),
                Text('查看日志'),
              ],
            ),
          ),
          if (onRetry != null)
            const PopupMenuItem(
              value: 'retry',
              child: Row(
                children: [
                  Icon(Icons.refresh),
                  SizedBox(width: 8),
                  Text('重试'),
                ],
              ),
            ),
          if (onCancel != null)
            const PopupMenuItem(
              value: 'cancel',
              child: Row(
                children: [
                  Icon(Icons.stop_circle_outlined),
                  SizedBox(width: 8),
                  Text('取消'),
                ],
              ),
            ),
          if (onDismiss != null)
            const PopupMenuItem(
              value: 'dismiss',
              child: Row(
                children: [
                  Icon(Icons.close),
                  SizedBox(width: 8),
                  Text('移除记录'),
                ],
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

class _StoryTemplateEditorPage extends StatefulWidget {
  final StoryTemplateModel template;
  final StoryRoomTemplatePayload payload;

  const _StoryTemplateEditorPage({
    required this.template,
    required this.payload,
  });

  @override
  State<_StoryTemplateEditorPage> createState() =>
      _StoryTemplateEditorPageState();
}

class _StoryTemplateEditorPageState extends State<_StoryTemplateEditorPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _openingController;
  late List<AssistantRoleCardImportResult> _roles;
  late List<int> _roleKeys;
  int _nextRoleKey = 0;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.template.title);
    _openingController = TextEditingController(
      text: widget.payload.initialOpening,
    );
    _roles = widget.payload.results.map(_copyRole).toList(growable: true);
    _roleKeys = List<int>.generate(_roles.length, (_) => _nextRoleKey++);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _openingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑酒馆模板'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存模板',
            onPressed: _save,
          ),
        ],
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        header: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _titleController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '模板名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _openingController,
                minLines: 3,
                maxLines: 7,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  labelText: '房间开场（优先显示）',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text('角色（${_roles.length}）',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
            ],
          ),
        ),
        footer: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('添加角色'),
            onPressed: _addRole,
          ),
        ),
        itemCount: _roles.length,
        onReorder: _reorder,
        itemBuilder: (context, index) {
          final role = _roles[index];
          final assistant = role.assistant;
          final subtitle = <String>[
            if (assistant.description.trim().isNotEmpty)
              assistant.description.trim(),
            if (assistant.openingMessage.trim().isNotEmpty) '有角色开场',
            if (assistant.memoryBook.trim().isNotEmpty) '有世界书',
          ].join(' · ');
          return ListTile(
            key: ValueKey(_roleKeys[index]),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: CircleAvatar(
              child: Text(
                '${index + 1}',
                style: const TextStyle(fontSize: 14),
              ),
            ),
            title: Text(
              assistant.name.trim().isEmpty ? '未命名角色' : assistant.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: subtitle.isEmpty
                ? const Text('点击编辑角色资料')
                : Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _editRole(index),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: _roles.length == 1 ? '模板至少保留一个角色' : '删除角色',
                  onPressed:
                      _roles.length == 1 ? null : () => _deleteRole(index),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _addRole() async {
    final result = await Navigator.push<AssistantRoleCardImportResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _StoryTemplateRoleEditorPage(
          role: AssistantRoleCardImportResult(
            assistant: AssistantModel(name: '新角色'),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _roles.add(result);
      _roleKeys.add(_nextRoleKey++);
    });
  }

  Future<void> _editRole(int index) async {
    final result = await Navigator.push<AssistantRoleCardImportResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _StoryTemplateRoleEditorPage(role: _roles[index]),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _roles[index] = result);
  }

  void _deleteRole(int index) {
    if (_roles.length <= 1) {
      HiDialog.showSnackBar(context, '模板至少保留一个角色');
      return;
    }
    setState(() {
      _roles.removeAt(index);
      _roleKeys.removeAt(index);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      _roles.insert(newIndex, _roles.removeAt(oldIndex));
      _roleKeys.insert(newIndex, _roleKeys.removeAt(oldIndex));
    });
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      HiDialog.showSnackBar(context, '请填写模板名称');
      return;
    }
    if (_roles.isEmpty) {
      HiDialog.showSnackBar(context, '模板至少保留一个角色');
      return;
    }
    if (_roles.any((role) => role.assistant.name.trim().isEmpty)) {
      HiDialog.showSnackBar(context, '每个角色都需要名称');
      return;
    }
    final result = StoryTemplateModel(
      id: widget.template.id,
      title: title,
      sourceTitle: widget.template.sourceTitle,
      kind: widget.template.kind,
      translated: widget.template.translated,
      payload: jsonEncode(
        StoryRoomTemplatePayload(
          results: _roles,
          initialOpening: _openingController.text.trim(),
          promptConfigJson: widget.payload.promptConfigJson,
          quickRepliesJson: widget.payload.quickRepliesJson,
          regexScriptsJson: widget.payload.regexScriptsJson,
        ).toJson(),
      ),
      createdAt: widget.template.createdAt,
      updatedAt: widget.template.updatedAt,
    );
    Navigator.pop(context, result);
  }

  static AssistantRoleCardImportResult _copyRole(
    AssistantRoleCardImportResult role,
  ) =>
      AssistantRoleCardImportResult(
        assistant: AssistantModel.fromJson(
          Map<String, dynamic>.from(role.assistant.toJson()),
        ),
        avatarPngBytes: role.avatarPngBytes,
        sourceName: role.sourceName,
        tavernMeta: role.tavernMeta,
      );
}

class _StoryTemplateRoleEditorPage extends StatefulWidget {
  final AssistantRoleCardImportResult role;

  const _StoryTemplateRoleEditorPage({required this.role});

  @override
  State<_StoryTemplateRoleEditorPage> createState() =>
      _StoryTemplateRoleEditorPageState();
}

class _StoryTemplateRoleEditorPageState
    extends State<_StoryTemplateRoleEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _promptController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _avatarController;
  late final TextEditingController _openingController;
  late final TextEditingController _examplesController;
  late final TextEditingController _worldBookController;

  @override
  void initState() {
    super.initState();
    final assistant = widget.role.assistant;
    _nameController = TextEditingController(text: assistant.name);
    _promptController = TextEditingController(text: assistant.prompt);
    _descriptionController = TextEditingController(text: assistant.description);
    _avatarController =
        TextEditingController(text: assistant.avatarValue ?? '');
    _openingController = TextEditingController(text: assistant.openingMessage);
    _examplesController = TextEditingController(text: assistant.exampleDialogs);
    _worldBookController = TextEditingController(text: assistant.memoryBook);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    _descriptionController.dispose();
    _avatarController.dispose();
    _openingController.dispose();
    _examplesController.dispose();
    _worldBookController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑角色'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存角色',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _field(_nameController, '角色名称', maxLines: 1),
          _field(_descriptionController, '简介', minLines: 2, maxLines: 5),
          _field(_avatarController, '头像引用（本地路径或 URL）', maxLines: 1),
          _field(_promptController, '人设（系统提示）', minLines: 5, maxLines: 12),
          _field(_openingController, '角色开场', minLines: 3, maxLines: 8),
          _field(_examplesController, '示例对话', minLines: 4, maxLines: 12),
          _field(_worldBookController, '世界书', minLines: 5, maxLines: 14),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int minLines = 1,
    int? maxLines,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: controller,
          minLines: minLines,
          maxLines: maxLines ?? minLines,
          textInputAction:
              minLines == 1 ? TextInputAction.next : TextInputAction.newline,
          decoration: InputDecoration(
            labelText: label,
            alignLabelWithHint: minLines > 1,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      HiDialog.showSnackBar(context, '请填写角色名称');
      return;
    }
    final assistant = AssistantModel.fromJson(
      Map<String, dynamic>.from(widget.role.assistant.toJson()),
    )
      ..name = name
      ..description = _descriptionController.text.trim()
      ..prompt = _promptController.text.trim()
      ..openingMessage = _openingController.text.trim()
      ..exampleDialogs = _examplesController.text.trim()
      ..memoryBook = _worldBookController.text.trim();
    final avatar = _avatarController.text.trim();
    assistant.avatarValue = avatar.isEmpty ? null : avatar;
    if (avatar.isEmpty) {
      assistant.avatarType = null;
    } else if ((assistant.avatarType ?? '').trim().isEmpty) {
      assistant.avatarType = 'image';
    }
    Navigator.pop(
      context,
      AssistantRoleCardImportResult(
        assistant: assistant,
        avatarPngBytes: widget.role.avatarPngBytes,
        sourceName: widget.role.sourceName,
        tavernMeta: widget.role.tavernMeta,
      ),
    );
  }
}
