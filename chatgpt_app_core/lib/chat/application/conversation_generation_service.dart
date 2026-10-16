import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'dart:async';
import 'package:chatgpt_app_core/chat/application/role_continuation_snapshot.dart';
import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';

/// 页面只提交值快照；准备对象由应用服务持有，不接收 State/Context/controller。
class ConversationGenerationInput {
  final int cid;
  final int? conversationRowId;
  final Map<String, Object?>? newConversation;
  final int? assistantId, existingUserRowId, projectId, retryReplyRowId;
  final String? retryReplyHash;
  final String? existingSourceId, existingSourceRowHash, systemPrompt;
  final String? receiverName, receiverAvatar;
  final MessageModel user;
  final List<MessageModel> history;
  final bool stream, webSearch, roleContinuationEnabled;
  final Map<int, List<Map<String, dynamic>>> protocolHistory;
  final Map<int, String> fileHistory, roleContinuationHistory;
  final Map<int, List<ToolBlock>> toolHistory;
  ConversationGenerationInput({
    required this.cid,
    required this.conversationRowId,
    ConversationModel? newConversation,
    required MessageModel user,
    this.assistantId,
    this.existingUserRowId,
    this.existingSourceId,
    this.existingSourceRowHash,
    this.retryReplyRowId,
    this.retryReplyHash,
    this.projectId,
    this.systemPrompt,
    this.receiverName,
    this.receiverAvatar,
    this.stream = true,
    this.webSearch = false,
    this.roleContinuationEnabled = false,
    List<MessageModel> history = const [],
    Map<int, List<Map<String, dynamic>>> protocolHistory = const {},
    Map<int, String> fileHistory = const {},
    Map<int, String> roleContinuationHistory = const {},
    Map<int, List<ToolBlock>> toolHistory = const {},
  })  : newConversation = newConversation == null
            ? null
            : Map.unmodifiable(newConversation.toJson()),
        user = MessageModel.fromJson(user.toJson()),
        history = List.unmodifiable(
            history.map((m) => MessageModel.fromJson(m.toJson()))),
        protocolHistory = Map.unmodifiable(protocolHistory.map((key, value) =>
            MapEntry(
                key,
                (jsonDecode(jsonEncode(value)) as List)
                    .cast<Map<String, dynamic>>()))),
        fileHistory = Map.unmodifiable(fileHistory),
        roleContinuationHistory = Map.unmodifiable(roleContinuationHistory),
        toolHistory = Map.unmodifiable(toolHistory.map((key, value) =>
            MapEntry(key, List<ToolBlock>.unmodifiable(value))));
}

class PreparedConversationTurn {
  final String prompt;
  final String? systemPrompt;
  final ChatAttachments attachments;
  final List<MessageBlock> userBlocks;
  final ToolRegistry? tools;
  PreparedConversationTurn(
      {required this.prompt,
      this.systemPrompt,
      ChatAttachments attachments = const ChatAttachments(),
      List<MessageBlock> userBlocks = const [],
      this.tools})
      : attachments = ChatAttachments(
            images: List.unmodifiable(attachments.images),
            nativeFiles: List.unmodifiable(attachments.nativeFiles),
            extraText: attachments.extraText),
        userBlocks = List.unmodifiable(userBlocks);
}

abstract class ConversationTurnPreparation {
  Future<PreparedConversationTurn> prepare(ConversationGenerationRun run);

  /// 释放本次持有的引用快照；不能清除页面后来编辑的新草稿。
  Future<void> release();
}

abstract interface class ConfigurationAwareConversationPreparation {
  Future<void> verifyToolConfiguration();
}

abstract interface class UnacceptedConversationPreparation {
  Future<void> preserveUnacceptedDraft(
      ConversationGenerationRun run, ConversationGenerationScope writeScope);
}

abstract interface class SubmittedDraftOwnership {
  Future<bool> ownsSubmission(DraftSubmissionToken token);
}

abstract interface class AcceptedConversationPreparation {
  /// 真实事务已提交后同步转交资源，不等待页面或网络。
  void userAccepted();
  Future<void> clearAcceptedDraft(ConversationGenerationRun run);
}

class ReadyConversationTurn implements ConversationTurnPreparation {
  final PreparedConversationTurn turn;
  ReadyConversationTurn(this.turn);
  @override
  Future<PreparedConversationTurn> prepare(
          ConversationGenerationRun run) async =>
      turn;
  @override
  Future<void> release() async {}
}

class GenerationConfirmation {
  final String id, title, detail;
  const GenerationConfirmation(this.id, this.title, this.detail);
}

