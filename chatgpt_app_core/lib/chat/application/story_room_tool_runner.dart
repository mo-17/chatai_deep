import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_execution_session.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/application/story_backend_generation_snapshot.dart';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

/// 需要用户确认的本地写操作或非信任 MCP 调用。
typedef StoryRoomToolConfirm = Future<bool> Function(
    String title, String detail);

/// 允许测试或特殊宿主替换 MCP 发现，不把网络细节泄漏到房间页面。
typedef StoryRoomMcpDiscover = Future<List<ChatTool>> Function(
  AISettings settings, {
  StoryRoomToolConfirm? confirm,
  int? projectId,
});

/// 多角色房间中单个发言者的工具执行编排。
///
/// 角色绑定的助手是唯一权限来源：只有该助手的 [AssistantModel.useTools]
/// 与 [AssistantModel.toolIds] 同时允许时，才会暴露内置、知识库和 MCP 工具。
/// 未绑定/已删除助手时不发现工具，直接转发普通 [ChatService] 事件流。
class StoryRoomToolRunner {
  final Future<HiDBManager> Function() _openStorage;
  final ChatService Function(AISettings settings) _chatServiceFactory;
  final StoryRoomMcpDiscover? _mcpDiscover;

  StoryRoomToolRunner({
    Future<HiDBManager> Function()? openStorage,
    ChatService Function(AISettings settings)? chatServiceFactory,
    StoryRoomMcpDiscover? mcpDiscover,
  })  : _openStorage = openStorage ??
            (() => HiDBManager.instance(dbName: HiDBManager.getAccountHash())),
        _chatServiceFactory = chatServiceFactory ?? ChatService.from,
        _mcpDiscover = mcpDiscover;

  /// 用 [speakerAssistantId] 解析当前发言角色绑定的助手并运行一轮流式回复。
  Stream<StreamEvent> run({
    required int? speakerAssistantId,
    required AISettings settings,
    required List<Map<String, dynamic>> history,
    required String prompt,
    ChatAttachments? attachments,
    StoryRoomToolConfirm? confirm,
    int? projectId,
    bool forceWebSearch = false,
    ChatRequestOptions? requestOptions,
  }) =>
      _run(
          speakerAssistantId: speakerAssistantId,
          settings: settings,
          history: history,
          prompt: prompt,
          attachments: attachments,
          confirm: confirm,
          projectId: projectId,
          forceWebSearch: forceWebSearch,
          requestOptions: requestOptions);

  /// 已准备的后端运行不再重建transport，也不重新读取全局选择。
  Stream<StreamEvent> runPrepared({
    required PreparedStoryBackendService prepared,
    int? maxOutputTokensOverride,
    required int? speakerAssistantId,
    required List<Map<String, dynamic>> history,
    required String prompt,
    ChatAttachments? attachments,
    StoryRoomToolConfirm? confirm,
    int? projectId,
    bool forceWebSearch = false,
  }) =>
      _run(
          speakerAssistantId: speakerAssistantId,
          settings: prepared.settings,
          history: history,
          prompt: prompt,
          attachments: attachments,
          confirm: confirm,
          projectId: projectId,
          forceWebSearch: forceWebSearch,
          prepared: prepared,
          requestOptions: ChatRequestOptions(
              maxOutputTokensOverride: maxOutputTokensOverride));

  Stream<StreamEvent> _run({
    required int? speakerAssistantId,
    required AISettings settings,
    required List<Map<String, dynamic>> history,
    required String prompt,
    ChatAttachments? attachments,
    StoryRoomToolConfirm? confirm,
    int? projectId,
    bool forceWebSearch = false,
    PreparedStoryBackendService? prepared,
    ChatRequestOptions? requestOptions,
  }) async* {
    final localScope =
        prepared == null && requestOptions?.dispatchIsCurrent != null
            ? _DirectStoryToolScope(_openStorage, requestOptions!)
            : null;
    void verifyOperation() {
      prepared?.verify();
      localScope?.verify();
    }

    verifyOperation();
    final scope = prepared?.tools(_openStorage) ?? localScope;
    // 所有工具复用本运行原身份；发现/确认返回后也不能重新捕获。
    final session = scope == null
        ? null
        : McpExecutionSession(
            scope: scope,
            backendBase: prepared != null
                ? Uri.parse(prepared.pair.origin!).replace(path: '/uapi/mcp/')
                : localScope!.identity.endpoint.replace(path: '/uapi/mcp/'),
            backendHeaders: {
                'Authorization': 'Bearer ${LoginDao.getBoardingPass() ?? ''}'
              });
    try {
      final assistant =
          await _loadAssistant(speakerAssistantId, verifyOperation);
      verifyOperation();
      final chatService = prepared ?? _chatServiceFactory(settings);

      // 房间联网是用户显式开启的房间级能力。未绑定助手时只允许
      // web_search，不会借此开放 MCP、写操作或知识库。
      if (assistant == null) {
        final canSearch = forceWebSearch &&
            settings.webSearchConfigured &&
            settings.streamEnabled &&
            chatService.capabilities.tool;
        if (canSearch) {
          final registry = ToolRegistry.fromAssistant(
            settings,
            const [ToolRegistry.webSearchId],
            forceWebSearch: true,
          );
          if (!registry.isEmpty) {
            yield* ToolLoopRunner(chatService: chatService, registry: registry)
                .run(
              prompt: prompt,
              history: history,
              attachments: attachments,
              requestOptions: requestOptions,
              beforeToolAction: scope?.beforeRequest,
            );
            return;
          }
        }
        yield* chatService.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: requestOptions ?? const ChatRequestOptions(),
        );
        return;
      }

      final toolIds = <String>{...?assistant.toolIds};
      if (forceWebSearch) toolIds.add(ToolRegistry.webSearchId);
      final canRunTools = assistant.useTools &&
          settings.streamEnabled &&
          chatService.capabilities.tool &&
          toolIds.isNotEmpty;
      if (!canRunTools) {
        yield* chatService.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: requestOptions ?? const ChatRequestOptions(),
        );
        return;
      }

