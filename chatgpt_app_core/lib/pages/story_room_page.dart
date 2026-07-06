import 'dart:async';

import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_speaker_scheduler.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class StoryRoomPage extends StatefulWidget {
  final StoryRoomModel room;

  const StoryRoomPage({super.key, required this.room});

  @override
  State<StoryRoomPage> createState() => _StoryRoomPageState();
}

class _StoryRoomPageState extends State<StoryRoomPage> {
  final _inputCtl = TextEditingController();
  final _publicContextCtl = TextEditingController();
  StoryRoomDao? _dao;
  List<StoryParticipantModel> _participants = const [];
  List<StoryMessageModel> _messages = const [];
  int? _selectedParticipantId;
  bool _loading = true;
  bool _sending = false;
  bool _stopRequested = false;
  StreamSubscription<StreamEvent>? _activeReplySub;
  Completer<void>? _activeReplyDone;
  String _generationStatus = '';
  final Set<int> _streamingMessageCreatedAt = {};

  bool get _isTavern => widget.room.mode == StoryRoomMode.tavern;

  StoryParticipantModel? get _selectedParticipant {
    for (final item in _participants) {
      if (item.id == _selectedParticipantId) return item;
    }
    return _participants.isEmpty ? null : _participants.first;
  }

  @override
  void initState() {
    super.initState();
    _publicContextCtl.text = widget.room.publicContext;
    _load();
  }

