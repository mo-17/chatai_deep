import 'dart:async';
import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/search_orchestrator.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 一次非流式会话的产物：正文 + 联网引用来源（阶段五）。
class CompletionResult {
  final String? content;
  final List<WebSearchResult> webResults;
  final int? promptTokens;
  final int? cachedPromptTokens;
  final int? completionTokens;
  final bool estimated;
  final double cost;

  const CompletionResult({
    this.content,
    this.webResults = const [],
    this.promptTokens,
    this.cachedPromptTokens,
    this.completionTokens,
    this.estimated = false,
    this.cost = 0,
  });
}

class CompletionDao {
  final ChatService chatService;
  final AISettings _settings;
  final List<MessageModel> _messageList;

  /// 助手系统提示词（阶段七）。非空时插在 history 头部作为 system 消息；
  /// 注意调用方应传入「已应用模型覆盖」的 settings（见 AssistantModel.applyTo）。
  final String _systemPrompt;

  /// 历史里每条 assistant 消息（按 createdAt）当轮调用过的工具块（遗留项 2）。
  /// 用于 _buildHistory 跨轮重建「assistant(tool_calls) + role:tool」消息序列，
  /// 使工具调用对后续轮次可见（落库 history 不再只剩正文）。
  final Map<int, List<ToolBlock>> _toolHistory;

  /// 历史里每条 user 消息（按 createdAt）当轮附件的降级文本（遗留项 6）。
  /// 用于 _buildHistory 把附件文本拼回该 user 消息，使文件上下文跨轮可见
  /// （当前轮经 attachments.extraText 发送，后续轮从这里重建）。
  final Map<int, String> _fileHistory;

  /// 历史里每条 assistant 消息（按 createdAt）未完成回复的角色状态承接。
  /// 用于把“有思考但无正文”的短期状态带到下一轮，不进入长期记忆。
  final Map<int, String> _roleContinuationHistory;

  /// 显式启用新的请求预算，旧调用方与静态历史重建行为保持原样。
  final bool manageContext;
  final ChatContextPolicy contextPolicy;

  CompletionDao(
      {required AISettings settings,
      ChatService? chatService,
      List<MessageModel>? messages,
      String? systemPrompt,
      Map<int, List<ToolBlock>>? toolHistory,
      Map<int, String>? fileHistory,
      Map<int, String>? roleContinuationHistory,
      this.manageContext = false,
      this.contextPolicy = const ChatContextPolicy()})
      : chatService = chatService ?? ChatService.from(settings),
        _settings = settings,
        _systemPrompt = systemPrompt?.trim() ?? '',
        // 防御性拷贝成可增删的 growable 列表：调用方常把上一个 dao 的
        // `currentMessages`（List.unmodifiable）传进来重建，若直接持有该引用，
        // 后续 _messageList.add/removeLast 会抛 "Cannot add to an unmodifiable list"。
        _messageList = messages == null
            ? <MessageModel>[]
            : List<MessageModel>.of(messages),
        _toolHistory = {...?toolHistory},
        _fileHistory = {...?fileHistory},
        _roleContinuationHistory = {...?roleContinuationHistory} {
    AILogger.log('init finish, loaded ${_messageList.length} messages');
  }

  ///当前历史消息列表，供重建 CompletionDao 时传递
  List<MessageModel> get currentMessages => List.unmodifiable(_messageList);

  ///当前工具调用历史，供重建 CompletionDao 时一并传递（遗留项 2）。
  Map<int, List<ToolBlock>> get currentToolHistory =>
      Map.unmodifiable(_toolHistory);

  ///当前附件文本历史，供重建 CompletionDao 时一并传递（遗留项 6）。
  Map<int, String> get currentFileHistory => Map.unmodifiable(_fileHistory);

  /// 重新生成前恢复原提问的附件；必须在 dropLastTurn 清理文件历史前调用。
  ChatAttachments attachmentsForUserMessage(MessageModel message) =>
      ChatAttachments(
        images: message.imageUrlsOrB64 ?? const [],
        extraText: _fileHistory[message.createdAt] ?? '',
      );

  ///当前未完成回复状态承接，供重建 CompletionDao 时一并传递。
  Map<int, String> get currentRoleContinuationHistory =>
      Map.unmodifiable(_roleContinuationHistory);

  ///当前生效模型的能力探测结果（阶段三）。UI 据此开关图片/PDF/工具入口。
  ModelCapabilities get capabilities => chatService.capabilities;

