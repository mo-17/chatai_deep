import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_room_read_aloud_controller.dart';
import 'package:chatgpt_app_core/chat/application/story_room_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_participant_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_speaker_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/pages/story_workbench_page.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class StoryRoomPage extends StatefulWidget {
  final StoryRoomModel room;
  final ReadAloudService? readAloudService;

  const StoryRoomPage({super.key, required this.room, this.readAloudService});

  @override
  State<StoryRoomPage> createState() => _StoryRoomPageState();
}

class _StoryRoomPageState extends State<StoryRoomPage> {
  final _publicContextCtl = TextEditingController();
  StoryRoomDao? _dao;
  UsageRecordService? _usageRecordService;
  List<StoryParticipantModel> _participants = const [];
  List<StoryMessageModel> _messages = const [];
  int? _selectedParticipantId;
  int? _forcedNextParticipantId;
  bool _loading = true;
  bool _sending = false;
  bool _stopRequested = false;
  StreamSubscription<StreamEvent>? _activeReplySub;
  Completer<void>? _activeReplyDone;
  String _generationStatus = '';
  String _inputText = '';
  List<String> _pendingImages = [];
  List<String> _pendingFiles = [];
  final Set<int> _streamingMessageCreatedAt = {};
  late final StoryRoomReadAloudController _readAloudController;

  bool get _isTavern => widget.room.mode == StoryRoomMode.tavern;

  StoryParticipantModel? get _selectedParticipant {
    for (final item in _participants) {
      if (item.id == _selectedParticipantId && item.enabled) return item;
    }
    for (final item in _participants) {
      if (item.enabled) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _readAloudController = StoryRoomReadAloudController(
      service: widget.readAloudService,
    )..addListener(_onReadAloudChanged);
    _publicContextCtl.text = widget.room.publicContext;
    _load();
  }

  @override
  void dispose() {
    unawaited(_activeReplySub?.cancel());
    _readAloudController
      ..removeListener(_onReadAloudChanged)
      ..dispose();
    _publicContextCtl.dispose();
    super.dispose();
  }

  void _onReadAloudChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final db = await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryRoomDao.create(db);
    final usageRecordService = UsageRecordService(await UsageDao.create(db));
    var participants = await dao.getParticipants(
      widget.room.id!,
      includeDisabled: true,
    );
    if (participants.isEmpty && !_isTavern) {
      await _seedDefaultParticipants(dao);
      participants = await dao.getParticipants(
        widget.room.id!,
        includeDisabled: true,
      );
    }
    final messages = await dao.getMessages(widget.room.id!);
    if (!mounted) return;
    setState(() {
      _dao = dao;
      _usageRecordService = usageRecordService;
      _participants = participants;
      _messages = messages;
      final selectedStillEnabled = participants.any(
        (item) => item.id == _selectedParticipantId && item.enabled,
      );
      if (!selectedStillEnabled) {
        _selectedParticipantId = _firstEnabledParticipantId(participants);
      }
      _loading = false;
    });
  }

  static int? _firstEnabledParticipantId(
    List<StoryParticipantModel> participants,
  ) {
    for (final item in participants) {
      if (item.enabled) return item.id;
    }
    return null;
  }

