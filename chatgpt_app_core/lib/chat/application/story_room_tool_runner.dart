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
  }) async* {
    final assistant = await _loadAssistant(speakerAssistantId);
    final chatService = _chatServiceFactory(settings);

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
          );
          return;
        }
      }
      yield* chatService.chatStreamEvents(
        prompt: prompt,
        history: history,
        attachments: attachments,
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
      yield* chatService.chatStreamEvents(
        prompt: prompt,
        history: history,
        attachments: attachments,
      );
      return;
    }

    final actions = ToolActionContext(
      openStorage: _openStorage,
      confirm: confirm,
      assistantId: assistant.id,
      projectId: projectId,
    );
    if (toolIds.contains(ToolRegistry.knowledgeSearchId)) {
      // 提前确保 RAG 表可用；实际检索仍由 BuiltinTools.knowledgeSearch 执行。
      await KnowledgeDao.create(await _openStorage());
    }

    final extraTools = await _discoverBoundMcpTools(
      settings,
      toolIds.toList(growable: false),
      confirm: confirm,
      projectId: projectId,
    );
    final registry = ToolRegistry.fromAssistant(
      settings,
      toolIds.toList(growable: false),
      forceWebSearch: forceWebSearch,
      actions: actions,
      extraTools: extraTools,
    );
    if (registry.isEmpty) {
      yield* chatService.chatStreamEvents(
        prompt: prompt,
        history: history,
        attachments: attachments,
      );
      return;
    }

    yield* ToolLoopRunner(chatService: chatService, registry: registry).run(
      prompt: prompt,
      history: history,
      attachments: attachments,
    );
  }

  Future<AssistantModel?> _loadAssistant(int? assistantId) async {
    if (assistantId == null) return null;
    final dao = await AssistantDao.create(await _openStorage());
    return dao.getAssistant(assistantId);
  }

  Future<List<ChatTool>> _discoverBoundMcpTools(
    AISettings settings,
    List<String> toolIds, {
    StoryRoomToolConfirm? confirm,
    int? projectId,
  }) async {
    final builtinIds = ToolRegistry.catalog.map((tool) => tool.id).toSet();
    if (!settings.mcpConfigured ||
        !toolIds.any((id) => !builtinIds.contains(id))) {
      return const [];
    }
    final all = await (_mcpDiscover?.call(
          settings,
          confirm: confirm,
          projectId: projectId,
        ) ??
        _discoverMcpTools(settings, confirm: confirm, projectId: projectId));
    final bound = toolIds.toSet();
    return all.where((tool) => bound.contains(tool.name)).toList();
  }

  Future<List<ChatTool>> _discoverMcpTools(
    AISettings settings, {
    StoryRoomToolConfirm? confirm,
    int? projectId,
  }) async {
    final auditDao = await ToolAuditDao.create(await _openStorage());
    return McpToolSource.discover(
      settings,
      confirm: confirm,
      auditDao: auditDao,
      currentProjectId: projectId,
    );
  }
}
