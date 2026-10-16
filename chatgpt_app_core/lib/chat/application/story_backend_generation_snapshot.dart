import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_usage_identity.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

/// 后端继承单层声明。follow忽略本层旧model，NULL legacy保留原文交R1。
AISettings storyBackendLayer(
    AISettings parent, BackendSelection? selection, String? legacyModel) {
  final next = parent.clone();
  if (parent.mode != AIMode.backend) return next;
  if (selection != null) {
    if (!selection.isFollow) next.backendSelection = selection;
  } else if (legacyModel?.trim().isNotEmpty == true) {
    next.backendSelection = null;
    next.backendModel = legacyModel!;
  }
  return next;
}

/// 构造时复制房间、角色与全局声明，固定原scope。继承者只用父实际pair。
/// 不持久化/重签旧消息或任务；旧消费者尚未接线时不能直接消费此新接口。
class StoryBackendGenerationSnapshot {
  final AiCatalogIdentity _identity = AiCatalogIdentity.capture();
  final int _restore = BackupService.restoreTick.value;
  final int _agentRevision = BackupService.agentExecutionRevision;
  late final AgentWorkflowScope _toolAccountScope;
  final bool Function() _current;
  final Completer<void> _abort = Completer<void>();
  final Map<String, _Entry> _entries = {};
  late final ChatService Function(AISettings) _factory;
  bool _retired = false;

