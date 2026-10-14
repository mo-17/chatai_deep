import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_execution_session.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/skill_script_dao.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/skill/js_runtime_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:sqflite/sqflite.dart';

/// 在运行内部装配，只保存工具选择值和本次 run；不携带页面确认闭包。
final class ConversationRunTools extends ToolExecutionScope {
  final List<String>? toolIds;
  final bool useTools, forceWebSearch;
  final http.Client Function()? mcpClientFactory;
  ConversationGenerationRun? _run;
  McpExecutionSession? _session;
  String? _configuration;
  bool _released = false, _enabled = false;
  AISettings? _checkedSettings;
  int? _authorizationRevision;
  ConversationRunTools(
      {List<String>? toolIds,
      this.useTools = true,
      this.forceWebSearch = false,
      this.mcpClientFactory})
      : toolIds = toolIds == null ? null : List.unmodifiable(toolIds);

  ConversationGenerationRun get run => _run ?? (throw StateError('工具尚未绑定运行'));
  @override
  Future<void> get abortTrigger => run.abortTrigger;
  @override
  void verify() {
    if (_released) throw const ConversationGenerationStale('本次工具运行已结束');
    run.verify();
  }

  static String _settingsKey(AISettings settings) => jsonEncode({
        'servers': settings.mcpServers.map((s) => s.toJson()).toList(),
        'backend': settings.mcpBackendEnabled,
        'trusted': settings.mcpBackendTrusted,
        'search': settings.webSearchProviderId,
        'searchKey': settings.activeSearchApiKey,
      });

  Future<void> verifyConfiguration() async {
    if (_run == null || _released || !_enabled) return;
    verify();
    _verifySettingsNow();
    final current = await wait(run.profile.loadSettings());
    verify();
    if (_settingsKey(current) != _configuration ||
        (_session != null &&
            BackendConfig.buildUri('/uapi/mcp/').toString() !=
                _session!.backendBase.toString())) {
      throw const ConversationGenerationStale('本次工具配置或凭据已变化');
    }
    _checkedSettings = current;
    _verifySettingsNow();
    final conversations = await wait(run.dao.storage.db.query(
        'tb_conversation_list',
        where: 'cid=?',
        whereArgs: [run.input.cid]));
    verify();
    if (conversations.length != 1) throw const ConversationGenerationStale();
    final conversation = ConversationModel.fromJson(conversations.single);
    AssistantModel? assistant;
    if (run.input.assistantId != null) {
      assistant = await wait((await AssistantDao.create(run.dao.storage))
          .getAssistant(run.input.assistantId!));
      verify();
      if (assistant == null || !assistant.useTools) {
        throw const ConversationGenerationStale('原助手的工具授权已撤销');
      }
    }
    final ids = conversation.toolIds ?? assistant?.toolIds;
    if (jsonEncode(ids) != jsonEncode(toolIds)) {
      throw const ConversationGenerationStale('原会话的工具选择已变化');
    }
  }

  @override
  Future<void> beforeRequest() async {
    verify();
    await run.guard();
    await verifyConfiguration();
    // 配置读取也可能异步挂起，最终请求前再次核对原消息/附件。
    await run.guard();
    // 原消息与实际工具授权在同一短事务核对；不持账号许可等待 HTTP。
    await run.commitTool((tx) async {
      await _verifyDatabaseAuthorization(tx);
      _verifySettingsNow();
    });
    _verifySettingsNow();
    verify();
  }

  void _verifySettingsNow() {
    verify();
    final visible = run.profile.visibleSettings() ??
        _checkedSettings ??
        run.profile.settings;
    if (_settingsKey(visible) != _configuration ||
        AISettingsDao.executionRevisionFor(run.scope.account) !=
            _authorizationRevision ||
        !AISettingsDao.executionConfigurationMatches(
            run.scope.account, run.profile.settings) ||
        (_session != null &&
            BackendConfig.buildUri('/uapi/mcp/').toString() !=
                _session!.backendBase.toString())) {
      throw const ConversationGenerationStale('工具配置或凭据已撤销，本次操作未发送');
    }
  }