/// 一个运行一个 block store/请求/协议/确认等待；两个订阅者不会重复消费或落盘。
class ConversationGenerationRun extends ChangeNotifier {
  final String runId = generateUuidV4(), receiverId = generateUuidV4();
  final ConversationGenerationScope scope;
  final ConversationGenerationDao dao;
  final ConversationGenerationProfile profile;
  final ConversationGenerationInput input;
  final ConversationTurnPreparation preparation;
  final ConversationGenerationService service;
  final ChatService? transport;
  late final ChatService _chat;
  final ChatBlockStore blocks = ChatBlockStore();
  final _abort = Completer<void>(), _finished = Completer<void>();
  late final ConversationExecutionTicket ticket;
  late final int receiverAt;
  late final StreamDispatcher dispatcher;
  ConversationGenerationRecord? record;
  ConversationGenerationStage stage = ConversationGenerationStage.preparing;
  String progress = '准备发送', notice = '';
  CompletionDao? completion;
  ChatContextPlan? contextPlan;
  Object? preparationFailure;
  ChatTransportException? transportFailure;
  bool _preparationFailureObserved = false;
  Object? takePreparationFailure() {
    if (_preparationFailureObserved || preparationFailure == null) return null;
    _preparationFailureObserved = true;
    return preparationFailure;
  }

  bool _inputConsumed = false;
  bool get inputConsumed => _inputConsumed;
  Future<bool> ownsDraftSubmission(DraftSubmissionToken token) async {
    if (!scope.identityCurrent ||
        retired ||
        preparation is! SubmittedDraftOwnership) {
      return false;
    }
    try {
      return await scope.wait(
          (preparation as SubmittedDraftOwnership).ownsSubmission(token),
          abortTrigger);
    } catch (_) {
      return false;
    }
  }

  MessageModel? acceptedUser;
  Map<String, Object?>? acceptedSourceRow;
  List<MessageBlock> acceptedUserBlocks = const [];
  String _acceptedFileText = '';
  bool _historyCommitted = false;
  GenerationConfirmation? confirmation;
  Completer<bool>? _confirmation;
  Object? _visibleHost;
  StreamSubscription<StreamEvent>? _subscription;
  Completer<void>? _streamDone;
  Future<void> _writes = Future.value();
  Future<void> _settlements = Future.value();
  Future<void>? _stop;
  Timer? _checkpoint;
  bool _cancelled = false, _hasUsage = false, _externalStop = false;
  bool _retired = false, _retiring = false;
  // 已确认来源/CAS 失效不能因源行后来恢复而重新获得写回复的许可。
  bool _closeOnly = false;
  PersonalMemoryDao? _personal;
  PersonalMemoryTurn? _memoryTurn;
  bool _candidateHandled = false;
  ConversationGenerationScope? _finalWriteScope;
  final _RetiredGeneration? _abandoned;
  bool _hasPromptUsage = false, _hasCompletionUsage = false;
  int _promptTokens = 0, _cachedTokens = 0, _completionTokens = 0;
  UsageRecord? _finalUsage;
  ConversationGenerationStage? _finalStage;
  String? _finalBlocks, _finalText;
  ConversationGenerationRun._(this.service, this.scope, this.dao, this.profile,
      this.input, this.preparation, this._abandoned, this.transport) {
    // 构造时固定 transport 的原身份；任何异步准备后都不重新捕获。
    _chat = transport ?? service.createChat(profile.settings);
    receiverAt = service.nextMessageTime(input.user.createdAt);
    dispatcher = StreamDispatcher(blocks, chatMessageKey(receiverAt),
        modelId: profile.modelId);
  }
  bool get retired => _retired || _retiring;
  bool get executionStopped => _cancelled || _finished.isCompleted;
  bool get persistencePending =>
      stage == ConversationGenerationStage.persistenceFailed;
  bool get busy =>
      !_retired &&
      !const {
        ConversationGenerationStage.complete,
        ConversationGenerationStage.interrupted,
        ConversationGenerationStage.failed
      }.contains(stage);
  bool get current =>
      !_cancelled && scope.isCurrent && service.registry.owns(ticket);

  /// 对外结算包括外部停止的最后一次短写入；内部停止不能等待自己。
  Future<void> get finished async {
    await _finished.future;
    final stopping = _stop;
    if (stopping != null) await stopping;
  }

  Future<void> get abortTrigger => _abort.future;
  List<MessageBlock> get replyBlocks => List.unmodifiable(_blocks());
  MessageModel get receiver => MessageModel(
      ownerType: OwnerType.receiver,
      ownerName: input.receiverName,
      avatar: input.receiverAvatar,
      content: dispatcher.mainText,
      createdAt: receiverAt);
  void verify() {
    scope.verify();
    if (!current) {
      throw const ConversationGenerationStale();
    }
  }