  @override
  void dispose() {
    unawaited(_activeReplySub?.cancel());
    _inputCtl.dispose();
    _publicContextCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryRoomDao.create(db);
    var participants = await dao.getParticipants(widget.room.id!);
    if (participants.isEmpty && !_isTavern) {
      await _seedDefaultParticipants(dao);
      participants = await dao.getParticipants(widget.room.id!);
    }
    final messages = await dao.getMessages(widget.room.id!);
    if (!mounted) return;
    setState(() {
      _dao = dao;
      _participants = participants;
      _messages = messages;
      _selectedParticipantId ??=
          participants.isEmpty ? null : participants.first.id;
      _loading = false;
    });
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
          IconButton(
            tooltip: '公共上下文',
            onPressed: _editPublicContext,
            icon: const Icon(Icons.notes_outlined),
          ),
          IconButton(
            tooltip: '添加角色',
            onPressed: _addAssistantParticipant,
            icon: const Icon(Icons.person_add_alt_1_outlined),
          ),
          if (_isTavern)
            IconButton(
              tooltip: '发言模式',
              onPressed: _editTavernReplyMode,
              icon: const Icon(Icons.forum_outlined),
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
          return ChoiceChip(
            avatar: _avatarForParticipant(item, radius: 13),
            selected: selected,
            label: Text(item.name, overflow: TextOverflow.ellipsis),
            onSelected: (_) => setState(() => _selectedParticipantId = item.id),
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
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget get _composer {
    final selected = _selectedParticipant;
    final manual = !_isTavern || widget.room.replyMode == StoryReplyMode.manual;
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
                              for (final item in _participants)
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
                              : '${StoryReplyMode.labelOf(widget.room.replyMode)} · 备用角色：${selected.name}',
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtl,
                    minLines: 1,
                    maxLines: 5,
                    enabled: !_sending,
                    decoration: InputDecoration(
                      hintText: _isTavern ? '输入对话或场景动作' : '输入剧情、台词或创作指令',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: _sending ? '停止生成' : '发送',
                  onPressed: _sending ? _stopGeneration : _send,
                  icon:
                      Icon(_sending ? Icons.stop_rounded : Icons.send_rounded),
                ),
              ],
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

  Future<void> _addAssistantParticipant() async {
    final result = await showAssistantPicker(context);
    final assistant = result?.assistant;
    if (assistant == null || !mounted) return;
    final dao = _dao;
    if (dao == null) return;
    final participant = _participantFromAssistant(assistant);
    await dao.saveParticipant(participant);
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
    final input = _inputCtl.text.trim();
    if (dao == null || input.isEmpty) return;
    final manual = !_isTavern || widget.room.replyMode == StoryReplyMode.manual;
    if (manual && manualSpeaker == null) return;
    if (_isTavern &&
        !manual &&
        StorySpeakerScheduler.tavernCandidates(_participants).isEmpty) {
      HiDialog.showSnackBar(context, '请先添加至少一个角色卡');
      return;
    }
    final settings = context.read<AISettingsProvider>().settings;
    final previousMessages = List<StoryMessageModel>.from(_messages);
    final userMessage = StoryMessageModel(
      roomId: widget.room.id!,
      speakerRole: 'user',
      speakerName: '我',
      content: input,
    );
    setState(() {
      _sending = true;
      _stopRequested = false;
      _generationStatus = '准备生成回复...';
      _messages = [..._messages, userMessage];
      _inputCtl.clear();
    });
    await dao.saveMessage(userMessage);

    try {
      final chatService = ChatService.from(settings);
      final speakers = manual
          ? [if (manualSpeaker != null) manualSpeaker]
          : await _scheduleTavernSpeakers(
              chatService: chatService,
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
          chatService: chatService,
          input: input,
          speaker: speaker,
          historyMessages: workingHistory,
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
    required String input,
    required List<StoryMessageModel> previousMessages,
  }) async {
    final candidates = StorySpeakerScheduler.tavernCandidates(_participants);
    final fallback = StorySpeakerScheduler.fallbackSpeaker(
      candidates: candidates,
      selectedParticipantId: _selectedParticipantId,
    );
    if (candidates.length <= 1) return [if (fallback != null) fallback];
    final maxSpeakers = widget.room.replyMode == StoryReplyMode.autoMulti
        ? widget.room.maxAutoReplies.clamp(2, 3)
        : 1;
    try {
      final allowedIds = {for (final item in candidates) item.id!};
      final response = await chatService.chat(
        prompt: StorySpeakerScheduler.promptFor(
          input,
          maxSpeakers: maxSpeakers,
        ),
        history: [
          {
            'role': 'system',
            'content': StorySpeakerScheduler.systemPrompt(
              room: widget.room,
              candidates: candidates,
              recentMessages: previousMessages,
              maxSpeakers: maxSpeakers,
            ),
          },
        ],
        timeout: const Duration(seconds: 20),
      );
      final ids = StorySpeakerScheduler.parseSpeakerIds(
        response,
        allowedIds,
        maxCount: maxSpeakers,
      );
      if (ids.isEmpty) return [if (fallback != null) fallback];
      final speakers = <StoryParticipantModel>[];
      for (final id in ids) {
        for (final item in candidates) {
          if (item.id == id) speakers.add(item);
        }
      }
      return speakers.isEmpty ? [if (fallback != null) fallback] : speakers;
    } catch (_) {
      return [if (fallback != null) fallback];
    }
  }

  Future<StoryMessageModel?> _streamSpeakerReply({
    required StoryRoomDao dao,
    required ChatService chatService,
    required String input,
    required StoryParticipantModel speaker,
    required List<StoryMessageModel> historyMessages,
  }) async {
    final system = StoryContextBuilder.systemPrompt(
      room: widget.room,
      participants: _participants,
      speaker: speaker,
      latestInput: input,
      recentMessages: historyMessages,
    );
    final history = [
      {'role': 'system', 'content': system},
      ...StoryContextBuilder.history(historyMessages),
    ];
    final message = StoryMessageModel(
      roomId: widget.room.id!,
      speakerId: speaker.id,
      speakerRole: speaker.role,
      speakerName: speaker.name,
      speakerAvatarType: speaker.avatarType,
      speakerAvatarValue: speaker.avatarValue,
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
    Object? streamError;
    final done = Completer<void>();
    final stream = chatService.chatStreamEvents(
      prompt: StoryContextBuilder.promptFor(input: input, speaker: speaker),
      history: history,
    );
    late final StreamSubscription<StreamEvent> sub;
    sub = stream.listen(
      (event) {
        if (_stopRequested) return;
        if (event.type != StreamEventType.text) return;
        buffer.write(event.delta);
        message.content = buffer.toString();
        if (mounted) setState(() {});
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
    return message;
  }
}
