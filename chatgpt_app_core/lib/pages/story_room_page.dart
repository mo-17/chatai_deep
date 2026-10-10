import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/creative_file_transfer_gateway.dart';
import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_regex_executor.dart';
import 'package:chatgpt_app_core/chat/application/story_room_image_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_read_aloud_controller.dart';
import 'package:chatgpt_app_core/chat/application/story_room_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_room_tool_runner.dart';
import 'package:chatgpt_app_core/chat/application/story_participant_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_speaker_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/story_tavern_preset_transfer.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_quick_reply.dart';
import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:chatgpt_app_core/model/story_tavern_preset.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/pages/story_workbench_page.dart';
import 'package:chatgpt_app_core/pages/story_prompt_manager_page.dart';
import 'package:chatgpt_app_core/pages/story_persona_list_page.dart';
import 'package:chatgpt_app_core/pages/story_quick_replies_page.dart';
import 'package:chatgpt_app_core/pages/story_regex_scripts_page.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:chatgpt_app_core/widget/story_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class StoryRoomPage extends StatefulWidget {
  final StoryRoomModel room;
  final ReadAloudService? readAloudService;
  final StoryRoomToolRunner? toolRunner;
  final bool skipInitialLoadForTesting;

  const StoryRoomPage({
    super.key,
    required this.room,
    this.readAloudService,
    this.toolRunner,
    @visibleForTesting this.skipInitialLoadForTesting = false,
  });

  @override
  State<StoryRoomPage> createState() => _StoryRoomPageState();
}

class _StoryRoomPageState extends State<StoryRoomPage> {
  final _publicContextCtl = TextEditingController();
  final _inputController = TextEditingController();
  StoryRoomDao? _dao;
  UsageRecordService? _usageRecordService;
  List<StoryParticipantModel> _participants = const [];
  List<StoryMessageModel> _messages = const [];
  List<StoryMessageModel> _allMessages = const [];
  StoryPersonaModel? _persona;
  int? _selectedParticipantId;
  int? _forcedNextParticipantId;
  final Set<int> _skipNextParticipantIds = <int>{};
  bool _loading = true;
  bool _savingWebSearch = false;
  late final String _accountHashAtOpen;
  bool _sending = false;
  bool _stopRequested = false;
  bool _presetTransferBusy = false;
  StreamSubscription<StreamEvent>? _activeReplySub;
  Completer<void>? _activeReplyDone;
  String _generationStatus = '';
  int _lastGeneratedCompletionTokens = 0;
  String _inputText = '';
  List<String> _pendingImages = [];
  List<String> _pendingFiles = [];
  String? _selectedQuickReplyGroupKey;
  Map<String, String> _displayContentByNodeKey = const {};
  final Set<int> _streamingMessageCreatedAt = {};
  late final StoryRoomReadAloudController _readAloudController;
  late final StoryRoomToolRunner _toolRunner;

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
    _accountHashAtOpen = HiDBManager.getAccountHash();
    _toolRunner = widget.toolRunner ?? StoryRoomToolRunner();
    _readAloudController = StoryRoomReadAloudController(
      service: widget.readAloudService,
    )..addListener(_onReadAloudChanged);
    _publicContextCtl.text = widget.room.publicContext;
    if (widget.skipInitialLoadForTesting) {
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    unawaited(_activeReplySub?.cancel());
    _readAloudController
      ..removeListener(_onReadAloudChanged)
      ..dispose();
    _publicContextCtl.dispose();
    _inputController.dispose();
    super.dispose();
  }