  /// 预览本轮实际发送的历史副本，不写库，也不会改动 currentMessages。
  ChatContextPlan previewContext({
    required String prompt,
    ChatAttachments? attachments,
    ToolRegistry? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) =>
      _planContext(
        prompt: prompt,
        attachments: attachments,
        declarations: tools?.declarations ?? const [],
        extraMessages: extraMessages,
      );

  ChatContextPlan _planContext({
    required String prompt,
    ChatAttachments? attachments,
    List<Map<String, dynamic>> declarations = const [],
    List<Map<String, dynamic>> extraMessages = const [],
  }) =>
      const ChatContextPlanner().plan(
        history: _buildHistory(),
        systemPrompt: injectSystemPrompt(const [], _systemPrompt)
            .single['content'] as String,
        prompt: prompt,
        attachments: attachments,
        tools: declarations,
        extraMessages: extraMessages,
        policy: contextPolicy,
        maxOutputTokens: _settings.maxOutputTokens,
      );

  List<Map<String, dynamic>> _requestHistory({
    required String prompt,
    ChatAttachments? attachments,
    List<Map<String, dynamic>> declarations = const [],
    List<Map<String, dynamic>> extraMessages = const [],
    ChatContextPlanCallback? onContextPlan,
  }) {
    if (!manageContext) return _withSystem(_buildHistory());
    final plan = _planContext(
      prompt: prompt,
      attachments: attachments,
      declarations: declarations,
      extraMessages: extraMessages,
    );
    onContextPlan?.call(plan);
    if (!plan.canSend) throw ChatContextBudgetException(plan);
    return plan.history;
  }

  ///把已完成的一轮（用户 + assistant）追加进历史，使后续轮次携带完整上下文。
  ///应在请求已发出（_buildHistory 已读取）之后调用，避免与当前轮 prompt 重复。
  ///assistant 的 content 仅为主文本（不含思考），符合「正文用于历史上下文」。
  ///
  ///[assistantBlocks] 为该 assistant 消息收尾时的块列表（落库同一份）。其中的
  ///[ToolBlock] 会被记入 [_toolHistory]，供 _buildHistory 跨轮重建工具调用消息
  ///（遗留项 2：assistant(tool_calls)/role:tool 不再随当轮请求一起丢失）。
  ///[userFileText] 为该 user 消息附件的降级文本，记入 [_fileHistory] 供跨轮重建
  ///（遗留项 6：附件文本不再只活在当前轮 attachments 里）。
  void appendTurn(MessageModel user, MessageModel assistant,
      {List<MessageBlock>? assistantBlocks, String? userFileText}) {
    _messageList.add(user);
    _messageList.add(assistant);
    if (assistantBlocks != null) {
      final tools = assistantBlocks.whereType<ToolBlock>().toList();
      if (tools.isNotEmpty) _toolHistory[assistant.createdAt] = tools;
      final continuationText = assistantBlocks
          .whereType<RoleContinuationBlock>()
          .map((block) => block.content.trim())
          .where((content) => content.isNotEmpty)
          .join('\n');
      if (continuationText.isNotEmpty) {
        _roleContinuationHistory[assistant.createdAt] = continuationText;
      }
    }
    if (userFileText != null && userFileText.isNotEmpty) {
      _fileHistory[user.createdAt] = userFileText;
    }
  }

  ///回退最近一轮（user + assistant），用于「重新生成」：把该轮从历史里摘掉，
  ///使其用户消息可作为新 prompt 重发、不与历史重复。同时清掉该轮在工具/附件
  ///历史里的记录。仅当末尾确为「user 后接 assistant」时才回退，返回被移除的
  ///用户消息；否则不动并返回 null。
  MessageModel? dropLastTurn() {
    if (_messageList.length < 2) return null;
    final assistant = _messageList.last;
    final user = _messageList[_messageList.length - 2];
    if (assistant.ownerType != OwnerType.receiver ||
        user.ownerType != OwnerType.sender) {
      return null;
    }
    _messageList.removeLast();
    _messageList.removeLast();
    _toolHistory.remove(assistant.createdAt);
    _roleContinuationHistory.remove(assistant.createdAt);
    _fileHistory.remove(user.createdAt);
    return user;
  }

  ///和 AI 进行会话。[attachments] 为当前轮附件（阶段四：图片/文件）。
  Future<String?> createCompletions(
      {required String prompt, ChatAttachments? attachments}) async {
    final history = _requestHistory(prompt: prompt, attachments: attachments);
    final response = await chatService.chat(
        prompt: prompt, history: history, attachments: attachments);
    AILogger.log('ai response length: ${response?.length ?? 0}');
    return response;
  }

  ///非流式会话 + 可选联网搜索（阶段五）：返回正文与引用来源。
  Future<CompletionResult> createCompletionsWithSearch({
    required String prompt,
    ChatAttachments? attachments,
    bool webSearch = false,
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    ChatContextPlanCallback? onContextPlan,
  }) async {
    await _ensureNotAborted(abortTrigger);
    // 意图识别的轻量调用用「无 system」的 history —— 助手人设不该影响
    // 「要不要联网」的判断（阶段七）；正式会话才带 system。
    final history = manageContext
        ? _requestHistory(prompt: prompt, attachments: attachments)
            .where((message) => message['role'] != 'system')
            .toList()
        : _buildHistory();
    if (webSearch) onProgress?.call(const ChatSendProgress('联网搜索'));
    final results = webSearch
        ? await _awaitRequestStage(_runWebSearch(prompt, history), abortTrigger)
        : const <WebSearchResult>[];
    await _ensureNotAborted(abortTrigger);
    final preparedAttachments = _withSearchContext(attachments, results);
    final requestHistory = manageContext
        ? _requestHistory(
            prompt: prompt,
            attachments: preparedAttachments,
            onContextPlan: onContextPlan)
        : _withSystem(history);
    onProgress?.call(const ChatSendProgress('等待回答'));
    final responseFuture = abortTrigger == null && onProgress == null
        ? chatService.chatWithUsage(
            prompt: prompt,
            history: requestHistory,
            attachments: preparedAttachments,
          )
        : chatService.chatWithUsageWithOptions(
            prompt: prompt,
            history: requestHistory,
            attachments: preparedAttachments,
            options: ChatRequestOptions(
                abortTrigger: abortTrigger, onProgress: onProgress),
          );
    final response = await _awaitRequestStage(responseFuture, abortTrigger);
    await _ensureNotAborted(abortTrigger);
    AILogger.log('ai response length: ${response.content?.length ?? 0}');
    return CompletionResult(
      content: response.content,
      webResults: results,
      promptTokens: response.promptTokens,
      cachedPromptTokens: response.cachedPromptTokens,
      completionTokens: response.completionTokens,
      estimated: response.estimated,
      cost: response.cost,
    );
  }

  ///流式会话，逐 token yield（仅文本）
  Stream<String> streamCompletions(
      {required String prompt, ChatAttachments? attachments}) {
    final history = _requestHistory(prompt: prompt, attachments: attachments);
    return chatService.chatStream(
        prompt: prompt, history: history, attachments: attachments);
  }

  ///流式会话，逐「带类型」事件 yield（区分正文 / 推理），供块化分发使用。
  ///
  ///两条增强路径（互斥，由调用方按 caps.tool 选路，见 conversation_page）：
  ///- [tools] 非空（阶段六，模型支持工具调用）：走 ToolLoopRunner ——
  ///  模型自主决定是否调用（如联网搜索），调用→执行→回灌→续写；
  ///- [webSearch]（阶段五，模型不支持工具时的回落）：先意图编排，
  ///  要搜则把结果回填给主 LLM，正文流结束后补发 citation 事件。
  Stream<StreamEvent> streamCompletionEvents({
    required String prompt,
    ChatAttachments? attachments,
    bool webSearch = false,
    ToolRegistry? tools,
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    ChatContextPlanCallback? onContextPlan,
  }) async* {
    await _ensureNotAborted(abortTrigger);
    final history = manageContext
        ? _requestHistory(prompt: prompt, attachments: attachments)
            .where((message) => message['role'] != 'system')
            .toList()
        : _buildHistory();
    if (tools != null && !tools.isEmpty) {
      yield* ToolLoopRunner(chatService: chatService, registry: tools).run(
        prompt: prompt,
        history: manageContext
            ? _requestHistory(
                prompt: prompt,
                attachments: attachments,
                declarations: tools.declarations,
                onContextPlan: onContextPlan)
            : _withSystem(history),
        attachments: attachments,
        abortTrigger: abortTrigger,
        onProgress: onProgress,
        historyForRound: manageContext
            ? (extraMessages, declarations) => _requestHistory(
                  prompt: prompt,
                  attachments: attachments,
                  declarations: declarations ?? const [],
                  extraMessages: extraMessages,
                  onContextPlan: onContextPlan,
                )
            : null,
      );
      return;
    }
    // 意图识别用无 system 的 history（同 createCompletionsWithSearch）。
    if (webSearch) onProgress?.call(const ChatSendProgress('联网搜索'));
    final results = webSearch
        ? await _awaitRequestStage(_runWebSearch(prompt, history), abortTrigger)
        : const <WebSearchResult>[];
    await _ensureNotAborted(abortTrigger);
    final preparedAttachments = _withSearchContext(attachments, results);
    final requestHistory = manageContext
        ? _requestHistory(
            prompt: prompt,
            attachments: preparedAttachments,
            onContextPlan: onContextPlan)
        : _withSystem(history);
    onProgress?.call(const ChatSendProgress('等待回答'));
    if (abortTrigger == null && onProgress == null) {
      yield* chatService.chatStreamEvents(
        prompt: prompt,
        history: requestHistory,
        attachments: preparedAttachments,
      );
    } else {
      yield* chatService.chatStreamEventsWithOptions(
        prompt: prompt,
        history: requestHistory,
        attachments: preparedAttachments,
        options: ChatRequestOptions(
            abortTrigger: abortTrigger, onProgress: onProgress),
      );
    }
    if (results.isNotEmpty) yield StreamEvent.citation(results);
  }

  static Future<void> _ensureNotAborted(Future<void>? abortTrigger) async {
    if (abortTrigger == null) return;
    var cancelled = false;
    unawaited(abortTrigger.then<void>((_) => cancelled = true,
        onError: (Object _, StackTrace __) => cancelled = true));
    await Future<void>.value();
    if (cancelled) {
      throw const ChatTransportException(
          safeCode: 'cancelled', safeMessage: '请求已取消');
    }
  }

  static Future<T> _awaitRequestStage<T>(
      Future<T> pending, Future<void>? abortTrigger) {
    if (abortTrigger == null) return pending;
    Never cancelled() => throw const ChatTransportException(
        safeCode: 'cancelled', safeMessage: '请求已取消');
    return Future.any([
      pending,
      abortTrigger.then<T>((_) => cancelled(),
          onError: (Object _, StackTrace __) => cancelled()),
    ]);
  }

  ///联网搜索编排：意图识别 → 并行搜索聚合。任何失败都降级为「不搜」，
  ///绝不阻塞正式会话。未配置搜索 key 时直接返回空。
  Future<List<WebSearchResult>> _runWebSearch(
      String prompt, List<Map<String, dynamic>> history) async {
    final provider = WebSearchProvider.fromSettings(_settings);
    if (provider == null) return const [];
    try {
      final orchestrator =
          SearchOrchestrator(chatService: chatService, provider: provider);
      final results = await orchestrator.run(prompt: prompt, history: history);
      AILogger.log('web search got ${results.length} results');
      return results;
    } catch (e) {
      AILogger.log('web search failed, continue without it: $e');
      return const [];
    }
  }

  ///把搜索结果上下文拼进附件的 extraText（与文件降级文本同一通路）。
  ChatAttachments? _withSearchContext(
      ChatAttachments? attachments, List<WebSearchResult> results) {
    if (results.isEmpty) return attachments;
    return (attachments ?? const ChatAttachments())
        .withExtraText(SearchOrchestrator.buildSearchContext(results));
  }

  ///把助手系统提示词 + 当前日期应用到 history（始终至少注入日期 system）。
  List<Map<String, dynamic>> _withSystem(List<Map<String, dynamic>> history) =>
      injectSystemPrompt(history, _systemPrompt);

  /// 始终注入的「当前日期」系统提示。让主 LLM 理解「今天/最近/最新」等时间词，
  /// 不至于退回训练截止日期——普通对话也生效，不依赖联网搜索回填。
  static String dateSystemPrompt() =>
      '当前日期：${SearchOrchestrator.today()}（用户本地时区）。回答涉及「今天」「最近」「最新」等时间概念时以此为准。';

  /// 阶段七：把 [systemPrompt] 作为 system 消息插在 [history] 头部，
  /// 并始终在最前面附上当前日期（见 [dateSystemPrompt]）。助手提示词为空时
  /// 仅注入日期。静态纯函数，便于单测。
  static List<Map<String, dynamic>> injectSystemPrompt(
      List<Map<String, dynamic>> history, String? systemPrompt) {
    final p = systemPrompt?.trim() ?? '';
    final content =
        p.isEmpty ? dateSystemPrompt() : '${dateSystemPrompt()}\n\n$p';
    return [
      {'role': 'system', 'content': content},
      ...history,
    ];
  }

  List<Map<String, dynamic>> _buildHistory() => buildHistory(
        _messageList,
        _toolHistory,
        fileHistory: _fileHistory,
        roleContinuationHistory: _roleContinuationHistory,
      );

  /// 把消息列表 + 各 assistant 的工具块 + 各 user 的附件文本重建成 OpenAI
  /// `messages[]`。
  ///
  /// - 遗留项 2：assistant 若在该轮调用过工具，则在其正文消息之前插入
  ///   「assistant(tool_calls) + role:tool 结果」配对（见 [toolCallMessages]）；
  /// - 遗留项 6：user 若在该轮带过附件降级文本，则拼回其 content
  ///   （格式与当前轮 [ChatAttachments.buildUserContent] 完全一致：`正文\n\n文本`）。
  /// 静态纯函数，便于单测。
  static List<Map<String, dynamic>> buildHistory(
    List<MessageModel> messages,
    Map<int, List<ToolBlock>> toolHistory, {
    Map<int, String> fileHistory = const {},
    Map<int, String> roleContinuationHistory = const {},
  }) {
    final history = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.ownerType == OwnerType.sender) {
        final fileText = fileHistory[m.createdAt] ?? '';
        final hasImages =
            m.imageUrlsOrB64 != null && m.imageUrlsOrB64!.isNotEmpty;
        history.add({
          'role': 'user',
          'content': hasImages
              ? _visionContent(m, fileText)
              : _appendText(m.content, fileText),
        });
      } else {
        final tools = toolHistory[m.createdAt];
        if (tools != null && tools.isNotEmpty) {
          history.addAll(toolCallMessages(tools));
        }
        final continuation = roleContinuationHistory[m.createdAt]?.trim() ?? '';
        if (continuation.isNotEmpty) {
          history.add({
            'role': 'assistant',
            'content': roleContinuationPrompt(continuation),
          });
        } else {
          history.add({'role': 'assistant', 'content': m.content});
        }
      }
    }
    return history;
  }

  static String roleContinuationPrompt(String content) {
    final text = content.trim();
    if (text.isEmpty) return '';
    return '【上一轮未完成回复状态，仅供续写，不是角色已经说出口的内容】\n'
        '$text\n'
        '下一次回应时请承接这个状态，不要把场景重置，也不要直接复述本段说明。';
  }

  /// 把一条 assistant 消息里的工具块还原成 OpenAI 协议消息序列：每个工具调用 →
  /// `assistant(tool_calls=[该调用])` + `role:tool(结果)`。一调用一配对（不按轮
  /// 分组），逐对满足「tool 消息须紧跟声明了该 tool_call_id 的 assistant」。
  /// 块列表里穿插的正文已并入该 assistant 消息的 content，故此处只取工具调用。
  /// 静态纯函数，便于单测。
  static List<Map<String, dynamic>> toolCallMessages(List<ToolBlock> blocks) {
    final out = <Map<String, dynamic>>[];
    for (final b in blocks) {
      if (b.toolId.isEmpty) continue; // 无 id 无法配对，跳过
      out.add({
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': b.toolId,
            'type': 'function',
            'function': {
              'name': b.toolName ?? '',
              'arguments': jsonEncode(b.arguments ?? const <String, dynamic>{}),
            },
          },
        ],
      });
      out.add({
        'role': 'tool',
        'tool_call_id': b.toolId,
        'content': _toolResultContent(b.content),
      });
    }
    return out;
  }

  /// 工具返回值转成 role:tool 的字符串 content（String 直传，其它 JSON 编码）。
  static String _toolResultContent(Object? content) {
    if (content == null) return '';
    if (content is String) return content;
    try {
      return jsonEncode(content);
    } catch (_) {
      return content.toString();
    }
  }

  ///构造多模态 vision content 数组（[fileText] 非空时拼进文本 part，遗留项 6）。
  static List<Map<String, dynamic>> _visionContent(
      MessageModel m, String fileText) {
    final parts = <Map<String, dynamic>>[];
    final text = _appendText(m.content, fileText);
    if (text.isNotEmpty) {
      parts.add({'type': 'text', 'text': text});
    }
    for (final img in m.imageUrlsOrB64!) {
      parts.add({
        'type': 'image_url',
        'image_url': {'url': img},
      });
    }
    return parts;
  }

  /// 把附件文本拼到正文后（与 [ChatAttachments.buildUserContent] 同款 `\n\n` 分隔）。
  static String _appendText(String content, String extra) {
    if (extra.isEmpty) return content;
    return content.isEmpty ? extra : '$content\n\n$extra';
  }
}