      final actions = ToolActionContext(
        executionScope: scope,
        openStorage: () async {
          verifyOperation();
          final storage = await _openStorage();
          verifyOperation();
          return storage;
        },
        confirm: confirm == null
            ? null
            : (title, detail) async {
                verifyOperation();
                final result = await confirm(title, detail);
                verifyOperation();
                return result;
              },
        assistantId: assistant.id,
        projectId: projectId,
      );
      if (toolIds.contains(ToolRegistry.knowledgeSearchId)) {
        // 提前确保 RAG 表可用；实际检索仍由 BuiltinTools.knowledgeSearch 执行。
        verifyOperation();
        final storage = await _openStorage();
        verifyOperation();
        await KnowledgeDao.create(storage);
        verifyOperation();
      }

      final extraTools = await _discoverBoundMcpTools(
        settings,
        toolIds.toList(growable: false),
        confirm: actions.confirm,
        projectId: projectId,
        session: session,
      );
      verifyOperation();
      final registry = ToolRegistry.fromAssistant(
        settings,
        toolIds.toList(growable: false),
        forceWebSearch: forceWebSearch,
        actions: actions,
        extraTools: extraTools,
      );
      if (registry.isEmpty) {
        yield* chatService.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: requestOptions ?? const ChatRequestOptions(),
        );
        return;
      }

      yield* ToolLoopRunner(chatService: chatService, registry: registry).run(
        prompt: prompt,
        history: history,
        attachments: attachments,
        requestOptions: requestOptions,
        beforeToolAction: scope?.beforeRequest,
      );
    } finally {
      session?.close();
    }
  }

  Future<AssistantModel?> _loadAssistant(
      int? assistantId, void Function() verify) async {
    if (assistantId == null) return null;
    verify();
    final storage = await _openStorage();
    verify();
    final dao = await AssistantDao.create(storage);
    verify();
    final assistant = await dao.getAssistant(assistantId);
    verify();
    return assistant;
  }

  Future<List<ChatTool>> _discoverBoundMcpTools(
    AISettings settings,
    List<String> toolIds, {
    StoryRoomToolConfirm? confirm,
    int? projectId,
    McpExecutionSession? session,
  }) async {
    final builtinIds = ToolRegistry.catalog.map((tool) => tool.id).toSet();
    if (!settings.mcpConfigured ||
        !toolIds.any((id) => !builtinIds.contains(id))) {
      return const [];
    }
    final all = session != null
        ? await _discoverMcpTools(settings,
            confirm: confirm, projectId: projectId, session: session)
        : await (_mcpDiscover?.call(
              settings,
              confirm: confirm,
              projectId: projectId,
            ) ??
            _discoverMcpTools(settings,
                confirm: confirm, projectId: projectId));
    final bound = toolIds.toSet();
    return all.where((tool) => bound.contains(tool.name)).toList();
  }

  Future<List<ChatTool>> _discoverMcpTools(
    AISettings settings, {
    StoryRoomToolConfirm? confirm,
    int? projectId,
    McpExecutionSession? session,
  }) async {
    session?.scope.verify();
    final storage = await _openStorage();
    session?.scope.verify();
    final auditDao = await ToolAuditDao.create(storage);
    session?.scope.verify();
    return McpToolSource.discover(
      settings,
      confirm: confirm,
      auditDao: auditDao,
      currentProjectId: projectId,
      session: session,
    );
  }
}

/// 本地故事工具在 POST 以后仍沿原账号和本次确认；短写事务最后再次复核。
class _DirectStoryToolScope extends ToolExecutionScope {
  final Future<HiDBManager> Function() openStorage;
  final ChatRequestOptions options;
  final AiCatalogIdentity identity = AiCatalogIdentity.capture();
  late final ConversationGenerationScope accountScope =
      ConversationGenerationScope(account: identity.account ?? 'guest');
  _DirectStoryToolScope(this.openStorage, this.options);
  @override
  Future<void> get abortTrigger => accountScope.whenCancelled;
  @override
  void verify() {
    accountScope.verify();
    if (!identity.current || options.dispatchIsCurrent?.call() == false) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '原故事请求已失效',
          failureKind: ChatFailureKind.cancelled);
    }
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
    return accountScope.stable(() => storage.db.transaction((tx) async {
          verify();
          final result = await action(tx);
          verify();
          return result;
        }));
  }
}
