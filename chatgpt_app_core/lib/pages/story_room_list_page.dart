import 'dart:async';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
                } else if (value == 'translate_copy') {
                  _translateTemplateAsSimplifiedCopy(template);
                } else if (value == 'delete') {
                  _deleteTemplate(template);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'create',
                  child: Row(
                    children: [
                      Icon(Icons.add_circle_outline),
                      SizedBox(width: 8),
                      Text('开新房间'),
                    ],
                  ),
                ),
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
                  value: 'opening',
                  child: Row(
                    children: [
                      Icon(Icons.edit_note_outlined),
                      SizedBox(width: 8),
                      Text('编辑开场'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'translate_copy',
                  child: Row(
                    children: [
                      Icon(Icons.translate_outlined),
                      SizedBox(width: 8),
                      Text('生成中文副本'),
                    ],
                  ),
                ),
                PopupMenuItem(
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
      final payload = StoryRoomTemplatePayload.fromTemplate(template);
      final count = payload.results.length;
      if (count <= 0) return '无角色';
      return '$count 个角色';
    } catch (_) {
      return '模板数据异常';
    }
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

  Future<void> _translateTemplateAsSimplifiedCopy(
    StoryTemplateModel template,
  ) async {
    final dao = _templateDao;
    if (dao == null) return;
    late final StoryRoomTemplatePayload payload;
    try {
      payload = StoryRoomTemplatePayload.fromTemplate(template);
    } catch (e) {
      HiDialog.showSnackBar(context, '模板数据异常：$e');
      return;
    }
    if (payload.results.isEmpty) {
      HiDialog.showSnackBar(context, '模板没有可翻译的角色');
      return;
    }

    final hasOpening = payload.initialOpening.trim().isNotEmpty;
    final totalSteps = payload.results.length + (hasOpening ? 1 : 0);
    final progress = ValueNotifier<_TemplateTranslationProgress>(
      _TemplateTranslationProgress(
        current: 0,
        total: totalSteps,
        name: template.title,
        stage: '准备翻译',
      ),
    );
    if (!mounted) return;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _TemplateTranslationProgressDialog(progress: progress),
    ));

    try {
      final settings = context.read<AISettingsProvider>().settings.clone();
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
          progress.value = _TemplateTranslationProgress(
            current: value.current,
            total: totalSteps,
            name: value.name,
            stage: value.stage,
          );
        },
      );

      var translatedOpening = payload.initialOpening;
      if (hasOpening) {
        progress.value = _TemplateTranslationProgress(
          current: payload.results.length + 1,
          total: totalSteps,
          name: '模板开场',
          stage: '正在翻译开场',
        );
        translatedOpening = await _translateTemplateOpening(
          payload.initialOpening,
          chatService,
          template.title,
        );
      }

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
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已生成中文副本「$title」');
    } on FormatException catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '生成中文副本失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '生成中文副本失败：$e');
    } finally {
      if (mounted) {
        await Navigator.of(context, rootNavigator: true).maybePop();
      }
      progress.dispose();
    }
  }

  Future<String> _translateTemplateOpening(
    String opening,
    ChatService chatService,
    String templateTitle,
  ) async {
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
      );
      final translated = assistant.openingMessage.trim();
      return translated.isEmpty ? opening : translated;
    } catch (_) {
      return opening;
    }
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
}

class _TemplateTranslationProgress {
  final int current;
  final int total;
  final String name;
  final String stage;

  const _TemplateTranslationProgress({
    required this.current,
    required this.total,
    required this.name,
    required this.stage,
  });
}

class _TemplateTranslationProgressDialog extends StatelessWidget {
  final ValueListenable<_TemplateTranslationProgress> progress;

  const _TemplateTranslationProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在生成中文副本'),
      content: ValueListenableBuilder<_TemplateTranslationProgress>(
        valueListenable: progress,
        builder: (context, value, _) {
          final ratio = value.total <= 0
              ? 0.0
              : (value.current / value.total).clamp(0, 1).toDouble();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value.name.trim().isEmpty ? '未命名模板' : value.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '${value.stage} · ${value.current}/${value.total}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: ratio),
            ],
          );
        },
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