  StoryBackendGenerationSnapshot({
    required AISettings global,
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required bool Function() isCurrent,
    ChatService Function(AISettings)? serviceFactory,
  }) : _current = isCurrent {
    if (global.mode != AIMode.backend) throw const FormatException('仅后端故事运行');
    _toolAccountScope =
        AgentWorkflowScope(accountHash: _identity.account ?? '');
    final roomCopy = StoryRoomModel.fromJson(room.toJson());
    final roomSettings =
        storyBackendLayer(global, roomCopy.backendSelection, roomCopy.modelId);
    roomSettings.webSearchEnabled =
        roomCopy.webSearchEnabled ?? global.webSearchEnabled;
    if (roomCopy.temperature != null) {
      roomSettings.temperature = roomCopy.temperature!;
    }
    if (roomCopy.topP != null) {
      roomSettings.topP = roomCopy.topP!.clamp(0, 1).toDouble();
    }
    if (roomCopy.maxOutputTokens != null) {
      roomSettings.maxOutputTokens =
          roomCopy.maxOutputTokens!.clamp(0, 200000).toInt();
    }
    final participantCopies = participants
        .map((p) => StoryParticipantModel.fromJson(p.toJson()))
        .toList();
    _factory = serviceFactory ?? ChatService.from;
    _entries['room'] =
        _Entry(roomSettings.clone(), _factory(roomSettings.clone()));
    for (final copy in participantCopies) {
      final key = participantKey(copy);
      if (_entries.containsKey(key)) throw const FormatException('角色快照身份重复');
      final settings =
          storyBackendLayer(roomSettings, copy.backendSelection, copy.modelId);
      if (copy.temperature != null) {
        settings.temperature = copy.temperature!.clamp(0, 2).toDouble();
      }
      if (copy.topP != null) settings.topP = copy.topP!.clamp(0, 1).toDouble();
      if (copy.maxOutputTokens != null) {
        settings.maxOutputTokens =
            copy.maxOutputTokens!.clamp(0, 200000).toInt();
      }
      final declared = copy.backendSelection;
      final own = declared != null
          ? !declared.isFollow
          : (copy.modelId?.trim().isNotEmpty ?? false);
      _entries[key] = _Entry(
          settings.clone(), own ? _factory(settings.clone()) : null,
          source: own ? null : 'room');
    }
    _verifyIdentity();
  }
  static String participantKey(StoryParticipantModel p) =>
      jsonEncode([p.roomId, p.id, p.participantKey]);
  void _verifyIdentity() {
    if (!_identity.current ||
        _restore != BackupService.restoreTick.value ||
        _agentRevision != BackupService.agentExecutionRevision ||
        _retired) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '故事生成环境已变化，请重新发起',
          failureKind: ChatFailureKind.cancelled);
    }
  }

  void verify() {
    _verifyIdentity();
    if (!_current()) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '故事生成已停止',
          failureKind: ChatFailureKind.cancelled);
    }
  }

  void retire() {
    _retired = true;
    _toolAccountScope.cancel();
    if (!_abort.isCompleted) _abort.complete();
  }

  Future<PreparedStoryBackendService> prepareRoom(
          {Future<void>? abortTrigger}) =>
      _prepare('room', abortTrigger: abortTrigger);
  Future<PreparedStoryBackendService> prepareParticipant(
          StoryParticipantModel p,
          {Future<void>? abortTrigger}) =>
      _prepare(participantKey(p), abortTrigger: abortTrigger);
  Future<PreparedStoryBackendService> _prepare(String key,
      {Future<void>? abortTrigger}) async {
    final cancelled = Completer<Object>();
    var waiterCancelled = false;
    void checkWaiter() {
      if (waiterCancelled) {
        throw const ChatTransportException(
            safeCode: 'cancelled',
            safeMessage: '故事准备已取消',
            failureKind: ChatFailureKind.cancelled);
      }
    }

    void cancel() {
      waiterCancelled = true;
      if (!cancelled.isCompleted) {
        cancelled.complete(const _CancelledPreparation());
      }
    }

    abortTrigger?.then<void>((_) => cancel(),
        onError: (Object _, StackTrace __) => cancel());
    // 已完成的abort先传播；不启动此等待者已取消的准备。
    await Future<void>.value();
    checkWaiter();
    verify();
    final entry = _entries[key];
    if (entry == null) {
      throw const ChatTransportException(
          safeCode: 'model_unavailable',
          safeMessage: '原角色模型快照已失效',
          failureKind: ChatFailureKind.invalidConfiguration);
    }
    final prepared = entry.preparing ??= _prepareOnce(entry);
    final value = await (abortTrigger == null
        ? prepared
        : Future.any<Object>([prepared, cancelled.future]));
    if (value is _CancelledPreparation) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '故事准备已取消',
          failureKind: ChatFailureKind.cancelled);
    }
    final result = value as PreparedStoryBackendService;
    // 缓存结果/取消同边界完成时，Future.any的赢家不代表仍有许可。
    await Future<void>.value();
    checkWaiter();
    verify();
    result.verify();
    return result;
  }

  Future<PreparedStoryBackendService> _prepareOnce(_Entry entry) async {
    verify();
    if (entry.source != null) {
      final parent = await _prepare(entry.source!);
      verify();
      entry.settings.backendSelection = parent.pair;
      // 继承R1实际结果；原身份仍相等时同步构造子transport，不重新model-only解析。
      entry.service = _factory(entry.settings.clone());
      verify();
    }
    final service = entry.service;
    if (service is! BackendSelectionPreparingChatService ||
        service is! OptionsAwareChatService ||
        service is! OptionsAwareNonStreamingChatService ||
        service is! AttemptAwareChatService) {
      throw const ChatTransportException(
          safeCode: 'model_unavailable',
          safeMessage: '后端故事发送需要完整模型选择支持',
          failureKind: ChatFailureKind.invalidConfiguration);
    }
    final pair = await (service as BackendSelectionPreparingChatService)
        .prepareBackendSelection(abortTrigger: _abort.future);
    verify();
    (service as BackendSelectionPreparingChatService)
        .verifyPreparedBackendSelection(pair);
    final settings = entry.settings.clone()..backendSelection = pair;
    return PreparedStoryBackendService._(this, service!, settings, pair);
  }
}

class _CancelledPreparation {
  const _CancelledPreparation();
}

class _Entry {
  final AISettings settings;
  ChatService? service;
  final String? source;
  Future<PreparedStoryBackendService>? preparing;
  _Entry(this.settings, this.service, {this.source});
}