  void _onReadAloudChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!_roomAccountCurrent) return;
    final db = await HiDBManager.instance(dbName: _accountHashAtOpen);
    final dao = await StoryRoomDao.create(db);
    final usageRecordService = UsageRecordService(await UsageDao.create(db));
    final personaDao = await StoryPersonaDao.create(db);
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
    final room = await dao.getRoom(widget.room.id!);
    final personaKey = room?.personaKey ?? widget.room.personaKey;
    final persona = personaKey?.trim().isNotEmpty == true
        ? await personaDao.getPersonaByKey(personaKey!)
        : null;
    final allMessages = await dao.getMessages(widget.room.id!);
    final messages = await dao.getActiveMessages(widget.room.id!);
    final displayContent = await _buildDisplayContent(
      messages,
      room?.regexScriptsJson ?? widget.room.regexScriptsJson,
    );
    if (!mounted || !_roomAccountCurrent) return;
    setState(() {
      if (room != null) {
        _applyRoomSnapshot(room);
      }
      _dao = dao;
      _usageRecordService = usageRecordService;
      _participants = participants;
      _messages = messages;
      _allMessages = allMessages;
      _persona = persona;
      _displayContentByNodeKey = displayContent;
      final selectedStillEnabled = participants.any(
        (item) => item.id == _selectedParticipantId && item.enabled,
      );
      if (!selectedStillEnabled) {
        _selectedParticipantId = _firstEnabledParticipantId(participants);
      }
      _loading = false;
    });
  }

  Future<void> _reloadMessages() async {
    final dao = _dao;
    final roomId = widget.room.id;
    if (dao == null || roomId == null) return;
    final room = await dao.getRoom(roomId);
    final personaDao = await StoryPersonaDao.create(dao.storage);
    final personaKey = room?.personaKey ?? widget.room.personaKey;
    final persona = personaKey?.trim().isNotEmpty == true
        ? await personaDao.getPersonaByKey(personaKey!)
        : null;
    final allMessages = await dao.getMessages(roomId);
    final messages = await dao.getActiveMessages(roomId);
    final displayContent = await _buildDisplayContent(
      messages,
      room?.regexScriptsJson ?? widget.room.regexScriptsJson,
    );
    if (!mounted) return;
    setState(() {
      if (room != null) {
        _applyRoomSnapshot(room);
      }
      _allMessages = allMessages;
      _messages = messages;
      _displayContentByNodeKey = displayContent;
      _persona = persona;
    });
  }

  Future<Map<String, String>> _buildDisplayContent(
    List<StoryMessageModel> messages,
    String rawConfig,
  ) async {
    final scripts = StoryRegexScriptsCodec.decode(rawConfig);
    if (!scripts.rules.any((rule) =>
        rule.enabled && rule.stage == StoryRegexStage.assistantDisplay)) {
      return const {};
    }
    final result = <String, String>{};
    for (final message in messages) {
      if (message.isUser || message.content.isEmpty) continue;
      final execution = await StoryRegexExecutor.execute(
        scripts: scripts,
        stage: StoryRegexStage.assistantDisplay,
        input: message.content,
      );
      if (execution.output != message.content) {
        result[message.nodeKey] = execution.output;
      }
    }
    return result;
  }

  void _applyRoomSnapshot(StoryRoomModel room) {
    widget.room
      ..title = room.title
      ..mode = room.mode
      ..replyMode = room.replyMode
      ..maxAutoReplies = room.maxAutoReplies
      ..speakerStrategy = room.speakerStrategy
      ..avoidRepeatSpeaker = room.avoidRepeatSpeaker
      ..maxAutoTotalTokens = room.maxAutoTotalTokens
      ..publicContext = room.publicContext
      ..worldBookState = room.worldBookState
      ..promptConfigJson = room.promptConfigJson
      ..quickRepliesJson = room.quickRepliesJson
      ..regexScriptsJson = room.regexScriptsJson
      ..tavernPresetJson = room.tavernPresetJson
      ..personaKey = room.personaKey
      ..webSearchEnabled = room.webSearchEnabled
      ..modelProviderId = room.modelProviderId
      ..modelId = room.modelId
      ..temperature = room.temperature
      ..topP = room.topP
      ..maxOutputTokens = room.maxOutputTokens
      ..activeMessageKey = room.activeMessageKey
      ..tavernChatMetadataJson = room.tavernChatMetadataJson
      ..createdAt = room.createdAt
      ..updatedAt = room.updatedAt;
  }

  String _displayContent(StoryMessageModel message) =>
      StoryPersonaVariables.resolve(
        _displayContentByNodeKey[message.nodeKey] ?? message.content,
        userName: _persona?.name ?? '我',
      );

  Future<StoryRegexExecutionResult> _runRegex(
    StoryRegexStage stage,
    String input,
  ) {
    final scripts = StoryRegexScriptsCodec.decode(widget.room.regexScriptsJson);
    if (!scripts.rules.any((rule) => rule.enabled && rule.stage == stage)) {
      return Future.value(StoryRegexExecutionResult(
        output: input,
        rules: const [],
        timedOut: false,
        inputTruncated: false,
        outputTruncated: false,
      ));
    }
    return StoryRegexExecutor.execute(
      scripts: scripts,
      stage: stage,
      input: input,
    );
  }

  bool _hasEnabledRegexStage(StoryRegexStage stage) =>
      StoryRegexScriptsCodec.decode(widget.room.regexScriptsJson)
          .rules
          .any((rule) => rule.enabled && rule.stage == stage);

  void _reportRegexIssues(StoryRegexExecutionResult result) {
    if (!mounted) return;
    final failed = result.rules.where((item) =>
        item.status == StoryRegexRuleStatus.failed ||
        item.status == StoryRegexRuleStatus.timedOut);
    if (failed.isEmpty && !result.inputTruncated && !result.outputTruncated) {
      return;
    }
    final suffix =
        result.timedOut ? '处理超时，已停止后续规则' : '${failed.length} 条规则未成功，消息已继续处理';
    HiDialog.showSnackBar(context, 'Regex Scripts：$suffix');
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
    final compactForKeyboard = storyUsesAnimeStyle(context) &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
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
              if (value == 'web_search') _editRoomWebSearch();
              if (value == 'prompts') _openPromptManager();
              if (value == 'quick_replies') _openQuickReplies();
              if (value == 'regex_scripts') _openRegexScripts();
              if (value == 'tavern_presets') _manageTavernPresets();
              if (value == 'persona') _selectPersona();
              if (value == 'persona_manage') _managePersonas();
              if (value == 'branches') _showStoryBranches();
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
              PopupMenuItem(
                value: 'web_search',
                enabled: _canEditRoomWebSearch,
                child: ListTile(
                  leading: const Icon(Icons.travel_explore),
                  title: const Text('联网搜索'),
                  subtitle: Text(_roomWebSearchLabel),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'persona',
                child: ListTile(
                  leading: Icon(Icons.badge_outlined),
                  title: Text('切换 Persona'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'persona_manage',
                child: ListTile(
                  leading: Icon(Icons.manage_accounts_outlined),
                  title: Text('Persona 管理'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'prompts',
                child: ListTile(
                  leading: Icon(Icons.view_list_outlined),
                  title: Text('提示词编排'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'quick_replies',
                child: ListTile(
                  leading: Icon(Icons.bolt_outlined),
                  title: Text('快捷回复'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'regex_scripts',
                child: ListTile(
                  leading: Icon(Icons.find_replace_outlined),
                  title: Text('Regex Scripts'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (_isTavern)
                const PopupMenuItem(
                  value: 'tavern_presets',
                  child: ListTile(
                    leading: Icon(Icons.settings_input_component_outlined),
                    title: Text('Tavern 预设'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (_allMessages.isNotEmpty)
                const PopupMenuItem(
                  value: 'branches',
                  child: ListTile(
                    leading: Icon(Icons.account_tree_outlined),
                    title: Text('故事分支'),
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
                if (!compactForKeyboard) ...[
                  _participantStrip,
                  const Divider(height: 1),
                ],
                Expanded(child: _messageList),
                const Divider(height: 1),
                _composer,
              ],
            ),
    );
  }

  Widget get _participantStrip {
    return StoryAdaptiveSurface(
      animeKey: const ValueKey('anime_story_participant_strip'),
      animeMargin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
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
      ),
    );
  }

  Widget get _messageList {
    if (_messages.isEmpty) {
      final message = _isTavern ? '添加角色卡后开始酒馆对话' : '添加角色后，选择发言者开始创作';
      return StoryAdaptiveEmptyState(
        classicChild: Center(child: Text(message)),
        icon: _isTavern ? Icons.forum_outlined : Icons.theater_comedy_outlined,
        title: _isTavern ? '酒馆还没有开场' : '创作舞台等待角色',
        subtitle: message,
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
              onLongPress: _sending ? null : () => _showMessageActions(message),
              child: StoryMessageBubble(
                isUser: isUser,
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
                              style: TextStyle(
                                fontSize: 12,
                                color: storyUsesAnimeStyle(context)
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                    : Colors.black54,
                              ),
                            ),
                          ),
                          if (isUser &&
                              (message.speakerAvatarValue?.trim().isNotEmpty ??
                                  false)) ...[
                            const SizedBox(width: 6),
                            _avatarForMessage(message, radius: 12),
                          ],
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
                        Text(_displayContent(message)),
                      if (message.imagePaths.isNotEmpty ||
                          message.filePaths.isNotEmpty ||
                          message.attachmentContext.trim().isNotEmpty)
                        _messageAttachments(message),
                      if (message.citationUrls.isNotEmpty)
                        _messageCitations(message),
                      if (!_streamingMessageCreatedAt
                          .contains(message.createdAt))
                        _candidateSwitcher(message),
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

  Widget _candidateSwitcher(StoryMessageModel message) {
    final variants = _variantsOf(message);
    if (variants.length <= 1) return const SizedBox.shrink();
    final index =
        variants.indexWhere((item) => item.nodeKey == message.nodeKey);
    final selected = index < 0 ? 0 : index;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一个候选',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(
              width: kStoryMinTouchTarget,
              height: kStoryMinTouchTarget,
            ),
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: _sending || selected <= 0
                ? null
                : () => _activateCandidate(variants[selected - 1]),
          ),
          Text(
            '${selected + 1}/${variants.length}',
            style: TextStyle(
              fontSize: 12,
              color: storyUsesAnimeStyle(context)
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Colors.black54,
            ),
          ),
          IconButton(
            tooltip: '下一个候选',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(
              width: kStoryMinTouchTarget,
              height: kStoryMinTouchTarget,
            ),
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _sending || selected >= variants.length - 1
                ? null
                : () => _activateCandidate(variants[selected + 1]),
          ),
        ],
      ),
    );
  }

  List<StoryMessageModel> _variantsOf(StoryMessageModel message) {
    final group = message.candidateGroupKey?.trim() ?? '';
    if (group.isEmpty) return [message];
    final variants = _allMessages
        .where((item) => item.candidateGroupKey == group)
        .toList(growable: false)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return (a.id ?? 0).compareTo(b.id ?? 0);
      });
    return variants;
  }

  Future<void> _activateCandidate(StoryMessageModel target) async {
    final dao = _dao;
    final roomId = widget.room.id;
    if (dao == null || roomId == null || target.nodeKey.trim().isEmpty) return;
    await dao.activateMessage(roomId, target.nodeKey);
    await _reloadMessages();
  }

  Future<void> _showStoryBranches() async {
    if (_allMessages.isEmpty) return;
    final rows = _branchRows(_allMessages);
    final activeKeys = _messages.map((item) => item.nodeKey).toSet();
    final selected = await showModalBottomSheet<StoryMessageModel>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.72,
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.account_tree_outlined),
                title: Text('故事分支'),
                subtitle: Text('选择任意节点作为当前剧情终点，下一条消息会从这里继续'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, index) {
                    final row = rows[index];
                    final message = row.message;
                    final active = activeKeys.contains(message.nodeKey);
                    return Padding(
                      padding: EdgeInsets.only(left: row.depth * 18.0),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          row.hasChildren
                              ? Icons.account_tree_outlined
                              : Icons.subdirectory_arrow_right,
                          color:
                              active ? Theme.of(ctx).colorScheme.primary : null,
                        ),
                        title: Text(
                          message.speakerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          message.content.trim().isEmpty
                              ? '（空消息）'
                              : message.content.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: active
                            ? const Icon(Icons.check_circle_outline, size: 18)
                            : null,
                        onTap: () => Navigator.pop(ctx, message),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _activateCandidate(selected);
  }

  static List<_StoryBranchRow> _branchRows(
    List<StoryMessageModel> messages,
  ) {
    final ordered = List<StoryMessageModel>.from(messages)
      ..sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
    final byKey = {
      for (final message in ordered)
        if (message.nodeKey.trim().isNotEmpty) message.nodeKey: message,
    };
    final children = <String?, List<StoryMessageModel>>{};
    for (final message in ordered) {
      final parent = byKey.containsKey(message.parentNodeKey)
          ? message.parentNodeKey
          : null;
      children.putIfAbsent(parent, () => []).add(message);
    }
    final result = <_StoryBranchRow>[];
    final visited = <String>{};

    void visit(StoryMessageModel message, int depth) {
      if (!visited.add(message.nodeKey)) return;
      final descendants = children[message.nodeKey] ?? const [];
      result.add(_StoryBranchRow(message, depth, descendants.isNotEmpty));
      for (final child in descendants) {
        visit(child, depth + 1);
      }
    }

    for (final root in children[null] ?? const []) {
      visit(root, 0);
    }
    for (final message in ordered) {
      if (!visited.contains(message.nodeKey)) visit(message, 0);
    }
    return result;
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
        constraints: const BoxConstraints.tightFor(
          width: kStoryMinTouchTarget,
          height: kStoryMinTouchTarget,
        ),
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
    final settings =
        _effectiveSettings(context.watch<AISettingsProvider>().settings);
    final capabilities = ChatService.capabilitiesFor(settings);
    final compactForKeyboard = storyUsesAnimeStyle(context) &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final availableWithKeyboard = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final compactInputMaxHeight =
        (availableWithKeyboard * 0.55).clamp(96.0, 180.0).toDouble();
    final input = MessageInputWidget(
      _isTavern ? '输入对话或场景动作' : '输入剧情、台词或创作指令',
      controller: _inputController,
      enable: !_sending,
      isStreaming: _sending,
      onChanged: (value) => _inputText = value,
      onSend: () => unawaited(_send()),
      onStop: _stopGeneration,
      showWebSearch: settings.webSearchConfigured,
      webSearchEnabled: settings.webSearchEnabled,
      onToggleWebSearch:
          _canEditRoomWebSearch ? () => unawaited(_toggleWebSearch()) : null,
      pendingImages: _pendingImages,
      imagesEnabled: capabilities.image,
      imagesDisabledReason: '当前模型不支持图片，请切换多模态模型',
      onImagesPicked: (paths) => setState(() =>
          _pendingImages = StoryRoomAttachmentPolicy.normalizePaths(paths)),
      onRemoveImage: (index) => setState(() {
        _pendingImages = List<String>.from(_pendingImages)..removeAt(index);
      }),
      pendingFiles: _pendingFiles,
      onFilesPicked: (paths) => setState(() =>
          _pendingFiles = StoryRoomAttachmentPolicy.normalizePaths(paths)),
      onRemoveFile: (index) => setState(() {
        _pendingFiles = List<String>.from(_pendingFiles)..removeAt(index);
      }),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: StoryAdaptiveSurface(
          animeKey: const ValueKey('anime_story_composer_controls'),
          animePadding: const EdgeInsets.all(10),
          emphasized: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compactForKeyboard) ...[
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(minHeight: kStoryMinTouchTarget),
                  child: InkWell(
                    key: const ValueKey('story_room_persona_selector'),
                    borderRadius: BorderRadius.circular(
                      storyUsesAnimeStyle(context) ? 16 : 6,
                    ),
                    onTap: _sending ? null : _selectPersona,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          AssistantAvatar.raw(
                            emoji: _persona?.avatarType == 'emoji'
                                ? _persona!.avatarValue
                                : '🙂',
                            avatarType: _persona?.avatarType,
                            avatarValue: _persona?.avatarValue,
                            radius: 12,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Persona · ${_persona?.name ?? '我'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(Icons.swap_horiz_outlined, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
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
                                    : (id) => setState(
                                        () => _selectedParticipantId = id),
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
                              style: TextStyle(
                                color: storyUsesAnimeStyle(context)
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                    : Colors.grey.shade700,
                              ),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (!compactForKeyboard &&
                  _sending &&
                  _generationStatus.isNotEmpty) ...[
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
              if (!compactForKeyboard && _quickReplyGroups.isNotEmpty) ...[
                _quickReplyBar,
                const SizedBox(height: 6),
              ],
              if (compactForKeyboard)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: compactInputMaxHeight,
                  ),
                  child: SingleChildScrollView(
                    key: const ValueKey('anime_story_compact_composer'),
                    child: input,
                  ),
                )
              else
                input,
            ],
          ),
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

  List<StoryQuickReplyGroupModel> get _quickReplyGroups =>
      StoryQuickReplyCollectionModel.tryParse(widget.room.quickRepliesJson)
          .sortedGroups(enabledOnly: true)
          .where((group) => group.sortedItems(enabledOnly: true).isNotEmpty)
          .toList(growable: false);

  StoryQuickReplyGroupModel? get _selectedQuickReplyGroup {
    final groups = _quickReplyGroups;
    if (groups.isEmpty) return null;
    for (final group in groups) {
      if (group.key == _selectedQuickReplyGroupKey) return group;
    }
    return groups.first;
  }

  Widget get _quickReplyBar {
    final groups = _quickReplyGroups;
    final selected = _selectedQuickReplyGroup ?? groups.first;
    final replies = selected.sortedItems(enabledOnly: true);
    return SizedBox(
      height: kStoryMinTouchTarget,
      child: Row(
        children: [
          if (groups.length > 1)
            SizedBox(
              width: 108,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: selected.key,
                  items: [
                    for (final group in groups)
                      DropdownMenuItem(
                        value: group.key,
                        child: Text(
                          group.label.isEmpty ? '快捷回复' : group.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _sending
                      ? null
                      : (value) =>
                          setState(() => _selectedQuickReplyGroupKey = value),
                ),
              ),
            )
          else
            Tooltip(
              message: selected.label.isEmpty ? '快捷回复' : selected.label,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    selected.label.isEmpty ? '快捷回复' : selected.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: replies.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, index) {
                final reply = replies[index];
                return ActionChip(
                  avatar: reply.sendImmediately
                      ? const Icon(Icons.send_outlined, size: 15)
                      : null,
                  label: Text(
                    reply.label.trim().isEmpty ? reply.content : reply.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: _sending
                      ? null
                      : () => unawaited(_applyQuickReply(reply)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyQuickReply(StoryQuickReplyModel reply) async {
    final current = _inputController.text;
    final resolved = reply.resolveContent(
      char: _selectedParticipant?.name ?? '',
      user: _persona?.name ?? '我',
      room: widget.room.title,
      input: current,
    );
    if (resolved.trim().isEmpty) return;
    final next = current.trim().isEmpty || reply.content.contains('{{input}}')
        ? resolved
        : '$current\n$resolved';
    _inputController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _inputText = next;
    if (reply.sendImmediately) await _send();
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
              borderRadius: BorderRadius.circular(
                storyUsesAnimeStyle(context) ? 14 : 6,
              ),
              child: Image.file(
                File(path),
                width: 54,
                height: 54,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 54,
                  height: 54,
                  color: storyUsesAnimeStyle(context)
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                      : Colors.black12,
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
        borderRadius: BorderRadius.circular(
          storyUsesAnimeStyle(context) ? 14 : 6,
        ),
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

  Widget _messageCitations(StoryMessageModel message) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var index = 0; index < message.citationUrls.length; index++)
            TextButton.icon(
              onPressed: () async {
                final uri = Uri.tryParse(message.citationUrls[index]);
                if (uri != null) await launchUrl(uri);
              },
              icon: const Icon(Icons.link, size: 14),
              label: Text('来源 ${index + 1}'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
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
    final participant = await _participantFromAssistant(assistant);
    await dao.saveParticipant(participant);
    await _load();
  }

  Future<void> _showMessageActions(StoryMessageModel message) async {
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
              subtitle: const Text('保留原消息，并从编辑版本建立新分支'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            if (StoryRegexScriptsCodec.decode(widget.room.regexScriptsJson)
                .rules
                .isNotEmpty)
              ListTile(
                leading: const Icon(Icons.find_replace_outlined),
                title: const Text('预览 Regex 处理'),
                subtitle: const Text('只预览，不修改消息或上下文'),
                onTap: () => Navigator.pop(ctx, 'regex_preview'),
              ),
            if (message.speakerId != null)
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('更新角色长期状态'),
                subtitle: const Text('保存到当前故事分支，不调用 AI'),
                onTap: () => Navigator.pop(ctx, 'role_state'),
              ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.refresh_outlined),
                title: const Text('生成备选回复'),
                subtitle: const Text('保留当前候选，使用之前的上下文重新生成'),
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
        await Clipboard.setData(ClipboardData(text: _displayContent(message)));
        if (mounted) HiDialog.showSnackBar(context, '已复制');
        return;
      case 'edit':
        await _editMessage(message);
        return;
      case 'regex_preview':
        await _previewMessageRegex(message);
        return;
      case 'role_state':
        final participant = _participantById(message.speakerId);
        if (participant != null) await _editParticipantState(participant);
        return;
      case 'regenerate':
        await _regenerateMessage(message);
        return;
      case 'continue':
        await _continueMessage(message);
        return;
      case 'delete':
        await _deleteMessage(message);
        return;
    }
  }

  Future<void> _previewMessageRegex(StoryMessageModel message) async {
    final firstStage = message.isUser
        ? StoryRegexStage.userInput
        : StoryRegexStage.assistantOutput;
    final first = await _runRegex(firstStage, message.content);
    final display = message.isUser
        ? null
        : await _runRegex(StoryRegexStage.assistantDisplay, first.output);
    if (!mounted) return;
    final finalOutput = display?.output ?? first.output;
    final results = [...first.rules, ...?display?.rules];
    final relevant = results.where(
      (item) => item.status != StoryRegexRuleStatus.skipped,
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regex 处理预览'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('原文', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                SelectableText(message.content),
                const SizedBox(height: 16),
                const Text('处理后',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                SelectableText(finalOutput),
                const SizedBox(height: 16),
                Text(
                  relevant.isEmpty
                      ? '没有规则命中此阶段'
                      : relevant
                          .map((item) =>
                              '${item.key} · ${item.status.name} · ${item.elapsed.inMilliseconds}ms'
                              '${item.error == null ? '' : ' · ${item.error}'}')
                          .join('\n'),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
          decoration: InputDecoration(border: storyInputBorder(ctx)),
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
    final edited = StoryMessageModel(
      roomId: message.roomId,
      speakerId: message.speakerId,
      speakerRole: message.speakerRole,
      speakerName: message.speakerName,
      speakerAvatarType: message.speakerAvatarType,
      speakerAvatarValue: message.speakerAvatarValue,
      speakerVoiceStyle: message.speakerVoiceStyle,
      speakerPersonaKey: message.speakerPersonaKey,
      content: content,
      imagePaths: message.imagePaths,
      imageSources: message.imageSources,
      citationUrls: message.citationUrls,
      filePaths: message.filePaths,
      attachmentContext: message.attachmentContext,
      parentNodeKey: message.parentNodeKey,
      candidateGroupKey: message.candidateGroupKey,
      contextStateAfter: message.contextStateAfter,
      roleStatesAfter: message.roleStatesAfter,
    );
    await _dao?.saveMessage(edited);
    await _reloadMessages();
  }

  Future<void> _deleteMessage(StoryMessageModel message) async {
    final nodeKey = message.nodeKey.trim();
    final roomId = widget.room.id;
    if (nodeKey.isEmpty || roomId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('这会删除该消息以及从它继续产生的整条子分支，其他候选和分支会保留。'),
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
    await _dao?.deleteMessageSubtree(roomId, nodeKey);
    await _reloadMessages();
  }

  Future<void> _regenerateMessage(StoryMessageModel message) async {
    final speaker = _participantById(message.speakerId);
    if (speaker == null) {
      HiDialog.showSnackBar(context, '原角色已移出或暂停，无法重新生成');
      return;
    }
    final dao = _dao;
    final roomId = widget.room.id;
    final parentKey = message.parentNodeKey?.trim() ?? '';
    if (dao == null || roomId == null || parentKey.isEmpty) {
      HiDialog.showSnackBar(context, '找不到这条回复所属的剧情节点');
      return;
    }
    final restoreKey = widget.room.activeMessageKey;
    await dao.activateMessage(roomId, parentKey);
    await _reloadMessages();
    if (!mounted) return;
    final userMessage =
        _messages.reversed.cast<StoryMessageModel?>().firstWhere(
              (item) => item?.isUser == true,
              orElse: () => null,
            );
    if (userMessage == null) {
      if (mounted) HiDialog.showSnackBar(context, '找不到触发这条回复的用户消息');
      if (restoreKey?.isNotEmpty == true) {
        await dao.activateMessage(roomId, restoreKey!);
        await _reloadMessages();
      }
      return;
    }
    if (!mounted) return;
    final input = userMessage.content;
    final history = _messages.last.nodeKey == userMessage.nodeKey
        ? _messages.sublist(0, _messages.length - 1)
        : List<StoryMessageModel>.from(_messages);
    final settings =
        _effectiveSettings(context.read<AISettingsProvider>().settings);
    final attachmentBundle = await StoryRoomAttachmentService.prepare(
      imagePaths: userMessage.imagePaths,
      filePaths: userMessage.filePaths,
      capabilities: ChatService.capabilitiesFor(settings),
      limits: settings.attachmentProcessingLimits,
      fallbackContext: userMessage.attachmentContext,
      reuseExtractedContext: true,
    );
    final reply = await _runSingleSpeakerGeneration(
      input: input,
      speaker: speaker,
      historyMessages: history,
      attachmentBundle: attachmentBundle,
      candidateGroupKey: message.candidateGroupKey,
    );
    if (reply == null && restoreKey?.isNotEmpty == true) {
      await dao.activateMessage(roomId, restoreKey!);
    }
    await _reloadMessages();
  }

  Future<void> _continueMessage(StoryMessageModel message) async {
    final speaker = _participantById(message.speakerId);
    if (speaker == null) {
      HiDialog.showSnackBar(context, '原角色已移出或暂停，无法继续生成');
      return;
    }
    final dao = _dao;
    final roomId = widget.room.id;
    if (dao == null || roomId == null || message.nodeKey.trim().isEmpty) return;
    final restoreKey = widget.room.activeMessageKey;
    await dao.activateMessage(roomId, message.nodeKey);
    await _reloadMessages();
    final reply = await _runSingleSpeakerGeneration(
      input: '请从上一段中断处继续，保持相同语气和场景，不要重复已经生成的内容。',
      speaker: speaker,
      historyMessages: List<StoryMessageModel>.from(_messages),
    );
    if (reply == null && restoreKey?.isNotEmpty == true) {
      await dao.activateMessage(roomId, restoreKey!);
    }
    await _reloadMessages();
  }

  StoryParticipantModel? _participantById(int? id) {
    for (final item in _participants) {
      if (item.id == id && item.enabled) return item;
    }
    return null;
  }

  Future<StoryMessageModel?> _runSingleSpeakerGeneration({
    required String input,
    required StoryParticipantModel speaker,
    required List<StoryMessageModel> historyMessages,
    StoryRoomAttachmentBundle? attachmentBundle,
    String? candidateGroupKey,
  }) async {
    final dao = _dao;
    if (dao == null || _sending) return null;
    final settings =
        _effectiveSettings(context.read<AISettingsProvider>().settings);
    setState(() {
      _sending = true;
      _stopRequested = false;
      _generationStatus = '${speaker.name} 正在发言...';
    });
    StoryMessageModel? reply;
    try {
      reply = await _streamSpeakerReply(
        dao: dao,
        settings: settings,
        input: input,
        speaker: speaker,
        historyMessages: historyMessages,
        attachmentBundle: attachmentBundle,
        candidateGroupKey: candidateGroupKey,
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
    return reply;
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
            ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('角色长期状态'),
              subtitle: Text(
                participant.stateSummary.trim().isEmpty
                    ? '当前分支尚未记录状态'
                    : participant.stateSummary.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(ctx, 'state'),
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
            if (_isTavern &&
                participant.enabled &&
                participant.role == StoryParticipantRole.assistant &&
                widget.room.replyMode != StoryReplyMode.manual)
              ListTile(
                leading: const Icon(Icons.skip_next_outlined),
                title: Text(
                  _skipNextParticipantIds.contains(participant.id)
                      ? '取消下一轮跳过'
                      : '下一轮跳过该角色',
                ),
                subtitle: const Text('只影响下一次发送，不会暂停角色'),
                onTap: () => Navigator.pop(ctx, 'skip_next'),
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
      case 'state':
        await _editParticipantState(participant);
        return;
      case 'sync':
        await _syncParticipantFromAssistant(participant);
        return;
      case 'force_next':
        setState(() {
          _forcedNextParticipantId = participant.id;
          _skipNextParticipantIds.remove(participant.id);
          _selectedParticipantId = participant.id;
        });
        HiDialog.showSnackBar(context, '下一位将由「${participant.name}」发言');
        return;
      case 'skip_next':
        final participantId = participant.id;
        if (participantId == null) return;
        setState(() {
          if (!_skipNextParticipantIds.remove(participantId)) {
            _skipNextParticipantIds.add(participantId);
            if (_forcedNextParticipantId == participantId) {
              _forcedNextParticipantId = null;
            }
          }
        });
        HiDialog.showSnackBar(
          context,
          _skipNextParticipantIds.contains(participantId)
              ? '下一轮将跳过「${participant.name}」'
              : '已取消跳过「${participant.name}」',
        );
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
    final topPController = TextEditingController(
      text: participant.topP?.toString() ?? '',
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
      topPController.dispose();
      maxTokensController.dispose();
      return;
    }
    var voiceStyle = participant.voiceStyle ?? TtsVoiceStyle.system.id;
    var providerId = participant.modelProviderId?.trim() ?? '';
    final hasVoiceStyle = TtsVoiceStyle.isValid(voiceStyle) ||
        userVoiceModels.any((model) => model.voiceStyleId == voiceStyle);
    if (!hasVoiceStyle) voiceStyle = TtsVoiceStyle.system.id;
    final saved = await showDialog<
        (String, String, String, String?, String?, double?, double?, int?)>(
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
                  decoration: InputDecoration(
                    labelText: '显示名称',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: promptController,
                  minLines: 5,
                  maxLines: 10,
                  decoration: InputDecoration(
                    labelText: '房间内人设 / 职责',
                    border: storyInputBorder(ctx),
                  ),
                ),
                if (global.mode == AIMode.local) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: global.enabledProviders
                            .any((provider) => provider.id == providerId)
                        ? providerId
                        : '',
                    decoration: InputDecoration(
                      labelText: '角色服务商覆盖',
                      border: storyInputBorder(ctx),
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
                  decoration: InputDecoration(
                    labelText: '角色模型覆盖',
                    hintText: '留空跟随房间设置',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: temperatureController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '角色 Temperature 覆盖',
                    hintText: '留空跟随房间设置，范围 0-2',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: topPController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: '角色 Top P 覆盖',
                    hintText: '留空跟随房间设置，范围 0-1',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: maxTokensController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '角色最大输出 Token 覆盖',
                    hintText: '留空跟随房间设置，0 表示不限制',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: voiceStyle,
                  decoration: InputDecoration(
                    labelText: '朗读音色风格',
                    border: storyInputBorder(ctx),
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
                final topPText = topPController.text.trim();
                final maxTokensText = maxTokensController.text.trim();
                final temperature = temperatureText.isEmpty
                    ? null
                    : double.tryParse(temperatureText);
                final topP =
                    topPText.isEmpty ? null : double.tryParse(topPText);
                final maxTokens =
                    maxTokensText.isEmpty ? null : int.tryParse(maxTokensText);
                if (temperatureText.isNotEmpty &&
                    (temperature == null ||
                        !temperature.isFinite ||
                        temperature < 0 ||
                        temperature > 2)) {
                  return;
                }
                if (maxTokensText.isNotEmpty &&
                    (maxTokens == null || maxTokens < 0)) {
                  return;
                }
                if (topPText.isNotEmpty &&
                    (topP == null || !topP.isFinite || topP < 0 || topP > 1)) {
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
                  topP,
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
    topPController.dispose();
    maxTokensController.dispose();
    if (saved == null) return;
    participant.name = saved.$1;
    participant.prompt = saved.$2;
    participant.voiceStyle = saved.$3;
    participant
      ..modelProviderId = saved.$4
      ..modelId = saved.$5
      ..temperature = saved.$6
      ..topP = saved.$7
      ..maxOutputTokens = saved.$8;
    await _dao?.saveParticipant(participant);
    await _load();
  }

  Future<void> _editParticipantState(
    StoryParticipantModel participant,
  ) async {
    final controller = TextEditingController(text: participant.stateSummary);
    final result = await showDialog<(bool, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${participant.name} · 长期状态'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('记录关系、情绪、身体状态和未完成动作。状态只影响当前故事分支，不会调用 AI。'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 5,
                maxLines: 12,
                decoration: InputDecoration(
                  labelText: '当前分支角色状态',
                  hintText: '例如：仍警惕用户；左臂受伤；答应在天亮前返回。',
                  border: storyInputBorder(ctx),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (participant.stateSummary.trim().isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, (true, '')),
              child: const Text('清空状态'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (false, controller.text)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final dao = _dao;
    final roomId = widget.room.id;
    if (dao == null || roomId == null) return;
    final state = result.$1 ? '' : result.$2.trim();
    final saved = await dao.updateParticipantState(
      roomId,
      participant.participantKey,
      state,
    );
    if (!saved) {
      if (mounted) HiDialog.showSnackBar(context, '角色状态保存失败');
      return;
    }
    await _load();
    if (!mounted) return;
    HiDialog.showSnackBar(context, state.isEmpty ? '已清空角色状态' : '角色状态已保存到当前分支');
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
      ..prompt = await assistant.systemPromptForSafely('')
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

  Future<StoryParticipantModel> _participantFromAssistant(
      AssistantModel assistant) async {
    final avatar = _avatarFromAssistant(assistant);
    return StoryParticipantModel(
      roomId: widget.room.id!,
      assistantId: assistant.id,
      role: StoryParticipantRole.assistant,
      name: assistant.name,
      prompt: await assistant.systemPromptForSafely(''),
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
          decoration: InputDecoration(
            hintText: '世界观、当前章节、场景、时间线、写作风格等',
            border: storyInputBorder(ctx),
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
    final topPController = TextEditingController(
      text: widget.room.topP?.toString() ?? '',
    );
    final maxTokensController = TextEditingController(
      text: widget.room.maxOutputTokens?.toString() ?? '',
    );
    final saved = await showDialog<(String?, String?, double?, double?, int?)>(
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
                    decoration: InputDecoration(
                      labelText: '服务商',
                      border: storyInputBorder(ctx),
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
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: temperatureController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Temperature',
                    hintText: '留空跟随全局，范围 0-2',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: topPController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Top P',
                    hintText: '留空跟随全局，范围 0-1',
                    border: storyInputBorder(ctx),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: maxTokensController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '最大输出 Token',
                    hintText: '留空跟随全局，0 表示不限制',
                    border: storyInputBorder(ctx),
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
                final topPText = topPController.text.trim();
                final maxTokensText = maxTokensController.text.trim();
                final temperature = temperatureText.isEmpty
                    ? null
                    : double.tryParse(temperatureText);
                final topP =
                    topPText.isEmpty ? null : double.tryParse(topPText);
                final maxTokens =
                    maxTokensText.isEmpty ? null : int.tryParse(maxTokensText);
                if (temperatureText.isNotEmpty &&
                    (temperature == null ||
                        !temperature.isFinite ||
                        temperature < 0 ||
                        temperature > 2)) {
                  return;
                }
                if (maxTokensText.isNotEmpty &&
                    (maxTokens == null || maxTokens < 0)) {
                  return;
                }
                if (topPText.isNotEmpty &&
                    (topP == null || !topP.isFinite || topP < 0 || topP > 1)) {
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
                    topP,
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
    topPController.dispose();
    maxTokensController.dispose();
    if (saved == null) return;
    widget.room
      ..modelProviderId = saved.$1
      ..modelId = saved.$2
      ..temperature = saved.$3
      ..topP = saved.$4
      ..maxOutputTokens = saved.$5;
    await _dao?.saveRoom(widget.room);
    if (mounted) {
      setState(() {});
      HiDialog.showSnackBar(context, '房间模型设置已保存');
    }
  }

  Future<void> _manageTavernPresets() async {
    final presets = StoryTavernPresetTransfer.previewsFromRoomBundle(
      widget.room.tavernPresetJson,
    );
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Tavern 预设', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                presets.isEmpty
                    ? '尚未导入预设'
                    : presets
                        .map((item) => _presetKindLabel(item.kind!))
                        .join(' · '),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入预设 JSON'),
                subtitle:
                    const Text('支持 Context、Instruct、Sampler 与 OpenAI Preset'),
                onTap: () => Navigator.pop(ctx, 'import'),
              ),
              if (presets.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.save_alt_outlined),
                  title: const Text('导出安全预设包'),
                  subtitle: const Text('敏感字段和可执行内容已移除'),
                  onTap: () => Navigator.pop(ctx, 'export'),
                ),
              if (presets.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('移除房间预设'),
                  onTap: () => Navigator.pop(ctx, 'clear'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == 'import') await _importTavernPreset();
    if (action == 'export') await _exportTavernPresets();
    if (action == 'clear') {
      widget.room.tavernPresetJson = '';
      await _dao?.saveRoom(widget.room);
      if (mounted) {
        setState(() {});
        HiDialog.showSnackBar(context, '已移除房间预设；已应用的生成参数保持不变');
      }
    }
  }

  Future<void> _importTavernPreset() async {
    if (_presetTransferBusy) return;
    if (Platform.operatingSystem == 'ohos') {
      HiDialog.showSnackBar(context, '鸿蒙版本暂不支持预设文件选择');
      return;
    }
    setState(() => _presetTransferBusy = true);
    try {
      final source = await CreativeFileTransferGateway(
        maxBytes: StoryTavernPresetTransfer.maxRoomBundleBytes,
      ).pickUtf8Text(
        dialogTitle: '选择 Tavern 预设',
        allowedExtensions: const ['json'],
      );
      if (source == null || !mounted) return;
      final previews = StoryTavernPresetTransfer.previewImportFile(source);
      if (previews.isEmpty) {
        final rejected = StoryTavernPresetTransfer.previewJson(source);
        throw FormatException(rejected.error ?? '无法识别 Tavern 预设');
      }
      if (!mounted) return;
      final hasPromptData = previews.any(
        (item) => item.openAiPromptData?.isNotEmpty == true,
      );
      final decision = await _confirmTavernPresetImport(
        previews,
        canApplyPromptManager: hasPromptData,
      );
      if (decision == null || !mounted) return;
      final freshRoom = await _dao?.getRoom(widget.room.id!);
      if (!mounted) return;
      if (freshRoom != null) _applyRoomSnapshot(freshRoom);
      var stored = widget.room.tavernPresetJson;
      for (final preview in previews) {
        stored = StoryTavernPresetTransfer.mergeRoomBundle(stored, preview);
        final values = preview.applyValues;
        if (values.temperature != null) {
          widget.room.temperature = values.temperature;
        }
        if (values.topP != null) widget.room.topP = values.topP;
        if (values.maxTokens != null) {
          widget.room.maxOutputTokens = values.maxTokens;
        }
        if (decision && preview.openAiPromptData?.isNotEmpty == true) {
          widget.room.promptConfigJson = StoryPromptConfigCodec.encode(
            StoryPromptConfigCodec.fromTavernExtensions(
              preview.openAiPromptData!,
            ),
          );
        }
      }
      widget.room.tavernPresetJson = stored;
      await _dao?.saveRoom(widget.room);
      if (!mounted) return;
      setState(() {});
      HiDialog.showSnackBar(context, 'Tavern 预设已安全导入');
    } on FormatException catch (e) {
      if (mounted) HiDialog.showSnackBar(context, e.message);
    } on CreativeFileTransferException catch (e) {
      if (mounted) HiDialog.showSnackBar(context, e.message);
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导入预设失败：$e');
    } finally {
      if (mounted) setState(() => _presetTransferBusy = false);
    }
  }

  Future<bool?> _confirmTavernPresetImport(
    List<StoryTavernPresetPreview> previews, {
    required bool canApplyPromptManager,
  }) {
    var applyPromptManager = canApplyPromptManager;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('导入 Tavern 预设'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '识别：${previews.map((item) => _presetKindLabel(item.kind!)).join('、')}'),
                  const SizedBox(height: 10),
                  for (final preview in previews) ...[
                    if (preview.applyValues.temperature != null)
                      Text('Temperature：${preview.applyValues.temperature}'),
                    if (preview.applyValues.topP != null)
                      Text('Top P：${preview.applyValues.topP}'),
                    if (preview.applyValues.maxTokens != null)
                      Text('最大输出 Token：${preview.applyValues.maxTokens}'),
                  ],
                  if (canApplyPromptManager)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: applyPromptManager,
                      title: const Text('导入 Prompt Manager 编排'),
                      subtitle: const Text('仅导入声明式提示词，不执行脚本或宏'),
                      onChanged: (value) => setDialogState(
                        () => applyPromptManager = value ?? false,
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text('Context / Instruct 仅保存用于兼容导出，不参与请求执行。'),
                  for (final warning
                      in previews.expand((item) => item.warnings).take(8))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('• $warning'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, applyPromptManager),
              child: const Text('确认导入'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportTavernPresets() async {
    if (_presetTransferBusy) return;
    if (Platform.operatingSystem == 'ohos') {
      HiDialog.showSnackBar(context, '鸿蒙版本暂不支持预设文件保存');
      return;
    }
    setState(() => _presetTransferBusy = true);
    try {
      final content = StoryTavernPresetTransfer.exportRoomBundleJson(
        widget.room.tavernPresetJson,
      );
      final bytes = Uint8List.fromList(utf8.encode(content));
      final safeTitle = widget.room.title
          .replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final result = await CreativeFileTransferGateway().saveBytes(
        bytes,
        dialogTitle: '导出 Tavern 预设包',
        fileName: '${safeTitle.isEmpty ? '酒馆房间' : safeTitle}_presets.json',
        allowedExtensions: const ['json'],
      );
      if (!result.saved) return;
      if (mounted) HiDialog.showSnackBar(context, 'Tavern 预设包已导出');
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导出预设失败：$e');
    } finally {
      if (mounted) setState(() => _presetTransferBusy = false);
    }
  }

  String _presetKindLabel(StoryTavernPresetKind kind) {
    switch (kind) {
      case StoryTavernPresetKind.context:
        return 'Context';
      case StoryTavernPresetKind.instruct:
        return 'Instruct';
      case StoryTavernPresetKind.textgenSampler:
        return 'Sampler';
      case StoryTavernPresetKind.openAi:
        return 'OpenAI Preset';
    }
  }

  Future<void> _editTavernReplyMode() async {
    var mode = StoryReplyMode.normalize(widget.room.replyMode);
    var maxReplies = widget.room.maxAutoReplies.clamp(1, 3).toInt();
    var strategy = StorySpeakerStrategy.normalize(widget.room.speakerStrategy);
    var avoidRepeat = widget.room.avoidRepeatSpeaker;
    var maxTotalTokens = StoryRoomSchedulingLimits.normalizeMaxAutoTotalTokens(
      widget.room.maxAutoTotalTokens,
    );
    final tokenOptions = <int>{
      512,
      1024,
      2048,
      4096,
      8192,
      16384,
      32768,
      maxTotalTokens,
    }.toList()
      ..sort();
    final saved = await showModalBottomSheet<
        ({
          String mode,
          int maxReplies,
          String strategy,
          bool avoidRepeat,
          int maxTotalTokens,
        })>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: SingleChildScrollView(
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
                if (mode != StoryReplyMode.manual) ...[
                  const SizedBox(height: 12),
                  Text('角色选择策略', style: Theme.of(ctx).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: StorySpeakerStrategy.smart,
                        icon: Icon(Icons.auto_awesome_outlined),
                        label: Text('智能'),
                      ),
                      ButtonSegment(
                        value: StorySpeakerStrategy.roundRobin,
                        icon: Icon(Icons.sync_outlined),
                        label: Text('按顺序'),
                      ),
                    ],
                    selected: {strategy},
                    onSelectionChanged: (values) =>
                        setSheetState(() => strategy = values.first),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('避免连续同角色'),
                    subtitle: const Text('被点名或只剩一个角色时仍允许连续发言'),
                    value: avoidRepeat,
                    onChanged: (value) =>
                        setSheetState(() => avoidRepeat = value),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: maxTotalTokens,
                    decoration: InputDecoration(
                      labelText: '本轮总输出 Token 上限',
                      border: storyInputBorder(ctx),
                    ),
                    items: [
                      for (final value in tokenOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text('$value tokens'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setSheetState(() => maxTotalTokens = value);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, (
                    mode: mode,
                    maxReplies: maxReplies,
                    strategy: strategy,
                    avoidRepeat: avoidRepeat,
                    maxTotalTokens: maxTotalTokens,
                  )),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == null) return;
    widget.room.replyMode = saved.mode;
    widget.room.maxAutoReplies = saved.mode == StoryReplyMode.autoMulti
        ? saved.maxReplies.clamp(2, 3)
        : 1;
    widget.room
      ..speakerStrategy = StorySpeakerStrategy.normalize(saved.strategy)
      ..avoidRepeatSpeaker = saved.avoidRepeat
      ..maxAutoTotalTokens =
          StoryRoomSchedulingLimits.normalizeMaxAutoTotalTokens(
        saved.maxTotalTokens,
      );
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

  Future<void> _openPromptManager() async {
    final dao = _dao;
    if (dao == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoryPromptManagerPage(
          room: widget.room,
          onSave: (room) async {
            await dao.saveRoom(room);
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openQuickReplies() async {
    final dao = _dao;
    if (dao == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoryQuickRepliesPage(
          room: widget.room,
          onSave: (room) async {
            await dao.saveRoom(room);
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openRegexScripts() async {
    final dao = _dao;
    if (dao == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoryRegexScriptsPage(
          room: widget.room,
          onSave: (room) async {
            await dao.saveRoom(room);
          },
        ),
      ),
    );
    if (!mounted) return;
    final displayContent = await _buildDisplayContent(
      _messages,
      widget.room.regexScriptsJson,
    );
    if (mounted) setState(() => _displayContentByNodeKey = displayContent);
  }

  Future<void> _selectPersona() async {
    final dao = _dao;
    if (dao == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const CircleAvatar(child: Text('我')),
              title: const Text('使用默认身份“我”'),
              onTap: () => Navigator.pop(ctx, 'default'),
            ),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('从 Persona 列表选择'),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'default') {
      widget.room.personaKey = null;
      await dao.saveRoom(widget.room);
      if (mounted) setState(() => _persona = null);
      return;
    }
    final selected = await Navigator.push<StoryPersonaModel>(
      context,
      MaterialPageRoute(
        builder: (_) => const StoryPersonaListPage(selectionMode: true),
      ),
    );
    if (selected == null || !mounted) return;
    widget.room.personaKey = selected.personaKey;
    await dao.saveRoom(widget.room);
    if (mounted) setState(() => _persona = selected);
  }

  Future<void> _managePersonas() async {
    final dao = _dao;
    if (dao == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const StoryPersonaListPage()),
    );
    if (!mounted) return;
    final personaKey = widget.room.personaKey;
    if (personaKey?.trim().isNotEmpty != true) return;
    final personaDao = await StoryPersonaDao.create(dao.storage);
    final persona = await personaDao.getPersonaByKey(personaKey!);
    if (persona == null) {
      widget.room.personaKey = null;
      await dao.saveRoom(widget.room);
    }
    if (mounted) setState(() => _persona = persona);
  }

  Future<void> _send() async {
    if (_sending) return;
    final dao = _dao;
    final manualSpeaker = _selectedParticipant;
    var input = _inputText.trim();
    if (dao == null || input.isEmpty) return;
    if (_hasEnabledRegexStage(StoryRegexStage.userInput) &&
        input.length > StoryRegexScriptLimits.maxTextLength) {
      HiDialog.showSnackBar(
        context,
        '输入超过 ${StoryRegexScriptLimits.maxTextLength} 字，暂不能执行 Regex Scripts',
      );
      return;
    }
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
        // 先锁住发送，避免正则与附件处理期间重复触发下一轮请求。
        _sending = true;
        _stopRequested = false;
        _generationStatus = '正在处理输入规则...';
      });
    }
    final inputRegex = await _runRegex(StoryRegexStage.userInput, input);
    _reportRegexIssues(inputRegex);
    input = inputRegex.output.trim();
    if (input.isEmpty) {
      if (mounted) {
        setState(() {
          _sending = false;
          _generationStatus = '';
        });
        HiDialog.showSnackBar(context, '输入经 Regex Scripts 处理后为空，已取消发送');
      }
      return;
    }
    if (mounted) {
      setState(() {
        _generationStatus = '准备附件...';
      });
    }
    late final StoryRoomAttachmentBundle attachmentBundle;
    try {
      attachmentBundle = await StoryRoomAttachmentService.prepare(
        imagePaths: pendingImages,
        filePaths: pendingFiles,
        capabilities: capabilities,
        limits: settings.attachmentProcessingLimits,
        isCancelled: () => _stopRequested || !mounted,
      );
      if (_stopRequested || !mounted) {
        if (mounted) {
          setState(() {
            _sending = false;
            _generationStatus = '';
            _stopRequested = false;
          });
        }
        return;
      }
    } catch (error) {
      if (mounted) {
        final stopped = _stopRequested;
        setState(() {
          _sending = false;
          _generationStatus = '';
          _stopRequested = false;
        });
        if (!stopped) HiDialog.showSnackBar(context, '附件检查失败：$error');
      }
      return;
    }
    // 仅在整轮附件通过检查后清理输入，超限或停止仍可删减后重发。
    if (mounted) {
      setState(() {
        _inputText = '';
        _pendingImages = [];
        _pendingFiles = [];
      });
    }
    _inputController.clear();
    final previousMessages = List<StoryMessageModel>.from(_messages);
    final userMessage = StoryMessageModel(
      roomId: widget.room.id!,
      speakerRole: 'user',
      speakerName: _persona?.name ?? '我',
      speakerAvatarType: _persona?.avatarType,
      speakerAvatarValue: _persona?.avatarValue,
      speakerPersonaKey: _persona?.personaKey,
      content: input,
      imagePaths: attachmentBundle.imagePaths,
      filePaths: attachmentBundle.filePaths,
      attachmentContext: attachmentBundle.attachmentContext,
      contextStateAfter: widget.room.worldBookState,
    );
    if (mounted) {
      setState(() {
        _generationStatus = '准备生成回复...';
        _messages = [..._messages, userMessage];
        _allMessages = [..._allMessages, userMessage];
      });
    }
    await dao.saveMessage(userMessage);
    widget.room.activeMessageKey = userMessage.nodeKey;

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
      var usedCompletionTokens = 0;
      var stoppedByTokenBudget = false;
      final enforceTokenBudget = _isTavern && !manual;
      for (final speaker in speakers) {
        if (_stopRequested) break;
        final remainingTokens = enforceTokenBudget
            ? widget.room.maxAutoTotalTokens - usedCompletionTokens
            : null;
        if (remainingTokens != null && remainingTokens <= 0) {
          stoppedByTokenBudget = true;
          break;
        }
        final reply = await _streamSpeakerReply(
          dao: dao,
          settings: settings,
          input: input,
          speaker: speaker,
          historyMessages: workingHistory,
          attachmentBundle: attachmentBundle,
          completionTokenLimit: remainingTokens,
        );
        if (reply == null) break;
        replies.add(reply);
        usedCompletionTokens += _lastGeneratedCompletionTokens;
        workingHistory = [...workingHistory, userMessage, ...replies];
      }
      if (stoppedByTokenBudget && mounted) {
        HiDialog.showSnackBar(context, '已达本轮自动发言 Token 上限');
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

  bool get _roomAccountCurrent =>
      HiDBManager.getAccountHash() == _accountHashAtOpen;

  bool get _canEditRoomWebSearch =>
      !_loading &&
      !_sending &&
      !_savingWebSearch &&
      _dao != null &&
      widget.room.id != null &&
      _roomAccountCurrent;

  String get _roomWebSearchLabel {
    final override = widget.room.webSearchEnabled;
    if (override != null) return override ? '仅此房间开启' : '仅此房间关闭';
    final enabled =
        context.read<AISettingsProvider>().settings.webSearchEnabled;
    return '跟随全局默认（当前${enabled ? '开启' : '关闭'}）';
  }

  Future<void> _toggleWebSearch() async {
    if (!_canEditRoomWebSearch) return;
    final settings =
        _effectiveSettings(context.read<AISettingsProvider>().settings);
    await _saveRoomWebSearch(!settings.webSearchEnabled);
  }

  Future<void> _editRoomWebSearch() async {
    if (!_canEditRoomWebSearch) return;
    final room = widget.room;
    final global = context.read<AISettingsProvider>().settings.webSearchEnabled;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('房间联网搜索'),
        children: [
          for (final option in [
            (-1, '跟随全局默认', '当前默认：${global ? '开启' : '关闭'}'),
            (1, '仅此房间开启', '不随全局默认变化'),
            (0, '仅此房间关闭', '不随全局默认变化'),
          ])
            ListTile(
              key: ValueKey('room_web_search_${option.$1}'),
              title: Text(option.$2),
              subtitle: Text(option.$3),
              trailing: (room.webSearchEnabled == null
                      ? option.$1 == -1
                      : option.$1 == (room.webSearchEnabled! ? 1 : 0))
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(ctx, option.$1),
            ),
        ],
      ),
    );
    if (!mounted || !identical(room, widget.room) || picked == null) return;
    await _saveRoomWebSearch(picked == -1 ? null : picked == 1);
  }

  Future<void> _saveRoomWebSearch(bool? enabled) async {
    if (!_canEditRoomWebSearch) return;
    final room = widget.room;
    final dao = _dao!;
    setState(() => _savingWebSearch = true);
    try {
      final updated = await dao.updateWebSearchOverride(room.id!, enabled);
      if (!mounted || !_roomAccountCurrent || !identical(room, widget.room)) {
        return;
      }
      if (updated != 1) throw StateError('房间不存在');
      setState(() => room.webSearchEnabled = enabled);
      HiDialog.showSnackBar(context, '联网搜索：$_roomWebSearchLabel');
    } catch (_) {
      if (mounted && _roomAccountCurrent && identical(room, widget.room)) {
        HiDialog.showSnackBar(context, '联网搜索设置未保存，请重试');
      }
    } finally {
      if (mounted) setState(() => _savingWebSearch = false);
    }
  }

  Future<bool> _confirmRoomToolAction(String title, String detail) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(child: Text(detail)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('允许'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<List<StoryParticipantModel>> _scheduleTavernSpeakers({
    required ChatService chatService,
    required AISettings settings,
    required String input,
    required List<StoryMessageModel> previousMessages,
  }) async {
    final candidates = StorySpeakerScheduler.tavernCandidates(_participants);
    final skippedIds = Set<int>.from(_skipNextParticipantIds);
    if (skippedIds.isNotEmpty) {
      _skipNextParticipantIds.clear();
      candidates.removeWhere((candidate) => skippedIds.contains(candidate.id));
      if (candidates.isEmpty) {
        candidates.addAll(
          StorySpeakerScheduler.tavernCandidates(_participants),
        );
        if (mounted) {
          HiDialog.showSnackBar(context, '不能跳过全部角色，已取消本轮跳过');
        }
      }
      if (mounted) setState(() {});
    }
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
    final remainingSlots = widget.room.replyMode == StoryReplyMode.autoMulti
        ? widget.room.maxAutoReplies - (forced == null ? 0 : 1)
        : 1;
    if (remainingSlots <= 0) return [if (forced != null) forced];
    final maxSpeakers = remainingSlots.clamp(1, 3);
    final locallyScheduled = StorySpeakerScheduler.schedule(
      room: widget.room,
      input: input,
      candidates: candidates,
      recentMessages: previousMessages,
      maxCount: maxSpeakers,
    );
    final mentioned = StorySpeakerScheduler.mentionedCandidates(
      input: input,
      candidates: candidates,
    );
    if (widget.room.speakerStrategy == StorySpeakerStrategy.roundRobin ||
        mentioned.isNotEmpty ||
        candidates.length <= 1) {
      return [if (forced != null) forced, ...locallyScheduled];
    }
    final fallback = StorySpeakerScheduler.fallbackSpeaker(
      candidates: locallyScheduled,
      selectedParticipantId: _selectedParticipantId,
    );
    final schedulerCandidates = StorySpeakerScheduler.smartCandidates(
      input: input,
      candidates: candidates,
      recentMessages: previousMessages,
      avoidRepeatSpeaker: widget.room.avoidRepeatSpeaker,
      maxCount: candidates.length,
    );
    try {
      final allowedIds = {for (final item in schedulerCandidates) item.id!};
      final prompt = StorySpeakerScheduler.promptFor(
        input,
        maxSpeakers: maxSpeakers,
        room: widget.room,
      );
      final history = [
        {
          'role': 'system',
          'content': StorySpeakerScheduler.systemPrompt(
            room: widget.room,
            candidates: schedulerCandidates,
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
        for (final item in schedulerCandidates) {
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
    String? candidateGroupKey,
    int? completionTokenLimit,
  }) async {
    final speakerSettings =
        StoryParticipantSettingsResolver.apply(settings, speaker);
    if (completionTokenLimit != null && completionTokenLimit > 0) {
      final configured = speakerSettings.maxOutputTokens;
      if (configured <= 0 || configured > completionTokenLimit) {
        speakerSettings.maxOutputTokens = completionTokenLimit;
      }
    }
    _lastGeneratedCompletionTokens = 0;
    final contextResult = await StoryContextBuilder.buildSystemPromptSafely(
      room: widget.room,
      participants: _participants,
      speaker: speaker,
      persona: _persona,
      latestInput: input,
      recentMessages: historyMessages,
    );
    if (!mounted || _stopRequested) return null;
    final history = contextResult.applyToHistory(
      StoryContextBuilder.history(
        historyMessages,
        room: widget.room,
        speaker: speaker,
        persona: _persona,
      ),
    );
    final message = StoryMessageModel(
      roomId: widget.room.id!,
      speakerId: speaker.id,
      speakerRole: speaker.role,
      speakerName: speaker.name,
      speakerAvatarType: speaker.avatarType,
      speakerAvatarValue: speaker.avatarValue,
      speakerVoiceStyle: speaker.voiceStyle,
      content: '',
      candidateGroupKey: candidateGroupKey,
    );
    if (mounted) {
      setState(() {
        _generationStatus = '${speaker.name} 正在发言...';
        _streamingMessageCreatedAt.add(message.createdAt);
        _messages = [..._messages, message];
        _allMessages = [..._allMessages, message];
      });
    }

    final buffer = StringBuffer();
    var promptTokens = 0;
    var cachedPromptTokens = 0;
    var completionTokens = 0;
    var hasUsage = false;
    final imageEvents = <StreamEvent>[];
    final citationUrls = <String>{};
    Object? streamError;
    final done = Completer<void>();
    final speakerPrompt = contextResult.inputPrompt.trim().isEmpty
        ? StoryContextBuilder.promptFor(input: input, speaker: speaker)
        : contextResult.inputPrompt;
    final stream = _toolRunner.run(
      speakerAssistantId: speaker.assistantId,
      settings: speakerSettings,
      prompt: speakerPrompt,
      history: history,
      attachments: attachmentBundle?.attachments,
      confirm: _confirmRoomToolAction,
      forceWebSearch: speakerSettings.webSearchEnabled &&
          speakerSettings.webSearchConfigured,
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
          return;
        }
        if (event.type == StreamEventType.image &&
            event.imageUrl?.trim().isNotEmpty == true) {
          imageEvents.add(event);
          if (mounted) setState(() => _generationStatus = '正在保存生成图片...');
          return;
        }
        if (event.type == StreamEventType.citation) {
          for (final result in event.webResults ?? const []) {
            final url = result.url.trim();
            if (url.isNotEmpty) citationUrls.add(url);
          }
          return;
        }
        if (event.type == StreamEventType.toolCall && mounted) {
          setState(() => _generationStatus =
              '${speaker.name} 正在使用 ${event.toolName ?? '工具'}...');
          return;
        }
        if (event.type == StreamEventType.toolResult && mounted) {
          setState(() => _generationStatus = '工具执行完成，继续生成...');
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
    for (var index = 0; index < imageEvents.length; index++) {
      try {
        final saved = await StoryRoomImageService.saveEvent(
          imageEvents[index],
          filename:
              'room_${widget.room.id}_${speaker.id ?? 0}_${message.createdAt}_$index.png',
        );
        saved?.attachTo(message);
      } catch (error) {
        if (mounted) {
          HiDialog.showSnackBar(context, '第 ${index + 1} 张生成图片保存失败：$error');
        }
      }
    }
    message.citationUrls = citationUrls.toList(growable: false);
    final providerText = buffer.toString().trim();
    if (providerText.isEmpty && message.imagePaths.isEmpty) {
      if (mounted) {
        setState(() {
          _messages = _messages
              .where((item) => item.createdAt != message.createdAt)
              .toList();
          _allMessages = _allMessages
              .where((item) => item.createdAt != message.createdAt)
              .toList();
        });
      }
      if (_stopRequested) return null;
      throw Exception('${speaker.name} 没有返回内容');
    }
    final outputRegex = await _runRegex(
      StoryRegexStage.assistantOutput,
      providerText,
    );
    _reportRegexIssues(outputRegex);
    final text = outputRegex.output.trim();
    message.content = text;
    final nextWorldBookState =
        jsonEncode(contextResult.worldBookState.toJson());
    message.contextStateAfter = nextWorldBookState;
    await dao.saveMessage(message);
    final displayContent = await _buildDisplayContent(
      [message],
      widget.room.regexScriptsJson,
    );
    if (mounted && displayContent.isNotEmpty) {
      setState(() => _displayContentByNodeKey = {
            ..._displayContentByNodeKey,
            ...displayContent,
          });
    }
    widget.room.activeMessageKey = message.nodeKey;
    if (widget.room.worldBookState != nextWorldBookState) {
      widget.room.worldBookState = nextWorldBookState;
      await dao.saveRoom(widget.room);
    }
    await _recordUsage(
      settings: speakerSettings,
      prompt: _usagePromptText(
        history,
        speakerPrompt,
      ),
      completion: providerText,
      promptTokens: hasUsage ? promptTokens : null,
      cachedPromptTokens: hasUsage ? cachedPromptTokens : null,
      completionTokens: hasUsage ? completionTokens : null,
      estimated: !hasUsage,
      createdAt: message.createdAt,
    );
    _lastGeneratedCompletionTokens = hasUsage && completionTokens > 0
        ? completionTokens
        : providerText.runes.length.clamp(1, 200000).toInt();
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

class _StoryBranchRow {
  final StoryMessageModel message;
  final int depth;
  final bool hasChildren;

  const _StoryBranchRow(this.message, this.depth, this.hasChildren);
}