  @override
  void verifyRequest() => _verifySettingsNow();

  @override
  Future<T> commit<T>(Future<T> Function(Transaction tx) action) async {
    await beforeRequest();
    return run.commitTool((tx) async {
      verify();
      await _verifyDatabaseAuthorization(tx);
      _verifySettingsNow();
      final result = await action(tx);
      _verifySettingsNow();
      return result;
    });
  }

  Future<void> _verifyDatabaseAuthorization(Transaction tx) async {
    final rows = await tx.query('tb_conversation_list',
        where: 'cid=?', whereArgs: [run.input.cid]);
    if (rows.length != 1) throw const ConversationGenerationStale();
    final conversation = ConversationModel.fromJson(rows.single);
    List<String>? currentIds = conversation.toolIds;
    if (run.input.assistantId != null) {
      final assistants = await tx.query('tb_assistant',
          where: 'id=?', whereArgs: [run.input.assistantId]);
      if (assistants.length != 1) throw const ConversationGenerationStale();
      final assistant = AssistantModel.fromJson(assistants.single);
      if (!assistant.useTools) {
        throw const ConversationGenerationStale('助手工具已停用');
      }
      currentIds ??= assistant.toolIds;
    }
    if (jsonEncode(currentIds) != jsonEncode(toolIds)) {
      throw const ConversationGenerationStale('工具选择已变化');
    }
    verify();
  }

  Future<ToolRegistry?> create(ConversationGenerationRun value) async {
    if (_run != null && !identical(_run, value)) throw StateError('工具已绑定另一运行');
    _run = value;
    final settings = run.profile.settings;
    AISettingsDao.bindExecutionConfiguration(run.scope.account, settings);
    // 许可身份只捕获一次。设置待写/失败后的旧缓存不能认领新的失效代次。
    _authorizationRevision ??=
        AISettingsDao.executionRevisionFor(run.scope.account);
    _configuration ??= _settingsKey(settings);
    verify();
    if (!useTools ||
        !run.input.stream ||
        !ChatService.capabilitiesFor(settings).tool) {
      return null;
    }
    _enabled = true;
    await beforeRequest();
    // 懒建表也是短账号操作；网络发现、用户确认不在此许可内。
    final audit = await run.scope.stable(() async {
      verify();
      await FavoriteDao.create(run.dao.storage);
      await SkillScriptDao.create(run.dao.storage);
      return ToolAuditDao.create(run.dao.storage);
    });
    verify();
    final actions = ToolActionContext(
      executionScope: this,
      openStorage: () async {
        verify();
        return run.dao.storage;
      },
      confirm: run.confirm,
      assistantId: run.input.assistantId,
      projectId: run.input.projectId,
      runJs: JsRuntimeService.isSupported
          ? (code, input) => const JsRuntimeService().run(code, input: input)
          : null,
    );
    var mcp = <ChatTool>[];
    if (settings.mcpConfigured) {
      final session = _session = McpExecutionSession(
          scope: this,
          backendBase: BackendConfig.buildUri('/uapi/mcp/'),
          backendHeaders: hiHeaders(),
          clientFactory: mcpClientFactory);
      mcp = await wait(McpToolSource.discover(settings,
          session: session,
          confirm: run.confirm,
          auditDao: audit,
          currentProjectId: run.input.projectId));
      verify();
      if (run.input.assistantId != null) {
        final bound = {...?toolIds};
        mcp = mcp.where((t) => bound.contains(t.name)).toList();
      }
    }
    final registry = ToolRegistry.fromAssistant(settings, toolIds,
        forceWebSearch: forceWebSearch, actions: actions, extraTools: mcp);
    // 已出站工具不能因本地审计写失败被客户端隐式再执行一次。
    return ToolRegistry(registry.tools,
        retryPolicy: const ToolRetryPolicy.none());
  }

  void release() {
    _released = true;
    _session?.close();
  }
}