/// 只暴露受原运行fence包装的transport；profile/capability/usage共用此pair。
class PreparedStoryBackendService
    implements
        ChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService,
        AttemptAwareChatService {
  final StoryBackendGenerationSnapshot _owner;
  final ChatService _service;
  final AISettings _settings;
  final BackendSelection pair;
  PreparedStoryBackendService._(
      this._owner, this._service, this._settings, this.pair);
  AISettings get settings => _settings.clone();
  String get usageProviderId => backendUsageProviderId(pair);

  /// 仅包装原运行许可，不能在工具等待后重新capture账号或模型。
  ToolExecutionScope tools(Future<HiDBManager> Function() openStorage) =>
      _StoryToolScope(this, openStorage);
  void verify() {
    _owner.verify();
    (_service as BackendSelectionPreparingChatService)
        .verifyPreparedBackendSelection(pair);
  }

  @override
  ModelCapabilities get capabilities {
    verify();
    return _service.capabilities;
  }

  ChatRequestOptions _options(ChatRequestOptions options) => ChatRequestOptions(
        profile: options.profile,
        reasoningPolicy: options.reasoningPolicy,
        deepSeekReasoningEffort: options.deepSeekReasoningEffort,
        abortTrigger: options.abortTrigger == null
            ? _owner._abort.future
            : Future.any([_owner._abort.future, options.abortTrigger!]),
        connectTimeout: options.connectTimeout,
        nonStreamingTimeout: options.nonStreamingTimeout,
        minOutputTokens: options.minOutputTokens,
        suppressReasoningControl: options.suppressReasoningControl,
        maxOutputTokensOverride: options.maxOutputTokensOverride,
        onProgress: options.onProgress,
        maxAutoRetries: options.maxAutoRetries,
        retryBaseDelay: options.retryBaseDelay,
        maxRetryDelay: options.maxRetryDelay,
        onRetry: options.onRetry,
        messagesForAttempt: options.messagesForAttempt,
        dispatchIsCurrent: () =>
            _isCurrent() && (options.dispatchIsCurrent?.call() ?? true),
        beforeAttachmentUpload: () async {
          verify();
          await options.beforeAttachmentUpload?.call();
          verify();
        },
        beforeDispatch: (messages) async {
          verify();
          await options.beforeDispatch?.call(messages);
          verify();
        },
      );
  bool _isCurrent() {
    try {
      verify();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> chat(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      Duration? timeout}) async {
    final pending = chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: ChatRequestOptions(
            nonStreamingTimeout: timeout ?? const Duration(minutes: 2)));
    final result = timeout == null
        ? await pending
        : await pending.timeout(timeout, onTimeout: () {
            _owner.retire();
            throw const ChatTransportException(
                safeCode: 'timeout',
                safeMessage: '故事请求超时，请核对生成状态',
                failureKind: ChatFailureKind.timeout);
          });
    return result.content;
  }

  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      chatWithUsageWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: const ChatRequestOptions());
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) {
    verify();
    return (_service as OptionsAwareNonStreamingChatService)
        .chatWithUsageWithOptions(
            prompt: prompt,
            history: history,
            attachments: attachments,
            options: _options(options));
  }

  @override
  Stream<String> chatStream(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      chatStreamEvents(
              prompt: prompt, history: history, attachments: attachments)
          .map((e) => e.delta);
  @override
  Stream<StreamEvent> chatStreamEvents(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const []}) =>
      chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages,
          options: const ChatRequestOptions());
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    verify();
    yield* (_service as OptionsAwareChatService).chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: _options(options));
  }
}

class _StoryToolScope extends ToolExecutionScope {
  final PreparedStoryBackendService prepared;
  final Future<HiDBManager> Function() openStorage;
  _StoryToolScope(this.prepared, this.openStorage);
  @override
  Future<void> get abortTrigger => prepared._owner._abort.future;
  @override
  void verify() {
    prepared.verify();
    prepared._owner._toolAccountScope.verify();
  }

  @override
  Future<void> beforeRequest() async {
    verify();
    await Future<void>.value();
    verify();
  }

  @override
  Future<T> commit<T>(Future<T> Function(Transaction tx) action) async {
    verify();
    final storage = await openStorage();
    verify();
    return prepared._owner._toolAccountScope.stable(() async {
      verify();
      return storage.db.transaction((tx) async {
        verify();
        final result = await action(tx);
        verify();
        return result;
      });
    });
  }
}