  Future<T> _write<T>(Future<T> Function() action) {
    final future = _writes.then((_) => action());
    _writes = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  Future<void> _settle(Future<void> Function() action) {
    final future = _settlements.then((_) => action());
    _settlements =
        future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  Future<void> guard() async {
    verify();
    await scope.wait(profile.verify(scope), abortTrigger);
    verify();
    if (record != null) {
      // 空更新也核 source/CAS，工具/上传前不预留模型尝试。
      await _write(() async {
        verify();
        record = await dao.stage(scope, record!, stage);
        verify();
      });
    }
  }

  Future<T> commitTool<T>(Future<T> Function(Transaction tx) action) =>
      _write(() async {
        verify();
        if (record == null) throw const ConversationGenerationStale();
        return dao.commitTool(scope, record!, action);
      });

  Future<void> _dispatch(List<Map<String, dynamic>> _) async {
    await guard();
    await _write(() async {
      verify();
      record = await dao.reserveAttempt(scope, record!);
      verify();
    });
  }

  ChatRequestOptions get requestOptions => ChatRequestOptions(
      abortTrigger: abortTrigger,
      beforeDispatch: _dispatch,
      beforeAttachmentUpload: guard,
      dispatchIsCurrent: () => current && profile.visiblyCurrent,
      onProgress: (value) {
        if (current) {
          progress = value.label;
          notifyListeners();
        }
      });

  /// 绑定可见主机只发身份，不保存页面闭包；离页不等于停止。
  void attachVisibleHost(Object host) {
    if (current && !identical(_visibleHost, host)) {
      _visibleHost = host;
      notifyListeners();
    }
  }

  void detachVisibleHost(Object host) {
    if (identical(_visibleHost, host)) {
      _visibleHost = null;
    }
  }

  Future<bool> confirm(String title, String detail) async {
    await guard();
    if (_confirmation != null) {
      throw StateError('已有待确认操作');
    }
    final waiting = Completer<bool>();
    _confirmation = waiting;
    confirmation = GenerationConfirmation(generateUuidV4(), title, detail);
    stage = ConversationGenerationStage.awaitingConfirmation;
    await _write(() async {
      verify();
      record = await dao.stage(scope, record!, stage);
    });
    notifyListeners();
    try {
      final answer = await scope.wait(waiting.future, abortTrigger);
      await guard();
      return answer;
    } finally {
      if (identical(_confirmation, waiting)) {
        _confirmation = null;
        confirmation = null;
      }
      if (current) {
        stage = ConversationGenerationStage.generating;
        notifyListeners();
      }
    }
  }

  Future<bool> answerConfirmation(
      {required Object host,
      required String confirmationId,
      required bool accepted}) async {
    if (!current ||
        !identical(_visibleHost, host) ||
        confirmation?.id != confirmationId) {
      return false;
    }
    await guard();
    if (!current ||
        !identical(_visibleHost, host) ||
        confirmation?.id != confirmationId) {
      return false;
    }
    if (_confirmation?.isCompleted == false) {
      _confirmation!.complete(accepted);
    }
    return true;
  }

  Future<void> _execute() async {
    try {
      await scope.wait(
          profile.prepareSelection(_chat, scope, abortTrigger), abortTrigger);
      verify();
      await scope.wait(profile.verify(scope), abortTrigger);
      verify();
      record = await _write(() => dao.begin(scope,
          runId: runId,
          cid: input.cid,
          conversationRowId: input.conversationRowId,
          newConversation: input.newConversation,
          assistantId: input.assistantId,
          sourceId: input.existingSourceId ?? generateUuidV4(),
          sourceHash: generationContentHash(input.user.content),
          receiverId: receiverId,
          receiverAt: receiverAt,
          existingUserRowId: input.existingUserRowId,
          existingSourceRowHash: input.existingSourceRowHash,
          retryReplyRowId: input.retryReplyRowId,
          retryReplyHash: input.retryReplyHash,
          abandonedRun: _abandoned?.record));
      service._forgetRetirement(_abandoned);
      service.summaryChanged();
      verify();
      final memory = await scope.wait(service.createMemory(this), abortTrigger);
      verify();
      if (input.existingUserRowId == null &&
          memory != null &&
          input.assistantId == null) {
        _personal = memory.personal;
        _memoryTurn = await scope.wait(
            _personal!.beginTurn(
                cid: input.cid,
                assistantId: null,
                taskMode: false,
                rawInput: input.user.content,
                startedAt: service.startedAt(runId)),
            abortTrigger);
        verify();
      }
      final turn = await scope.wait(preparation.prepare(this), abortTrigger);
      await guard();
      final preparedUser = MessageModel(
          ownerType: input.user.ownerType,
          ownerName: input.user.ownerName,
          avatar: input.user.avatar,
          content: input.user.content,
          createdAt: input.user.createdAt,
          imageUrlsOrB64: turn.attachments.images.isEmpty
              ? input.user.imageUrlsOrB64
              : turn.attachments.images);
      final accepted = preparation is AcceptedConversationPreparation
          ? preparation as AcceptedConversationPreparation
          : null;
      record = await _write(() => dao.acceptUser(scope, record!, preparedUser,
          blocksJson: MessageBlock.encodeList(turn.userBlocks),
          onCommitted: () {
            _inputConsumed = true;
            accepted?.userAccepted();
          },
          onSourceCommitted: (row) => acceptedSourceRow = row));
      acceptedUser = acceptedSourceRow == null
          ? preparedUser
          : MessageModel.fromJson(acceptedSourceRow!);
      service.summaryChanged();
      acceptedUserBlocks = turn.userBlocks;
      _acceptedFileText = turn.attachments.extraText;
      notifyListeners();
      if (accepted != null) {
        try {
          await scope.wait(accepted.clearAcceptedDraft(this), abortTrigger);
        } catch (_) {
          if (current) notice = '消息已保存，原草稿清理失败；新的草稿未改动';
        }
      }
      verify();
      final chat = _chat;
      if (chat is! AttemptAwareChatService ||
          chat is! OptionsAwareChatService ||
          chat is! OptionsAwareNonStreamingChatService) {
        throw StateError('聊天传输不支持运行身份校验');
      }
      completion = CompletionDao(
          messages: input.history,
          settings: profile.settings,
          systemPrompt: turn.systemPrompt ?? input.systemPrompt,
          toolHistory: input.toolHistory,
          roleContinuationHistory: input.roleContinuationHistory,
          protocolHistory: input.protocolHistory,
          fileHistory: input.fileHistory,
          memoryContextResolver: memory?.resolve,
          manageContext: true,
          conversationId: input.cid,
          chatService: chat);
      stage = ConversationGenerationStage.generating;
      dispatcher.start();
      notifyListeners();
      if (input.stream) {
        final done = Completer<void>();
        _streamDone = done;
        Object? error;
        StackTrace? stack;
        _subscription = completion!
            .streamCompletionEvents(
                prompt: turn.prompt,
                attachments: turn.attachments,
                webSearch: input.webSearch,
                tools: turn.tools,
                requestOptions: requestOptions,
                beforeToolAction: guard,
                onContextPlan: (plan) => contextPlan = plan)
            .listen((event) {
          if (!current) {
            return;
          }
          _event(event);
          _scheduleCheckpoint();
          notifyListeners();
        }, onError: (Object e, StackTrace s) {
          error = e;
          stack = s;
          if (!done.isCompleted) {
            done.complete();
          }
        }, onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        });
        await scope.wait(done.future, abortTrigger);
        if (error != null) {
          Error.throwWithStackTrace(error!, stack!);
        }
      } else {
        final result = await scope.wait(
            completion!.createCompletionsWithSearch(
                prompt: turn.prompt,
                attachments: turn.attachments,
                webSearch: input.webSearch,
                requestOptions: requestOptions,
                onContextPlan: (plan) => contextPlan = plan),
            abortTrigger);
        verify();
        dispatcher.onTextChunk(result.content ?? 'no response');
        if (result.webResults.isNotEmpty) {
          dispatcher.onCitation(result.webResults);
        }
        _promptTokens = result.promptTokens ?? 0;
        _cachedTokens = result.cachedPromptTokens ?? 0;
        _completionTokens = result.completionTokens ?? 0;
        _hasPromptUsage = result.promptTokens != null;
        _hasCompletionUsage = result.completionTokens != null;
        _hasUsage =
            result.promptTokens != null || result.completionTokens != null;
      }
      verify();
      dispatcher.finish();
      _finalStage = ConversationGenerationStage.complete;
      await _persistFinal();
    } catch (error) {
      transportFailure = error is ChatTransportException ? error : null;
      if (acceptedUser == null) preparationFailure = error;
      if (error is ConversationRetirementStale) {
        service._forgetRetirement(_abandoned);
      }
      if (_finalStage == null) {
        _finalStage = _cancelled || error is ConversationGenerationStale
            ? ConversationGenerationStage.interrupted
            : ConversationGenerationStage.failed;
        notice = _cancelled
            ? notice
            : error is ConversationGenerationStale
                ? error.reason
                : error is ChatTransportException
                    ? error.safeMessage
                    : '请求未完成，可查看错误后明确重试';
        if (_finalStage == ConversationGenerationStage.interrupted) {
          dispatcher.onStopped();
        } else {
          dispatcher.onError(notice);
        }
        if (!_externalStop) {
          await _persistFinal();
        }
      }
    } finally {
      _checkpoint?.cancel();
      _checkpoint = null;
      final sub = _subscription;
      _subscription = null;
      if (sub != null) {
        unawaited(sub.cancel().catchError((Object _) {}));
      }
      // 普通同身份停止可保留未接受输入；维护撤销不补签新身份写权。
      if (!_inputConsumed &&
          !_retiring &&
          scope.identityCurrent &&
          preparation is UnacceptedConversationPreparation) {
        final control = scope.finalWriteScope();
        _finalWriteScope = control;
        // 未接受输入回存是有界收尾；超时撤销未取得的许可，已取得的短操作仍结算。
        final deadline = Timer(const Duration(seconds: 2), control.cancel);
        try {
          await (preparation as UnacceptedConversationPreparation)
              .preserveUnacceptedDraft(this, control);
        } catch (_) {
          if (!_retiring && scope.identityCurrent) {
            notice = '未接受的输入无法回存，原草稿及新草稿未改动';
          }
        } finally {
          deadline.cancel();
          if (identical(_finalWriteScope, control)) _finalWriteScope = null;
        }
      }
      try {
        await preparation.release();
      } catch (_) {
        notice = '本次附件快照释放未完成';
      }
      if (!_externalStop &&
          stage != ConversationGenerationStage.persistenceFailed) {
        service.registry.release(ticket);
      }
      if (!_finished.isCompleted) {
        _finished.complete();
      }
      notifyListeners();
      service.runChanged();
    }
  }

  void _event(StreamEvent event) {
    switch (event.type) {
      case StreamEventType.text:
        dispatcher.onTextChunk(event.delta);
      case StreamEventType.reasoning:
        dispatcher.onThinkingChunk(event.delta);
      case StreamEventType.toolCall:
        dispatcher.onToolCall(
            toolId: event.toolId ?? '',
            name: event.toolName,
            args: event.toolArguments);
      case StreamEventType.toolResult:
        dispatcher.onToolResult(
            toolId: event.toolId ?? '', content: event.toolContent);
      case StreamEventType.image:
        if (event.imageUrl != null) {
          dispatcher.onImage(event.imageUrl!);
        }
      case StreamEventType.citation:
        dispatcher.onCitation(event.webResults ?? [],
            localSources: event.localSources ?? []);
      case StreamEventType.usage:
        _hasUsage = true;
        _hasPromptUsage = _hasPromptUsage || event.promptTokens != null;
        _hasCompletionUsage =
            _hasCompletionUsage || event.completionTokens != null;
        _promptTokens += event.promptTokens ?? 0;
        _cachedTokens += event.cachedPromptTokens ?? 0;
        _completionTokens += event.completionTokens ?? 0;
    }
  }

  List<MessageBlock> _blocks() {
    final result = blocks.blocksFor(chatMessageKey(receiverAt)).toList();
    final protocol =
        completion?.lastProtocolMessages ?? const <Map<String, dynamic>>[];
    if (protocol.isNotEmpty &&
        _finalStage == ConversationGenerationStage.complete) {
      final index = result.lastIndexWhere((b) => b is MainTextBlock);
      if (index >= 0) {
        result[index] = (result[index] as MainTextBlock)
            .copyWith(protocolMessages: protocol);
      }
    }
    return _finalStage == null
        ? result
        : withRoleContinuationSnapshot(result,
            assistantBound: input.roleContinuationEnabled,
            receiverCreatedAt: receiverAt,
            messageKey: chatMessageKey(receiverAt),
            modelId: profile.modelId,
            mainText: dispatcher.mainText,
            hasError: dispatcher.hasError);
  }

  void _scheduleCheckpoint() {
    _checkpoint ??= Timer(const Duration(milliseconds: 400), () {
      _checkpoint = null;
      unawaited(_write(() async {
        if (!current || _finalStage != null || record == null) {
          return;
        }
        try {
          record = await dao.saveReply(scope, record!,
              content: dispatcher.mainText,
              blocksJson: MessageBlock.encodeList(_blocks()),
              ownerName: input.receiverName,
              avatar: input.receiverAvatar,
              state: ConversationGenerationStage.generating);
        } catch (_) {
          if (current) {
            notice = '生成仍在继续，进度保存失败；收尾将再次保存';
          }
        }
      }));
    });
  }

  Future<void> _persistFinal() async {
    _checkpoint?.cancel();
    _checkpoint = null;
    _finalText ??= dispatcher.mainText;
    _finalBlocks ??= MessageBlock.encodeList(_blocks());
    if (_hasUsage || (record?.attempts ?? 0) > 0) {
      final rate = profile.settings.usageCostConfig.rateFor(
          providerId: profile.usageProviderId,
          modelId: profile.modelId,
          at: DateTime.fromMillisecondsSinceEpoch(receiverAt));
      final estimate = UsageCostEstimator.estimateTurn(
          modelId: profile.modelId,
          prompt: input.user.content,
          completion: _finalText!,
          at: DateTime.fromMillisecondsSinceEpoch(receiverAt));
      final prompt = _hasPromptUsage ? _promptTokens : estimate.promptTokens;
      final output =
          _hasCompletionUsage ? _completionTokens : estimate.completionTokens;
      _finalUsage ??= UsageRecord(
          modelId: profile.modelId,
          providerId: profile.usageProviderId,
          projectId: input.projectId,
          cid: input.cid,
          promptTokens: prompt,
          cachedPromptTokens: _cachedTokens.clamp(0, prompt),
          completionTokens: output,
          estimated: !_hasPromptUsage || !_hasCompletionUsage,
          cost: rate.costFor(
              promptTokens: prompt,
              cachedPromptTokens: _cachedTokens.clamp(0, prompt),
              completionTokens: output),
          createdAt: receiverAt);
    }
    if (record == null) {
      stage = ConversationGenerationStage.interrupted;
      return;
    }
    if (_retiring || !scope.identityCurrent) {
      stage = ConversationGenerationStage.persistenceFailed;
      notice = '原执行身份已失效，未保存结果不能写回；只可由维护清理原记录';
      return;
    }
    final writeScope = scope.finalWriteScope();
    _finalWriteScope = writeScope;
    try {
      stage = ConversationGenerationStage.persisting;
      if (_closeOnly) {
        await _closeInvalidatedSource(writeScope);
        return;
      }
      if (notice == '回复尚未保存，点击重试保存；不会重新请求模型') notice = '';
      record = await _write(() => dao.saveReply(writeScope, record!,
          content: _finalText!,
          blocksJson: _finalBlocks!,
          state: _finalStage!,
          ownerName: input.receiverName,
          avatar: input.receiverAvatar,
          reason: notice,
          usage: _finalUsage));
      stage = _finalStage!;
      service.summaryChanged();
      if (!_historyCommitted && acceptedUser != null && completion != null) {
        _historyCommitted = true;
        completion!.appendTurn(acceptedUser!, receiver,
            assistantBlocks: MessageBlock.decodeList(_finalBlocks!),
            userFileText: _acceptedFileText);
      }
      await _suggestAfterFirstSave(writeScope);
    } on ConversationGenerationStale {
      stage = ConversationGenerationStage.interrupted;
      notice = '原消息或会话已变化，结果未写入新会话';
      if (!_retiring && scope.identityCurrent && writeScope.isCurrent) {
        _closeOnly = true;
        await _closeInvalidatedSource(writeScope);
      }
    } catch (_) {
      stage = ConversationGenerationStage.persistenceFailed;
      notice = '回复尚未保存，点击重试保存；不会重新请求模型';
    } finally {
      if (identical(_finalWriteScope, writeScope)) _finalWriteScope = null;
    }
  }

  Future<void> _suggestAfterFirstSave(
      ConversationGenerationScope writeScope) async {
    if (_candidateHandled ||
        _closeOnly ||
        _retiring ||
        !scope.identityCurrent ||
        stage != ConversationGenerationStage.complete ||
        _memoryTurn == null ||
        _personal == null) {
      return;
    }
    _candidateHandled = true;
    try {
      // 原新轮次 token 保留至首次成功保存；重接和旧消息重试不会创建 token。
      await _personal!.suggestAfterPersist(_memoryTurn!,
          userCreatedAt: input.user.createdAt,
          replyCreatedAt: receiverAt,
          stableMutation: (action) => writeScope.stable(action),
          validateSource: (tx) async {
            writeScope.verify();
            if (_retiring || _retired) {
              throw const ConversationGenerationStale();
            }
            await dao.validateSavedSource(tx, writeScope, record!);
            writeScope.verify();
          });
    } catch (_) {
      if (scope.identityCurrent) notice = '回复已保存，个人记忆建议保存失败';
    }
  }

  Future<void> _closeInvalidatedSource(
      ConversationGenerationScope writeScope) async {
    try {
      record = await _write(() => dao.invalidate(writeScope, record!));
      stage = ConversationGenerationStage.interrupted;
      notice = '原消息或会话已变化，结果未写入新会话';
    } catch (_) {
      stage = ConversationGenerationStage.persistenceFailed;
      notice = '原来源已变化，终止记录尚未保存；重试只关闭原记录';
    }
  }

  Future<void> retryPersistence() => _settle(() async {
        if (stage != ConversationGenerationStage.persistenceFailed ||
            _retired ||
            !scope.identityCurrent) {
          return;
        }
        await _persistFinal();
        if (stage != ConversationGenerationStage.persistenceFailed) {
          service.registry.release(ticket);
        }
        notifyListeners();
        service.runChanged();
      });

  Future<void> stop(String reason) => _stop ??= _stopNow(reason);
  Future<void> _stopNow(String reason) async {
    if (!busy && _finished.isCompleted) {
      return;
    }
    // 终态消息已保存不等于收尾已结算（可能仍有未接受草稿/候选的短写入）。
    notice = reason;
    _externalStop = true;
    _cancelled = true;
    scope.cancel();
    if (!_abort.isCompleted) {
      _abort.complete();
    }
    if (_confirmation?.isCompleted == false) {
      _confirmation!.complete(false);
    }
    if (_streamDone?.isCompleted == false) {
      _streamDone!.complete();
    }
    await _writes;
    await _finished.future;
    await _settle(() async {
      if (record?.terminal != true && !_retired) {
        if (_finalStage == null) {
          _finalStage = ConversationGenerationStage.interrupted;
          dispatcher.onStopped();
        }
        // 停止的短写入在调用方许可内执行；不能让 logoutReady 等待外部 zone
        // 中重新排队的账号许可，避免外层等待内层的死锁。
        await _persistFinal();
      }
      if (!persistencePending) service.registry.release(ticket);
    });
    notifyListeners();
    service.runChanged();
  }

  /// 维护明确撤销执行所有权；失败 journal 只由后续当前身份定点清理，不能补写旧答复。
  Future<void> retire(String reason) async {
    _retiring = true;
    scope.cancel();
    _finalWriteScope?.cancel();
    await stop(reason);
    await _settle(() async {
      if (_retired) return;
      if (record != null && !record!.terminal && scope.identityCurrent) {
        final control = scope.finalWriteScope();
        _finalWriteScope = control;
        try {
          stage = ConversationGenerationStage.persisting;
          record = await dao.invalidate(control, record!);
          stage = ConversationGenerationStage.interrupted;
        } catch (_) {
          stage = ConversationGenerationStage.persistenceFailed;
          notice = '执行已撤销，结果未保存；后续明确发送需先清理原生成记录';
        } finally {
          if (identical(_finalWriteScope, control)) _finalWriteScope = null;
        }
      }
      _retired = true;
      if (record != null && !record!.terminal) {
        service._rememberRetirement(this);
      }
      service.registry.release(ticket);
    });
    notifyListeners();
    service.runChanged();
  }
}

class _RetiredGeneration {
  final String account;
  final Object storage;
  final ConversationGenerationRecord record;
  _RetiredGeneration(ConversationGenerationRun run)
      : account = run.scope.account,
        storage = run.dao.storage.db,
        record = run.record!;
}

/// 应用级注册表不依赖路由，普通运行没有系统后台许可，后台安全中断。
class ConversationGenerationService extends ChangeNotifier
    with WidgetsBindingObserver {
  static final instance = ConversationGenerationService();
  final ConversationExecutionRegistry registry;
  final ChatService Function(AISettings) createChat;
  final Future<ConversationMemoryContext?> Function(ConversationGenerationRun)
      createMemory;
  final _runs = <String, ConversationGenerationRun>{};
  final _retirements = <String, _RetiredGeneration>{};
  final _started = <String, DateTime>{};
  int _messageTime = 0;
  int summaryRevision = 0;
  // 仅在真实 SQL 接受/最终保存时更新，正文 token 不触发列表全表读取。
  void summaryChanged() {
    summaryRevision++;
    notifyListeners();
  }

  final _initializedStorage = <Object>{};
  AISettingsProvider? _settingsProvider;
  bool _observing = false, _disposed = false;
  ConversationGenerationService({
    ConversationExecutionRegistry? registry,
    ChatService Function(AISettings)? createChat,
    Future<ConversationMemoryContext?> Function(ConversationGenerationRun)?
        createMemory,
    bool observeApplication = true,
  })  : registry = registry ?? ConversationExecutionRegistry.instance,
        createChat = createChat ?? ChatService.from,
        createMemory = createMemory ?? _memory {
    ModelCatalog.executionChanges.addListener(_configChanged);
    BackendConfig.changes.addListener(_configChanged);
    if (observeApplication) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      LoginDao.addLoginReadyHook(_identityChanged);
      LoginDao.addLogoutReadyHook(_identityChanged);
    }
  }
  static Future<ConversationMemoryContext?> _memory(
      ConversationGenerationRun run) async {
    return run.scope.stable(() async {
      final personal = await PersonalMemoryDao.create(run.dao.storage,
          accountHash: run.scope.account);
      final assistant = await AssistantMemoryDao.create(run.dao.storage);
      return ConversationMemoryContext(
          storage: run.dao.storage,
          accountHash: run.scope.account,
          cid: run.input.cid,
          assistantId: run.input.assistantId,
          taskMode: false,
          personal: personal,
          assistant: assistant);
    });
  }