  Future<void> _seedDefaultParticipants(StoryRoomDao dao) async {
    await dao.saveParticipant(StoryParticipantModel(
      roomId: widget.room.id!,
      role: StoryParticipantRole.author,
      name: '作者',
      sortOrder: 0,
    ));
    await dao.saveParticipant(StoryParticipantModel(
      roomId: widget.room.id!,
      role: StoryParticipantRole.narrator,
      name: '旁白',
      sortOrder: 1,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room.title),
        actions: [
          PopupMenuButton<String>(
            tooltip: '房间设置',
            onSelected: (value) {
              if (value == 'context') _editPublicContext();
              if (value == 'participant') _addAssistantParticipant();
              if (value == 'reply') _editTavernReplyMode();
              if (value == 'model') _editRoomModelSettings();
              if (value == 'workbench') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StoryWorkbenchPage(room: widget.room),
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'context',
                child: ListTile(
                  leading: Icon(Icons.notes_outlined),
                  title: Text('公共上下文'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'participant',
                child: ListTile(
                  leading: Icon(Icons.person_add_alt_1_outlined),
                  title: Text('添加角色'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (_isTavern)
                const PopupMenuItem(
                  value: 'reply',
                  child: ListTile(
                    leading: Icon(Icons.forum_outlined),
                    title: Text('发言模式'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem(
                value: 'model',
                child: ListTile(
                  leading: Icon(Icons.tune_outlined),
                  title: Text('模型与生成参数'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (!_isTavern)
                const PopupMenuItem(
                  value: 'workbench',
                  child: ListTile(
                    leading: Icon(Icons.dashboard_customize_outlined),
                    title: Text('创作工作台'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _participantStrip,
                const Divider(height: 1),
                Expanded(child: _messageList),
                const Divider(height: 1),
                _composer,
              ],
            ),
    );
  }

  Widget get _participantStrip {
    return SizedBox(
      height: 74,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: _participants.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final item = _participants[index];
          final selected = item.id == _selectedParticipant?.id;
          return Opacity(
            opacity: item.enabled ? 1 : 0.48,
            child: GestureDetector(
              onLongPress: _sending ? null : () => _manageParticipant(item),
              child: ChoiceChip(
                avatar: _avatarForParticipant(item, radius: 13),
                selected: selected,
                label: Text(
                  item.enabled ? item.name : '${item.name}（已暂停）',
                  overflow: TextOverflow.ellipsis,
                ),
                onSelected: _sending
                    ? null
                    : (_) {
                        if (!item.enabled) {
                          _manageParticipant(item);
                          return;
                        }
                        setState(() => _selectedParticipantId = item.id);
                      },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget get _messageList {
    if (_messages.isEmpty) {
      return Center(
        child: Text(_isTavern ? '添加角色卡后开始酒馆对话' : '添加角色后，选择发言者开始创作'),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: _messages.length,
      itemBuilder: (_, index) {
        final message = _messages[index];
        final isUser = message.isUser;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: GestureDetector(
              onLongPress:
                  _sending ? null : () => _showMessageActions(message, index),
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isUser) ...[
                            _avatarForMessage(message, radius: 12),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              message.speakerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (_streamingMessageCreatedAt
                          .contains(message.createdAt)) ...[
                        if (message.content.trim().isEmpty)
                          Text(
                            '${message.speakerName} 正在发言...',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontStyle: FontStyle.italic,
                            ),
                          )
                        else
                          Text(message.content),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          minHeight: 2,
                          color: Theme.of(context).colorScheme.primary,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                        ),
                      ] else
                        Text(message.content),
                      if (message.imagePaths.isNotEmpty ||
                          message.filePaths.isNotEmpty ||
                          message.attachmentContext.trim().isNotEmpty)
                        _messageAttachments(message),
                      if (!isUser) _readAloudButton(message),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _readAloudButton(StoryMessageModel message) {
    final contentAvailable = message.content.trim().isNotEmpty &&
        !_streamingMessageCreatedAt.contains(message.createdAt);
    final active = _readAloudController.state.isActiveFor(message);
    final state = _readAloudController.state;
    final icon = active && state.isGenerating
        ? null
        : active
            ? Icons.stop_rounded
            : Icons.volume_up_outlined;
    return Align(
      alignment: Alignment.centerLeft,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: active ? '停止朗读' : '朗读',
        onPressed: contentAvailable ? () => _toggleReadAloud(message) : null,
        icon: icon == null
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon),
      ),
    );
  }

  Future<void> _toggleReadAloud(StoryMessageModel message) {
    final voiceStyle = StoryRoomReadAloudVoiceResolver.resolve(
      message,
      _participants,
    );
    return _readAloudController.toggle(
      message: message,
      voiceStyle: voiceStyle,
    );
  }

  Widget get _composer {
    final selected = _selectedParticipant;
    final manual = !_isTavern || widget.room.replyMode == StoryReplyMode.manual;
    final settings = context.watch<AISettingsProvider>().settings;
    final capabilities =
        ChatService.capabilitiesFor(_effectiveSettings(settings));
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                    _isTavern
                        ? Icons.auto_awesome_outlined
                        : Icons.record_voice_over_outlined,
                    size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: manual
                      ? DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: selected?.id,
                            isExpanded: true,
                            items: [
                              for (final item in _participants
                                  .where((item) => item.enabled))
                                DropdownMenuItem(
                                  value: item.id,
                                  child: Text(
                                    '${StoryParticipantRole.labelOf(item.role)} · ${item.name}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _sending
                                ? null
                                : (id) =>
                                    setState(() => _selectedParticipantId = id),
                          ),
                        )
                      : Text(
                          selected == null
                              ? '自动接话：请先添加角色卡'
                              : _forcedNextParticipantId == null
                                  ? '${StoryReplyMode.labelOf(widget.room.replyMode)} · 备用角色：${selected.name}'
                                  : '${StoryReplyMode.labelOf(widget.room.replyMode)} · 下一位：${_forcedNextParticipantName()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_sending && _generationStatus.isNotEmpty) ...[
              Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _generationStatus,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            MessageInputWidget(
              _isTavern ? '输入对话或场景动作' : '输入剧情、台词或创作指令',
              enable: !_sending,
              isStreaming: _sending,
              onChanged: (value) => _inputText = value,
              onSend: () => unawaited(_send()),
              onStop: _stopGeneration,
              pendingImages: _pendingImages,
              imagesEnabled: capabilities.image,
              imagesDisabledReason: '当前模型不支持图片，请切换多模态模型',
              onImagesPicked: (paths) => setState(() => _pendingImages =
                  StoryRoomAttachmentPolicy.normalizePaths(paths,
                      limit: StoryRoomAttachmentPolicy.maxImages)),
              onRemoveImage: (index) => setState(() {
                _pendingImages = List<String>.from(_pendingImages)
                  ..removeAt(index);
              }),
              pendingFiles: _pendingFiles,
              onFilesPicked: (paths) => setState(() => _pendingFiles =
                  StoryRoomAttachmentPolicy.normalizePaths(paths,
                      limit: StoryRoomAttachmentPolicy.maxFiles)),
              onRemoveFile: (index) => setState(() {
                _pendingFiles = List<String>.from(_pendingFiles)
                  ..removeAt(index);
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatarForParticipant(StoryParticipantModel item,
      {double radius = 18}) {
    return AssistantAvatar.raw(
      emoji: item.avatarType == 'emoji' ? item.avatarValue ?? '🎭' : '🎭',
      avatarType: item.avatarType,
      avatarValue: item.avatarValue,
      radius: radius,
    );
  }

  Widget _avatarForMessage(StoryMessageModel message, {double radius = 18}) {
    return AssistantAvatar.raw(
      emoji: message.speakerAvatarType == 'emoji'
          ? message.speakerAvatarValue ?? '🎭'
          : '🎭',
      avatarType: message.speakerAvatarType,
      avatarValue: message.speakerAvatarValue,
      radius: radius,
    );
  }

  Widget _messageAttachments(StoryMessageModel message) {
    final hasFiles = message.filePaths.isNotEmpty;
    final hasExtractedText = message.attachmentContext.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final path in message.imagePaths)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(path),
                width: 54,
                height: 54,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 54,
                  height: 54,
                  color: Colors.black12,
                  alignment: Alignment.center,
                  child:
                      const Icon(Icons.image_not_supported_outlined, size: 20),
                ),
              ),
            ),
          if (hasFiles)
            for (final path in message.filePaths)
              _attachmentLabel(
                Icons.insert_drive_file_outlined,
                _attachmentName(path),
              ),
          if (hasExtractedText)
            _attachmentLabel(Icons.article_outlined, '已提取文件内容'),
        ],
      ),
    );
  }

  Widget _attachmentLabel(IconData icon, String label) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 210),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  String _attachmentName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }

  Future<void> _addAssistantParticipant() async {
    final result = await showAssistantPicker(context);
    final assistant = result?.assistant;
    if (assistant == null || !mounted) return;
    final dao = _dao;
    if (dao == null) return;
    if (assistant.id != null &&
        _participants.any((item) => item.assistantId == assistant.id)) {
      HiDialog.showSnackBar(context, '这个角色已经在房间中');
      return;
    }
    final participant = _participantFromAssistant(assistant);
    await dao.saveParticipant(participant);
    await _load();
  }

  Future<void> _showMessageActions(
    StoryMessageModel message,
    int index,
  ) async {
    final canRegenerate = !message.isUser && message.speakerId != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制内容'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑内容'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.refresh_outlined),
                title: const Text('重新生成'),
                subtitle: const Text('使用这条回复之前的对话重新生成'),
                onTap: () => Navigator.pop(ctx, 'regenerate'),
              ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.playlist_add_outlined),
                title: const Text('继续生成'),
                subtitle: const Text('从当前内容之后继续，不重复已有文字'),
                onTap: () => Navigator.pop(ctx, 'continue'),
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: Text(
                '删除消息',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.content));
        if (mounted) HiDialog.showSnackBar(context, '已复制');
        return;
      case 'edit':
        await _editMessage(message);
        return;
      case 'regenerate':
        await _regenerateMessage(message, index);
        return;
      case 'continue':
        await _continueMessage(message);
        return;
      case 'delete':
        await _deleteMessage(message);
        return;
    }
  }

  Future<void> _editMessage(StoryMessageModel message) async {
    final controller = TextEditingController(text: message.content);
    final content = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑${message.speakerName}的消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 5,
          maxLines: 14,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(ctx, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (content == null || content == message.content) return;
    message.content = content;
    await _dao?.updateMessage(message);
    if (mounted) setState(() {});
  }

  Future<void> _deleteMessage(StoryMessageModel message) async {
    final id = message.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('删除后不会自动改写后续剧情，确定继续吗？'),
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
    await _dao?.deleteMessage(id);
    if (mounted) {
      setState(
          () => _messages = _messages.where((item) => item.id != id).toList());
    }
  }

  Future<void> _regenerateMessage(
    StoryMessageModel message,
    int index,
  ) async {
    final speaker = _participantById(message.speakerId);
    if (speaker == null) {
      HiDialog.showSnackBar(context, '原角色已移出或暂停，无法重新生成');
      return;
    }
    var userIndex = index - 1;
    while (userIndex >= 0 && !_messages[userIndex].isUser) {
      userIndex--;
    }
    if (userIndex < 0) {
      HiDialog.showSnackBar(context, '找不到触发这条回复的用户消息');
      return;
    }
    final userMessage = _messages[userIndex];
    final input = userMessage.content;
    final history = _messages.sublist(0, userIndex);
    final settings =
        _effectiveSettings(context.read<AISettingsProvider>().settings);
    final attachmentBundle = await StoryRoomAttachmentService.prepare(
      imagePaths: userMessage.imagePaths,
      filePaths: userMessage.filePaths,
      capabilities: ChatService.capabilitiesFor(settings),
      fallbackContext: userMessage.attachmentContext,
    );
    if (message.id != null) await _dao?.deleteMessage(message.id!);
    if (mounted) {
      setState(() =>
          _messages = _messages.where((item) => item != message).toList());
    }
    await _runSingleSpeakerGeneration(
      input: input,
      speaker: speaker,
      historyMessages: history,
      attachmentBundle: attachmentBundle,
    );
  }

  Future<void> _continueMessage(StoryMessageModel message) async {
    final speaker = _participantById(message.speakerId);
    if (speaker == null) {
      HiDialog.showSnackBar(context, '原角色已移出或暂停，无法继续生成');
      return;
    }
    await _runSingleSpeakerGeneration(
      input: '请从上一段中断处继续，保持相同语气和场景，不要重复已经生成的内容。',
      speaker: speaker,
      historyMessages: List<StoryMessageModel>.from(_messages),
    );
  }

  StoryParticipantModel? _participantById(int? id) {
    for (final item in _participants) {
      if (item.id == id && item.enabled) return item;
    }
    return null;
  }

  Future<void> _runSingleSpeakerGeneration({
    required String input,
    required StoryParticipantModel speaker,
    required List<StoryMessageModel> historyMessages,
    StoryRoomAttachmentBundle? attachmentBundle,
  }) async {
    final dao = _dao;
    if (dao == null || _sending) return;
    final settings =
        _effectiveSettings(context.read<AISettingsProvider>().settings);
    setState(() {
      _sending = true;
      _stopRequested = false;
      _generationStatus = '${speaker.name} 正在发言...';
    });
    try {
      await _streamSpeakerReply(
        dao: dao,
        settings: settings,
        input: input,
        speaker: speaker,
        historyMessages: historyMessages,
        attachmentBundle: attachmentBundle,
      );
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '生成失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _generationStatus = '';
          _stopRequested = false;
        });
      }
    }
  }

  Future<void> _manageParticipant(StoryParticipantModel participant) async {
    final index = _participants.indexWhere((item) => item.id == participant.id);
    if (index < 0) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: _avatarForParticipant(participant),
              title: Text(participant.name),
              subtitle: Text(StoryParticipantRole.labelOf(participant.role)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑房间内角色'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            if (participant.assistantId != null)
              ListTile(
                leading: const Icon(Icons.sync_outlined),
                title: const Text('同步助手最新资料'),
                subtitle: const Text('更新名称、人设和头像，不改历史消息'),
                onTap: () => Navigator.pop(ctx, 'sync'),
              ),
            if (_isTavern &&
                participant.enabled &&
                participant.role == StoryParticipantRole.assistant &&
                widget.room.replyMode != StoryReplyMode.manual)
              ListTile(
                leading: const Icon(Icons.next_plan_outlined),
                title: const Text('指定为下一位发言者'),
                subtitle: const Text('下一次发送优先由该角色开口'),
                onTap: () => Navigator.pop(ctx, 'force_next'),
              ),
            ListTile(
              leading: Icon(
                participant.enabled
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              title: Text(participant.enabled ? '暂停参与发言' : '重新加入发言'),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
            if (index > 0)
              ListTile(
                leading: const Icon(Icons.arrow_back_outlined),
                title: const Text('向前移动'),
                onTap: () => Navigator.pop(ctx, 'previous'),
              ),
            if (index < _participants.length - 1)
              ListTile(
                leading: const Icon(Icons.arrow_forward_outlined),
                title: const Text('向后移动'),
                onTap: () => Navigator.pop(ctx, 'next'),
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: Text(
                '移出房间',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        await _editParticipant(participant);
        return;
      case 'sync':
        await _syncParticipantFromAssistant(participant);
        return;
      case 'force_next':
        setState(() {
          _forcedNextParticipantId = participant.id;
          _selectedParticipantId = participant.id;
        });
        HiDialog.showSnackBar(context, '下一位将由「${participant.name}」发言');
        return;
      case 'toggle':
        participant.enabled = !participant.enabled;
        await _dao?.saveParticipant(participant);
        await _load();
        return;
      case 'previous':
        await _swapParticipants(index, index - 1);
        return;
      case 'next':
        await _swapParticipants(index, index + 1);
        return;
      case 'delete':
        await _deleteParticipant(participant);
        return;
    }
  }

  Future<void> _editParticipant(StoryParticipantModel participant) async {
    final global = context.read<AISettingsProvider>().settings;
    final nameController = TextEditingController(text: participant.name);
    final promptController = TextEditingController(text: participant.prompt);
    final modelController =
        TextEditingController(text: participant.modelId ?? '');
    final temperatureController = TextEditingController(
      text: participant.temperature?.toString() ?? '',
    );
    final maxTokensController = TextEditingController(
      text: participant.maxOutputTokens?.toString() ?? '',
    );
    final userVoiceModels = await UserSherpaOnnxTtsModelStore().listModels();
    if (!mounted) {
      nameController.dispose();
      promptController.dispose();
      modelController.dispose();
      temperatureController.dispose();
      maxTokensController.dispose();
      return;
    }
    var voiceStyle = participant.voiceStyle ?? TtsVoiceStyle.system.id;
    var providerId = participant.modelProviderId?.trim() ?? '';
    final hasVoiceStyle = TtsVoiceStyle.isValid(voiceStyle) ||
        userVoiceModels.any((model) => model.voiceStyleId == voiceStyle);
    if (!hasVoiceStyle) voiceStyle = TtsVoiceStyle.system.id;
    final saved = await showDialog<
        (String, String, String, String?, String?, double?, int?)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑房间内角色'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '显示名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: promptController,
                  minLines: 5,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: '房间内人设 / 职责',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (global.mode == AIMode.local) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: global.enabledProviders
                            .any((provider) => provider.id == providerId)
                        ? providerId
                        : '',
                    decoration: const InputDecoration(
                      labelText: '角色服务商覆盖',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('跟随房间设置'),
                      ),
                      for (final provider in global.enabledProviders)
                        DropdownMenuItem(
                          value: provider.id,
                          child: Text(provider.name),
                        ),
                    ],
                    onChanged: (value) {
                      setDialogState(() {
                        providerId = value ?? '';
                      });
                    },
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: modelController,
                  decoration: const InputDecoration(
                    labelText: '角色模型覆盖',
                    hintText: '留空跟随房间设置',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: temperatureController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: '角色 Temperature 覆盖',
                    hintText: '留空跟随房间设置，范围 0-2',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: maxTokensController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '角色最大输出 Token 覆盖',
                    hintText: '留空跟随房间设置，0 表示不限制',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: voiceStyle,
                  decoration: const InputDecoration(
                    labelText: '朗读音色风格',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final style in TtsVoiceStyle.all)
                      DropdownMenuItem(
                        value: style.id,
                        child: Text(style.label),
                      ),
                    for (final model in userVoiceModels)
                      DropdownMenuItem(
                        value: model.voiceStyleId,
                        child: Text('用户模型：${model.title}'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => voiceStyle = value);
                  },
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _voiceStyleDescription(voiceStyle, userVoiceModels),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final temperatureText = temperatureController.text.trim();
                final maxTokensText = maxTokensController.text.trim();
                final temperature = temperatureText.isEmpty
                    ? null
                    : double.tryParse(temperatureText);
                final maxTokens =
                    maxTokensText.isEmpty ? null : int.tryParse(maxTokensText);
                if (temperatureText.isNotEmpty &&
                    (temperature == null ||
                        temperature < 0 ||
                        temperature > 2)) {
                  return;
                }
                if (maxTokensText.isNotEmpty &&
                    (maxTokens == null || maxTokens < 0)) {
                  return;
                }
                Navigator.pop(ctx, (
                  name,
                  promptController.text.trim(),
                  voiceStyle,
                  providerId.isEmpty ? null : providerId,
                  modelController.text.trim().isEmpty
                      ? null
                      : modelController.text.trim(),
                  temperature,
                  maxTokens,
                ));
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    promptController.dispose();
    modelController.dispose();
    temperatureController.dispose();
    maxTokensController.dispose();
    if (saved == null) return;
    participant.name = saved.$1;
    participant.prompt = saved.$2;
    participant.voiceStyle = saved.$3;
    participant
      ..modelProviderId = saved.$4
      ..modelId = saved.$5
      ..temperature = saved.$6
      ..maxOutputTokens = saved.$7;
    await _dao?.saveParticipant(participant);
    await _load();
  }

  String _voiceStyleDescription(
    String voiceStyle,
    List<UserSherpaOnnxTtsModel> userModels,
  ) {
    for (final model in userModels) {
      if (model.voiceStyleId == voiceStyle) {
        return '用户导入的 sherpa-onnx 模型：${model.title}';
      }
    }
    return TtsVoiceStyle.byId(voiceStyle).description;
  }

  Future<void> _syncParticipantFromAssistant(
    StoryParticipantModel participant,
  ) async {
    final assistantId = participant.assistantId;
    if (assistantId == null) return;
    final db = await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final assistant =
        await (await AssistantDao.create(db)).getAssistant(assistantId);
    if (!mounted) return;
    if (assistant == null) {
      HiDialog.showSnackBar(context, '原助手已不存在，房间快照保持不变');
      return;
    }
    final avatar = _avatarFromAssistant(assistant);
    participant
      ..name = assistant.name
      ..prompt = assistant.systemPromptFor('')
      ..avatarType = avatar.$1
      ..avatarValue = avatar.$2
      ..modelProviderId = assistant.providerId.trim().isEmpty
          ? null
          : assistant.providerId.trim()
      ..modelId =
          assistant.model.trim().isEmpty ? null : assistant.model.trim();
    await _dao?.saveParticipant(participant);
    await _load();
    if (mounted) HiDialog.showSnackBar(context, '已同步助手最新资料');
  }

  Future<void> _swapParticipants(int firstIndex, int secondIndex) async {
    if (firstIndex < 0 ||
        secondIndex < 0 ||
        firstIndex >= _participants.length ||
        secondIndex >= _participants.length) {
      return;
    }
    final first = _participants[firstIndex];
    final second = _participants[secondIndex];
    final firstOrder = first.sortOrder;
    first.sortOrder = second.sortOrder;
    second.sortOrder = firstOrder;
    if (first.sortOrder == second.sortOrder) {
      first.sortOrder = secondIndex;
      second.sortOrder = firstIndex;
    }
    await _dao?.saveParticipant(first);
    await _dao?.saveParticipant(second);
    await _load();
  }

  Future<void> _deleteParticipant(StoryParticipantModel participant) async {
    final id = participant.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出房间'),
        content: Text('确定将「${participant.name}」移出房间吗？历史消息会保留原头像和名称。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao?.deleteParticipant(id);
    await _load();
  }

  StoryParticipantModel _participantFromAssistant(AssistantModel assistant) {
    final avatar = _avatarFromAssistant(assistant);
    return StoryParticipantModel(
      roomId: widget.room.id!,
      assistantId: assistant.id,
      role: StoryParticipantRole.assistant,
      name: assistant.name,
      prompt: assistant.systemPromptFor(''),
      avatarType: avatar.$1,
      avatarValue: avatar.$2,
      voiceStyle: assistant.defaultVoiceStyle.trim().isEmpty
          ? null
          : assistant.defaultVoiceStyle.trim(),
      modelProviderId: assistant.providerId.trim().isEmpty
          ? null
          : assistant.providerId.trim(),
      modelId: assistant.model.trim().isEmpty ? null : assistant.model.trim(),
      sortOrder: _participants.length + 1,
    );
  }

  (String?, String?) _avatarFromAssistant(AssistantModel assistant) {
    if (assistant.avatarType == AvatarAssetService.imageType &&
        (assistant.avatarValue?.trim().isNotEmpty ?? false)) {
      return (AvatarAssetService.imageType, assistant.avatarValue!.trim());
    }
    final emoji = assistant.emoji.trim();
    return emoji.isEmpty ? (null, null) : ('emoji', emoji);
  }

  Future<void> _editPublicContext() async {
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('公共上下文'),
        content: TextField(
          controller: _publicContextCtl,
          minLines: 6,
          maxLines: 12,
          decoration: const InputDecoration(
            hintText: '世界观、当前章节、场景、时间线、写作风格等',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _publicContextCtl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    widget.room.publicContext = saved;
    await _dao?.saveRoom(widget.room);
    if (!mounted) return;
    setState(() {});
  }

  AISettings _effectiveSettings(AISettings settings) {
    return StoryRoomSettingsResolver.apply(widget.room, settings);
  }

  Future<void> _editRoomModelSettings() async {
    final global = context.read<AISettingsProvider>().settings;
    var providerId = widget.room.modelProviderId?.trim() ?? '';
    final modelController =
        TextEditingController(text: widget.room.modelId ?? '');
    final temperatureController = TextEditingController(
      text: widget.room.temperature?.toString() ?? '',
    );
    final maxTokensController = TextEditingController(
      text: widget.room.maxOutputTokens?.toString() ?? '',
    );
    final saved = await showDialog<(String?, String?, double?, int?)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('模型与生成参数'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (global.mode == AIMode.local)
                  DropdownButtonFormField<String>(
                    initialValue: providerId,
                    decoration: const InputDecoration(
                      labelText: '服务商',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('跟随全局'),
                      ),
                      for (final provider in global.enabledProviders)
                        DropdownMenuItem(
                          value: provider.id,
                          child: Text(provider.name),
                        ),
                    ],
                    onChanged: (value) {
                      setDialogState(() => providerId = value ?? '');
                      if (providerId.isEmpty) return;
                      final providers = global.enabledProviders
                          .where((provider) => provider.id == providerId);
                      if (providers.isNotEmpty &&
                          modelController.text.trim().isEmpty) {
                        modelController.text = providers.first.effectiveModelId;
                      }
                    },
                  ),
                if (global.mode == AIMode.local) const SizedBox(height: 12),
                TextField(
                  controller: modelController,
                  decoration: InputDecoration(
                    labelText: '模型 ID',
                    hintText: '留空跟随全局：${global.effectiveModel}',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: temperatureController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Temperature',
                    hintText: '留空跟随全局，范围 0-2',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: maxTokensController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大输出 Token',
                    hintText: '留空跟随全局，0 表示不限制',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final temperatureText = temperatureController.text.trim();
                final maxTokensText = maxTokensController.text.trim();
                final temperature = temperatureText.isEmpty
                    ? null
                    : double.tryParse(temperatureText);
                final maxTokens =
                    maxTokensText.isEmpty ? null : int.tryParse(maxTokensText);
                if (temperatureText.isNotEmpty &&
                    (temperature == null ||
                        temperature < 0 ||
                        temperature > 2)) {
                  return;
                }
                if (maxTokensText.isNotEmpty &&
                    (maxTokens == null || maxTokens < 0)) {
                  return;
                }
                Navigator.pop(
                  ctx,
                  (
                    providerId.isEmpty ? null : providerId,
                    modelController.text.trim().isEmpty
                        ? null
                        : modelController.text.trim(),
                    temperature,
                    maxTokens,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    modelController.dispose();
    temperatureController.dispose();
    maxTokensController.dispose();
    if (saved == null) return;
    widget.room
      ..modelProviderId = saved.$1
      ..modelId = saved.$2
      ..temperature = saved.$3
      ..maxOutputTokens = saved.$4;
    await _dao?.saveRoom(widget.room);
    if (mounted) {
      setState(() {});
      HiDialog.showSnackBar(context, '房间模型设置已保存');
    }
  }

  Future<void> _editTavernReplyMode() async {
    var mode = StoryReplyMode.normalize(widget.room.replyMode);
    var maxReplies = widget.room.maxAutoReplies.clamp(1, 3).toInt();
    final saved = await showModalBottomSheet<(String, int)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '酒馆发言模式',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _replyModeTile(
                  value: StoryReplyMode.manual,
                  groupValue: mode,
                  title: '手动发言',
                  subtitle: '你选择一个角色，由该角色回复',
                  onTap: () =>
                      setSheetState(() => mode = StoryReplyMode.manual),
                ),
                _replyModeTile(
                  value: StoryReplyMode.autoSingle,
                  groupValue: mode,
                  title: '自动接话',
                  subtitle: '系统自动选择 1 个最适合回应的角色',
                  onTap: () =>
                      setSheetState(() => mode = StoryReplyMode.autoSingle),
                ),
                _replyModeTile(
                  value: StoryReplyMode.autoMulti,
                  groupValue: mode,
                  title: '群聊轮换',
                  subtitle: '系统自动选择多个角色连续发言',
                  onTap: () => setSheetState(() {
                    mode = StoryReplyMode.autoMulti;
                    maxReplies = maxReplies.clamp(2, 3).toInt();
                  }),
                ),
                if (mode == StoryReplyMode.autoMulti) ...[
                  const SizedBox(height: 8),
                  Text('最多连续发言：${maxReplies.clamp(2, 3).toInt()}'),
                  Slider(
                    value: maxReplies.clamp(2, 3).toDouble(),
                    min: 2,
                    max: 3,
                    divisions: 1,
                    label: '$maxReplies',
                    onChanged: (v) =>
                        setSheetState(() => maxReplies = v.round()),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, (mode, maxReplies)),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == null) return;
    widget.room.replyMode = saved.$1;
    widget.room.maxAutoReplies =
        saved.$1 == StoryReplyMode.autoMulti ? saved.$2.clamp(2, 3) : 1;
    await _dao?.saveRoom(widget.room);
    if (!mounted) return;
    setState(() {});
  }

  Widget _replyModeTile({
    required String value,
    required String groupValue,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final selected = value == groupValue;
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }

  Future<void> _send() async {
    final dao = _dao;
    final manualSpeaker = _selectedParticipant;
    final input = _inputText.trim();
    if (dao == null || input.isEmpty) return;
    final manual = !_isTavern || widget.room.replyMode == StoryReplyMode.manual;
    if (manual && manualSpeaker == null) return;
    if (_isTavern &&
        !manual &&
        StorySpeakerScheduler.tavernCandidates(_participants).isEmpty) {
      HiDialog.showSnackBar(context, '请先添加至少一个角色卡');
      return;
    }
    final settings =
        _effectiveSettings(context.read<AISettingsProvider>().settings);
    final capabilities = ChatService.capabilitiesFor(settings);
    if (_pendingImages.isNotEmpty && !capabilities.image) {
      HiDialog.showSnackBar(context, '当前模型不支持图片，请切换多模态模型');
      return;
    }
    final pendingImages = List<String>.from(_pendingImages);
    final pendingFiles = List<String>.from(_pendingFiles);
    if (mounted) {
      setState(() {
        // 先锁住发送，避免附件编码期间重复触发下一轮请求。
        _sending = true;
        _stopRequested = false;
        _generationStatus = '准备附件...';
        _inputText = '';
        _pendingImages = [];
        _pendingFiles = [];
      });
    }
    final attachmentBundle = await StoryRoomAttachmentService.prepare(
      imagePaths: pendingImages,
      filePaths: pendingFiles,
      capabilities: capabilities,
    );
    final previousMessages = List<StoryMessageModel>.from(_messages);
    final userMessage = StoryMessageModel(
      roomId: widget.room.id!,
      speakerRole: 'user',
      speakerName: '我',
      content: input,
      imagePaths: attachmentBundle.imagePaths,
      filePaths: attachmentBundle.filePaths,
      attachmentContext: attachmentBundle.attachmentContext,
    );
    if (mounted) {
      setState(() {
        _generationStatus = '准备生成回复...';
        _messages = [..._messages, userMessage];
      });
    }
    await dao.saveMessage(userMessage);

    try {
      final chatService = ChatService.from(settings);
      final speakers = manual
          ? [if (manualSpeaker != null) manualSpeaker]
          : await _scheduleTavernSpeakers(
              chatService: chatService,
              settings: settings,
              input: input,
              previousMessages: previousMessages,
            );
      if (speakers.isEmpty) throw Exception('没有可用角色');
      var workingHistory = List<StoryMessageModel>.from(previousMessages);
      final replies = <StoryMessageModel>[];
      for (final speaker in speakers) {
        if (_stopRequested) break;
        final reply = await _streamSpeakerReply(
          dao: dao,
          settings: settings,
          input: input,
          speaker: speaker,
          historyMessages: workingHistory,
          attachmentBundle: attachmentBundle,
        );
        if (reply == null) break;
        replies.add(reply);
        workingHistory = [...workingHistory, userMessage, ...replies];
      }
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '生成失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _generationStatus = '';
          _stopRequested = false;
        });
      }
    }
  }

  void _stopGeneration() {
    _stopRequested = true;
    final sub = _activeReplySub;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    final done = _activeReplyDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
    if (mounted) {
      setState(() => _generationStatus = '正在停止...');
    }
  }

  Future<List<StoryParticipantModel>> _scheduleTavernSpeakers({
    required ChatService chatService,
    required AISettings settings,
    required String input,
    required List<StoryMessageModel> previousMessages,
  }) async {
    final candidates = StorySpeakerScheduler.tavernCandidates(_participants);
    StoryParticipantModel? forced;
    final forcedId = _forcedNextParticipantId;
    if (forcedId != null) {
      for (final candidate in candidates) {
        if (candidate.id == forcedId) {
          forced = candidate;
          break;
        }
      }
      _forcedNextParticipantId = null;
      if (mounted) setState(() {});
      if (forced != null && widget.room.replyMode != StoryReplyMode.autoMulti) {
        return [forced];
      }
      if (forced != null) {
        candidates.removeWhere((candidate) => candidate.id == forced!.id);
      }
    }
    final fallback = StorySpeakerScheduler.fallbackSpeaker(
      candidates: candidates,
      selectedParticipantId: _selectedParticipantId,
    );
    if (candidates.length <= 1) {
      return [if (forced != null) forced, if (fallback != null) fallback];
    }
    final maxSpeakers = widget.room.replyMode == StoryReplyMode.autoMulti
        ? (widget.room.maxAutoReplies - (forced == null ? 0 : 1)).clamp(1, 3)
        : 1;
    try {
      final allowedIds = {for (final item in candidates) item.id!};
      final prompt = StorySpeakerScheduler.promptFor(
        input,
        maxSpeakers: maxSpeakers,
      );
      final history = [
        {
          'role': 'system',
          'content': StorySpeakerScheduler.systemPrompt(
            room: widget.room,
            candidates: candidates,
            recentMessages: previousMessages,
            maxSpeakers: maxSpeakers,
          ),
        },
      ];
      final result = await chatService.chatWithUsage(
        prompt: prompt,
        history: history,
      );
      final response = result.content;
      if (response != null && response.trim().isNotEmpty) {
        await _recordUsage(
          settings: settings,
          prompt: _usagePromptText(history, prompt),
          completion: response,
          promptTokens: result.promptTokens,
          cachedPromptTokens: result.cachedPromptTokens,
          completionTokens: result.completionTokens,
          estimated: result.estimated,
          cost: result.cost,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
      final ids = StorySpeakerScheduler.parseSpeakerIds(
        response,
        allowedIds,
        maxCount: maxSpeakers,
      );
      if (ids.isEmpty) {
        return [if (forced != null) forced, if (fallback != null) fallback];
      }
      final speakers = <StoryParticipantModel>[];
      for (final id in ids) {
        for (final item in candidates) {
          if (item.id == id) speakers.add(item);
        }
      }
      if (speakers.isEmpty) {
        return [if (forced != null) forced, if (fallback != null) fallback];
      }
      return [if (forced != null) forced, ...speakers];
    } catch (_) {
      return [if (forced != null) forced, if (fallback != null) fallback];
    }
  }

  String _forcedNextParticipantName() {
    final id = _forcedNextParticipantId;
    for (final participant in _participants) {
      if (participant.id == id) return participant.name;
    }
    return '已指定角色';
  }

  Future<StoryMessageModel?> _streamSpeakerReply({
    required StoryRoomDao dao,
    required AISettings settings,
    required String input,
    required StoryParticipantModel speaker,
    required List<StoryMessageModel> historyMessages,
    StoryRoomAttachmentBundle? attachmentBundle,
  }) async {
    final speakerSettings =
        StoryParticipantSettingsResolver.apply(settings, speaker);
    final speakerChatService = ChatService.from(speakerSettings);
    final system = StoryContextBuilder.systemPrompt(
      room: widget.room,
      participants: _participants,
      speaker: speaker,
      latestInput: input,
      recentMessages: historyMessages,
    );
    final history = [
      {'role': 'system', 'content': system},
      ...StoryContextBuilder.history(
        historyMessages,
        room: widget.room,
        speaker: speaker,
      ),
    ];
    final message = StoryMessageModel(
      roomId: widget.room.id!,
      speakerId: speaker.id,
      speakerRole: speaker.role,
      speakerName: speaker.name,
      speakerAvatarType: speaker.avatarType,
      speakerAvatarValue: speaker.avatarValue,
      speakerVoiceStyle: speaker.voiceStyle,
      content: '',
    );
    if (mounted) {
      setState(() {
        _generationStatus = '${speaker.name} 正在发言...';
        _streamingMessageCreatedAt.add(message.createdAt);
        _messages = [..._messages, message];
      });
    }

    final buffer = StringBuffer();
    var promptTokens = 0;
    var cachedPromptTokens = 0;
    var completionTokens = 0;
    var hasUsage = false;
    Object? streamError;
    final done = Completer<void>();
    final stream = speakerChatService.chatStreamEvents(
      prompt: StoryContextBuilder.promptFor(input: input, speaker: speaker),
      history: history,
      attachments: attachmentBundle?.attachments,
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
          message.content = buffer.toString();
          if (mounted) setState(() {});
        }
      },
      onError: (Object e) {
        streamError = e;
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    _activeReplySub = sub;
    _activeReplyDone = done;
    await done.future;
    if (identical(_activeReplySub, sub)) _activeReplySub = null;
    if (identical(_activeReplyDone, done)) _activeReplyDone = null;

    if (mounted) {
      setState(() => _streamingMessageCreatedAt.remove(message.createdAt));
    }
    if (streamError != null) throw streamError!;
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      if (mounted) {
        setState(() {
          _messages = _messages
              .where((item) => item.createdAt != message.createdAt)
              .toList();
        });
      }
      if (_stopRequested) return null;
      throw Exception('${speaker.name} 没有返回内容');
    }
    message.content = text;
    await dao.saveMessage(message);
    await _recordUsage(
      settings: speakerSettings,
      prompt: _usagePromptText(
        history,
        StoryContextBuilder.promptFor(input: input, speaker: speaker),
      ),
      completion: text,
      promptTokens: hasUsage ? promptTokens : null,
      cachedPromptTokens: hasUsage ? cachedPromptTokens : null,
      completionTokens: hasUsage ? completionTokens : null,
      estimated: !hasUsage,
      createdAt: message.createdAt,
    );
    return message;
  }

  String _usagePromptText(
    List<Map<String, dynamic>> history,
    String prompt,
  ) {
    return [
      for (final item in history) '${item['role']}：${item['content']}',
      'user：$prompt',
    ].join('\n');
  }

  Future<void> _recordUsage({
    required AISettings settings,
    required String prompt,
    required String completion,
    int? promptTokens,
    int? cachedPromptTokens,
    int? completionTokens,
    bool estimated = false,
    double cost = 0,
    required int createdAt,
  }) async {
    final service = _usageRecordService;
    final modelId = settings.effectiveModel.trim();
    if (service == null || modelId.isEmpty) return;
    try {
      await service.recordTurn(
        modelId: modelId,
        providerId:
            settings.mode == AIMode.local ? settings.activeProviderId : null,
        projectId: null,
        cid: null,
        prompt: prompt,
        completion: completion,
        promptTokens: promptTokens,
        cachedPromptTokens: cachedPromptTokens,
        completionTokens: completionTokens,
        estimated: estimated,
        cost: cost,
        costConfig: settings.usageCostConfig,
        createdAt: createdAt,
      );
    } catch (_) {
      // 用量记录失败不能阻断房间回复。
    }
  }
}