  int nextMessageTime(int userAt) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _messageTime =
        [_messageTime + 1, userAt + 1, now].reduce((a, b) => a > b ? a : b);
    return _messageTime;
  }

  int startedAt(String id) => _started[id]!.millisecondsSinceEpoch;
  Iterable<ConversationGenerationRun> get runs =>
      List.unmodifiable(_runs.values);
  ConversationGenerationRun? lookup(String account, int cid) =>
      _runs[ConversationExecutionRegistry.key(account, cid)];
  Future<void> initializeStorage(
      ConversationGenerationScope scope, ConversationGenerationDao dao) async {
    if (_initializedStorage.contains(dao.storage.db)) return;
    // 仅冷启首次连接库时收口派生 journal；不能在每次发送或页面重接时中断活跃运行。
    if (_runs.values
        .any((r) => r.busy && identical(r.dao.storage.db, dao.storage.db))) {
      _initializedStorage.add(dao.storage.db);
      return;
    }
    await dao.recoverInterrupted(scope);
    scope.verify();
    _initializedStorage.add(dao.storage.db);
  }

  ConversationGenerationRun start(
      {required ConversationGenerationScope scope,
      required ConversationGenerationDao dao,
      required ConversationGenerationProfile profile,
      required ConversationGenerationInput input,
      required ConversationTurnPreparation preparation,
      ChatService? transport}) {
    scope.verify();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      throw StateError('请回到前台后发送');
    }
    final key = ConversationExecutionRegistry.key(scope.account, input.cid);
    final retired = _retirements[key];
    final abandoned = retired != null &&
            retired.account == scope.account &&
            identical(retired.storage, dao.storage.db)
        ? retired
        : null;
    if (retired != null && abandoned == null) {
      _forgetRetirement(retired);
    }
    final run = ConversationGenerationRun._(
        this, scope, dao, profile, input, preparation, abandoned, transport);
    run.ticket = registry.claim(
        account: scope.account,
        cid: input.cid,
        owner: run,
        kind: ConversationExecutionKind.ordinary,
        storageKey: dao.storage.db,
        stop: run.stop,
        retire: run.retire);
    final previous = _runs[key];
    if (previous != null) _started.remove(previous.runId);
    _runs[key] = run;
    _started[run.runId] = DateTime.now();
    _bindSettings();
    notifyListeners();
    unawaited(run._execute());
    return run;
  }

  void _rememberRetirement(ConversationGenerationRun run) {
    _retirements[ConversationExecutionRegistry.key(
        run.scope.account, run.input.cid)] = _RetiredGeneration(run);
  }

  void _forgetRetirement(_RetiredGeneration? retired) {
    if (retired == null) return;
    final key =
        ConversationExecutionRegistry.key(retired.account, retired.record.cid);
    if (identical(_retirements[key], retired)) _retirements.remove(key);
  }

  void runChanged() {
    // 只保留有限终态供当次页面重接；历史正文的来源仍是 SQLite。
    final terminal = _runs.entries.where((e) => !e.value.busy).toList();
    while (terminal.length > 8) {
      final oldest = terminal.removeAt(0);
      _runs.remove(oldest.key);
      _started.remove(oldest.value.runId);
    }
    notifyListeners();
  }

  void _bindSettings() {
    final provider = AISettingsProvider.instance;
    if (identical(provider, _settingsProvider)) {
      return;
    }
    _settingsProvider?.executionChanges.removeListener(_configChanged);
    _settingsProvider = provider;
    provider?.executionChanges.addListener(_configChanged);
  }

  void _configChanged() {
    if (_disposed) return;
    for (final run in _runs.values.where((r) => r.busy).toList()) {
      if (!run.scope.identityCurrent || !run.profile.visiblyCurrent) {
        unawaited(run.stop('原账号或模型配置已撤销，请重新选择后发送'));
      } else if (run.preparation is ConfigurationAwareConversationPreparation) {
        unawaited(_checkToolConfiguration(run));
      }
    }
  }

  Future<void> _checkToolConfiguration(ConversationGenerationRun run) async {
    try {
      await (run.preparation as ConfigurationAwareConversationPreparation)
          .verifyToolConfiguration();
    } catch (_) {
      if (run.current) await run.stop('原工具配置或凭据已撤销');
    }
  }

  Future<void> _identityChanged() async {
    if (_disposed) return;
    await Future.wait(_runs.values
        .where((r) => r.busy)
        .toList()
        .map((r) => r.retire('登录身份已变化，旧请求已停止')));
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _settingsProvider?.executionChanges.removeListener(_configChanged);
    ModelCatalog.executionChanges.removeListener(_configChanged);
    BackendConfig.changes.removeListener(_configChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(Future.wait(_runs.values
          .where((r) => r.busy)
          .toList()
          .map((r) => r.stop('应用进入后台，普通聊天已中断；返回后可明确重试'))));
    }
  }
}
