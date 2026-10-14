import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_execution_session.dart';

import 'package:chatgpt_app_core/chat/application/mcp/mcp_backend_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client_pool.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/tool_audit_record.dart';
import 'package:http/http.dart' as http;
import 'package:openai_flutter/utils/ai_logger.dart';

/// 写操作确认回调（复用会话页的 ToolActionContext.confirm 形态）。
typedef McpConfirm = Future<bool> Function(String title, String detail);

/// 供「助手编辑页」绑定用的 MCP 工具元信息（不含执行体）。
class McpToolBindSpec {
  /// 工具名（与模型可调用名一致，已做 safeName 处理）。
  final String name;

  /// 工具描述，含来源前缀（如 [source]）会拼进提示。
  final String description;

  /// 来源 server id（用于权限/审计/项目开关映射）。
  final String sourceServerId;

  /// 来源 server 展示名。
  final String sourceServerName;

  /// 来源是否可信（可信则默认跳过 confirm）。
  final bool trusted;

  /// 是否声明为只读工具；未来可用于写权限控制与 UI 标识。
  final bool readOnly;

  /// 项目级启用白名单，空数组表示「通用可用」。MVP 期为未来地基。
  final List<String> enabledProjects;

  const McpToolBindSpec({
    required this.name,
    required this.description,
    required this.sourceServerId,
    required this.sourceServerName,
    required this.trusted,
    this.readOnly = true,
    this.enabledProjects = const [],
  });
}

/// MCP 工具调用审计记录（MVP 地基：记录 confirm 判定与参数摘要）。
class McpToolInvocationRecord {
  final String toolName;
  final String sourceServerId;
  final String sourceServerName;
  final bool trusted;
  final bool approved;
  final DateTime at;
  final int argCount;

  const McpToolInvocationRecord({
    required this.toolName,
    required this.sourceServerId,
    required this.sourceServerName,
    required this.trusted,
    required this.approved,
    required this.at,
    required this.argCount,
  });
}

class _DiscoveredMcpTool {
  final ChatTool tool;
  final McpToolBindSpec spec;
  const _DiscoveredMcpTool(this.tool, this.spec);
}

class _Cached<T> {
  final DateTime at;
  final T value;
  const _Cached(this.at, this.value);
  bool get fresh => DateTime.now().difference(at) < McpToolSource.cacheTtl;
}

/// 一次直连发现的结果：工具清单 + server 声明的 resources/prompts 能力。
class _DirectInfo {
  final List<RawMcpTool> specs;
  final bool supportsResources;
  final bool supportsPrompts;
  const _DirectInfo(this.specs, this.supportsResources, this.supportsPrompts);
}

/// MCP 工具源：把方案 A（客户端直连）+ 方案 B（后端 Host）发现的 MCP 工具，
/// 统一映射成项目里的 [ChatTool]，由现有 [ToolLoopRunner] 驱动调用。
///
/// 安全取向：MCP 工具来自外部、不可信，默认每次调用前 `await confirm`
/// （confirm 为 null 时一律拒绝，防提示注入下的静默执行）；仅当来源被显式
/// 标记为「信任」时免确认——与项目对写工具/技能脚本的处理一致。
class McpToolSource {
  const McpToolSource._();

  /// 工具发现的缓存时长（避免每次发消息都重连 server 列工具）。
  static const Duration cacheTtl = Duration(seconds: 60);

  static final Map<String, _Cached<_DirectInfo>> _directCache = {};
  static _Cached<List<BackendMcpTool>>? _backendCache;
  static const int _auditLimit = 100;
  static final List<McpToolInvocationRecord> _auditTrail = [];

  /// 配置变更后清空缓存（设置页保存时调用）。同时清空直连连接池，
  /// 避免改了 URL / 请求头后仍复用旧连接。
  static void clearCache() {
    _directCache.clear();
    _backendCache = null;
    McpClientPool.clear();
  }

  /// 清理 MCP 审计轨迹（测试/退出页可调用）。
  static void clearAuditTrail() {
    _auditTrail.clear();
  }

  /// 最近的 MCP 调用记录（最多保留 [_auditLimit] 条）。
  static List<McpToolInvocationRecord> get auditTrail =>
      List<McpToolInvocationRecord>.unmodifiable(_auditTrail);

  /// 发现并装配当前设置下所有可用的 MCP 工具。任一来源失败都被吞掉
  /// （记日志，返回已成功的部分），绝不阻断会话发送。
  static Future<List<ChatTool>> discover(
    AISettings s, {
    McpConfirm? confirm,
    ToolAuditDao? auditDao,
    http.Client? client,
    int? currentProjectId,
    McpExecutionSession? session,
  }) async {
    return [
      for (final item in await _discoverWithSpec(s,
          confirm: confirm,
          auditDao: auditDao,
          client: client,
          currentProjectId: currentProjectId,
          session: session))
        item.tool
    ];
  }

  /// 列出当前设置下可绑定的 MCP 工具元信息（供助手编辑页勾选）。
  /// 与 [discover] 共用同一发现链路，保证工具名/来源一致。
  static Future<List<McpToolBindSpec>> listSpecs(
    AISettings s, {
    http.Client? client,
  }) async {
    final tools = await _discoverWithSpec(s,
        confirm: null, client: client, ignoreProjectFilter: true);
    return [for (final item in tools) item.spec];
  }

  static Future<List<_DiscoveredMcpTool>> _discoverWithSpec(
    AISettings s, {
    McpConfirm? confirm,
    ToolAuditDao? auditDao,
    http.Client? client,
    int? currentProjectId,
    bool ignoreProjectFilter = false,
    McpExecutionSession? session,
  }) async {
    if (!s.mcpConfigured) return const [];
    final items = <_DiscoveredMcpTool>[];

    // 方案 A：客户端直连各远程 server。
    for (final server in s.enabledMcpServers) {
      if (!ignoreProjectFilter &&
          !server.isEnabledForProject(currentProjectId)) {
        continue;
      }
      try {
        final info =
            await _listDirect(server, client: client, session: session);
        if (server.permission != McpToolPermission.readOnly) {
          for (final spec in info.specs) {
            final bind = McpToolBindSpec(
              name: _safeName('mcp__${server.id}__${spec.name}'),
              description: _withSource(spec.description, server.name),
              sourceServerId: server.id,
              sourceServerName: server.name,
              trusted: server.trusted,
              readOnly: false,
              enabledProjects: [
                for (final id in server.enabledProjectIds) '$id'
              ],
            );
            items.add(_DiscoveredMcpTool(
              _directTool(
                  server, spec, confirm, auditDao, client, bind, session),
              bind,
            ));
          }
        }
        // Resources / Prompts（item 7）：按 server 声明的能力暴露只读合成工具。
        if (info.supportsResources) {
          for (final tool in _resourceTools(server, client,
              sourceName: server.name, session: session)) {
            final name = tool.name;
            final bind = McpToolBindSpec(
              name: name,
              description: tool.description,
              sourceServerId: server.id,
              sourceServerName: server.name,
              trusted: server.trusted,
              readOnly: true,
              enabledProjects: [
                for (final id in server.enabledProjectIds) '$id'
              ],
            );
            items.add(_DiscoveredMcpTool(
              _auditWrappedTool(tool, bind,
                  confirm: confirm, auditDao: auditDao, session: session),
              bind,
            ));
          }
        }
        if (info.supportsPrompts) {
          for (final tool in _promptTools(server, client,
              sourceName: server.name, session: session)) {
            final name = tool.name;
            final bind = McpToolBindSpec(
              name: name,
              description: tool.description,
              sourceServerId: server.id,
              sourceServerName: server.name,
              trusted: server.trusted,
              readOnly: true,
              enabledProjects: [
                for (final id in server.enabledProjectIds) '$id'
              ],
            );
            items.add(_DiscoveredMcpTool(
              _auditWrappedTool(tool, bind,
                  confirm: confirm, auditDao: auditDao, session: session),
              bind,
            ));
          }
        }
      } catch (e) {
        session?.scope.verify();
        await session?.scope.beforeRequest();
        AILogger.log('MCP 直连 "${server.id}" 发现工具失败：$e');
      }
    }

    // 方案 B：后端聚合的 MCP 工具。
    if (s.mcpBackendEnabled) {
      try {
        final backendTools =
            await _listBackend(client: client, session: session);
        for (final t in backendTools) {
          final bind = McpToolBindSpec(
            name: t.name,
            description: _withSource(t.description, '后端 MCP'),
            sourceServerId: 'backend',
            sourceServerName: '后端 MCP',
            trusted: s.mcpBackendTrusted,
            readOnly: false,
          );
          items.add(_DiscoveredMcpTool(
            _backendTool(t, s.mcpBackendTrusted, confirm, auditDao, client,
                bind, session),
            bind,
          ));
        }
      } catch (e) {
        session?.scope.verify();
        await session?.scope.beforeRequest();
        AILogger.log('MCP 后端发现工具失败：$e');
      }
    }
    return items;
  }

  // ── 直连（方案 A）────────────────────────────────────────
  static Future<_DirectInfo> _listDirect(
    McpServerConfig server, {
    http.Client? client,
    McpExecutionSession? session,
  }) async {
    final key = '${server.id}|${server.url}';
    final cached = _directCache[key];
    if (session == null && cached != null && cached.fresh) return cached.value;
    // 复用池中连接（免重复握手）；列工具出错则驱逐，下次重连。
    final c = session?.direct(server) ??
        McpClientPool.acquire(server, client: client);
    try {
      final specs = await c.listTools();
      final info = _DirectInfo(specs, c.supportsResources, c.supportsPrompts);
      if (session == null) _directCache[key] = _Cached(DateTime.now(), info);
      return info;
    } catch (_) {
      if (session == null) {
        McpClientPool.evict(server);
      } else {
        session.evict(server);
      }
      rethrow;
    }
  }

  static ChatTool _directTool(
    McpServerConfig server,
    RawMcpTool spec,
    McpConfirm? confirm,
    ToolAuditDao? auditDao,
    http.Client? client,
    McpToolBindSpec bindSpec,
    McpExecutionSession? session,
  ) {
    final exposedName = _safeName('mcp__${server.id}__${spec.name}');
    return _auditWrappedTool(
      ChatTool(
        name: exposedName,
        description: _withSource(spec.description, server.name),
        parameters: spec.inputSchema,
        execute: (args) async {
          // 复用池中已初始化的连接；出错则驱逐，让下一次调用重连。
          final c = session?.direct(server) ??
              McpClientPool.acquire(server, client: client);
          try {
            final text = await c.callTool(spec.name, args);
            return ToolOutcome(content: text);
          } catch (e) {
            if (session == null) {
              McpClientPool.evict(server);
            } else {
              session.evict(server);
            }
            return ToolOutcome(content: 'MCP 工具「${spec.name}」执行失败：$e');
          }
        },
      ),
      bindSpec,
      confirm: confirm,
      auditDao: auditDao,
      sourceLabel: server.name,
      session: session,
    );
  }

  // ── Resources / Prompts 合成工具（item 7，只读、免确认）──────
  static List<ChatTool> _resourceTools(
      McpServerConfig server, http.Client? client,
      {String sourceName = '', McpExecutionSession? session}) {
    return [
      ChatTool(
        name: _safeName('mcp__${server.id}__resources_list'),
        description:
            '[MCP·${sourceName.isEmpty ? server.name : sourceName}] 列出该来源可读的资源（uri/名称/类型）。',
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (args) async {
          final c = session?.direct(server) ??
              McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: jsonEncode(await c.listResources()));
          } catch (e) {
            if (session == null) {
              McpClientPool.evict(server);
            } else {
              session.evict(server);
            }
            return ToolOutcome(content: '列资源失败：$e');
          }
        },
      ),
      ChatTool(
        name: _safeName('mcp__${server.id}__resources_read'),
        description:
            '[MCP·${sourceName.isEmpty ? server.name : sourceName}] 读取指定 uri 的资源正文（uri 来自 resources_list）。',
        parameters: const {
          'type': 'object',
          'properties': {
            'uri': {'type': 'string', 'description': '资源 uri'},
          },
          'required': ['uri'],
        },
        execute: (args) async {
          final uri = (args['uri'] as String? ?? '').trim();
          if (uri.isEmpty) return const ToolOutcome(content: '错误：缺少 uri 参数');
          final c = session?.direct(server) ??
              McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: await c.readResource(uri));
          } catch (e) {
            if (session == null) {
              McpClientPool.evict(server);
            } else {
              session.evict(server);
            }
            return ToolOutcome(content: '读资源失败：$e');
          }
        },
      ),
    ];
  }

  static List<ChatTool> _promptTools(
      McpServerConfig server, http.Client? client,
      {String sourceName = '', McpExecutionSession? session}) {
    return [
      ChatTool(
        name: _safeName('mcp__${server.id}__prompts_list'),
        description:
            '[MCP·${sourceName.isEmpty ? server.name : sourceName}] 列出该来源的提示词模板（名称/说明/参数）。',
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (args) async {
          final c = session?.direct(server) ??
              McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: jsonEncode(await c.listPrompts()));
          } catch (e) {
            if (session == null) {
              McpClientPool.evict(server);
            } else {
              session.evict(server);
            }
            return ToolOutcome(content: '列提示词失败：$e');
          }
        },
      ),
      ChatTool(
        name: _safeName('mcp__${server.id}__prompts_get'),
        description:
            '[MCP·${server.name}] 取指定提示词模板渲染后的文本（name 来自 prompts_list）。',
        parameters: const {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '提示词模板名'},
            'arguments': {'type': 'object', 'description': '模板参数（可选）'},
          },
          'required': ['name'],
        },
        execute: (args) async {
          final name = (args['name'] as String? ?? '').trim();
          if (name.isEmpty) return const ToolOutcome(content: '错误：缺少 name 参数');
          final promptArgs =
              (args['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
          final c = session?.direct(server) ??
              McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: await c.getPrompt(name, promptArgs));
          } catch (e) {
            if (session == null) {
              McpClientPool.evict(server);
            } else {
              session.evict(server);
            }
            return ToolOutcome(content: '取提示词失败：$e');
          }
        },
      ),
    ];
  }

  // ── 后端 Host（方案 B）──────────────────────────────────
  static Future<List<BackendMcpTool>> _listBackend(
      {http.Client? client, McpExecutionSession? session}) async {
    final cached = _backendCache;
    if (session == null && cached != null && cached.fresh) return cached.value;
    final c = session?.backend() ?? BackendMcpClient(client: client);
    try {
      final tools = await c.listTools();
      if (session == null) _backendCache = _Cached(DateTime.now(), tools);
      return tools;
    } finally {
      if (session == null) c.close();
    }
  }

  static ChatTool _backendTool(
    BackendMcpTool tool,
    bool trusted,
    McpConfirm? confirm,
    ToolAuditDao? auditDao,
    http.Client? client,
    McpToolBindSpec bindSpec,
    McpExecutionSession? session,
  ) {
    return _auditWrappedTool(
      ChatTool(
        name: tool.name, // 后端已加前缀，原样透传以便后端路由
        description: _withSource(tool.description, '后端 MCP'),
        parameters: tool.parameters,
        execute: (args) async {
          final c = session?.backend() ?? BackendMcpClient(client: client);
          try {
            final text = await c.callTool(tool.name, args);
            return ToolOutcome(content: text);
          } catch (e) {
            return ToolOutcome(content: 'MCP 工具「${tool.name}」执行失败：$e');
          } finally {
            if (session == null) c.close();
          }
        },
      ),
      bindSpec,
      confirm: confirm,
      auditDao: auditDao,
      trusted: trusted,
      sourceLabel: '后端 MCP',
      session: session,
    );
  }

  // ── 工具 ──────────────────────────────────────────────
  static const _denied = ToolOutcome(content: '用户拒绝了该 MCP 工具调用，未执行');

  static Future<bool> _confirm(
    McpConfirm? confirm,
    String source,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (confirm == null) return false;
    final preview = args.isEmpty ? '(无参数)' : _cap(jsonEncode(args), 300);
    return confirm('调用 MCP 工具', '来源：$source\n工具：$toolName\n参数：$preview');
  }

  static String _withSource(String? desc, String source) {
    final d = (desc ?? '').trim();
    return d.isEmpty ? '[MCP·$source]' : '[MCP·$source] $d';
  }

  /// OpenAI function name 仅允许 [a-zA-Z0-9_-]，且长度有限；做防御性净化。
  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  static ChatTool _auditWrappedTool(
    ChatTool tool,
    McpToolBindSpec bindSpec, {
    McpConfirm? confirm,
    ToolAuditDao? auditDao,
    bool trusted = false,
    String? sourceLabel,
    McpExecutionSession? session,
  }) {
    final source = sourceLabel ?? bindSpec.sourceServerName;
    return ChatTool(
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
      execute: (args) async {
        await session?.scope.beforeRequest();
        final needConfirm = !bindSpec.trusted && !trusted && !bindSpec.readOnly;
        final approved = needConfirm
            ? await _confirm(confirm, source, tool.name, args)
            : true;
        session?.scope.verify();
        if (!approved) {
          await _recordInvocation(
            bindSpec,
            args,
            approved: false,
            success: false,
            outcome: _denied.content,
            auditDao: auditDao,
            session: session,
          );
          return _denied;
        }
        try {
          await session?.scope.beforeRequest();
          final outcome = await tool.execute(args);
          session?.scope.verify();
          final success = !outcome.content.contains('失败');
          try {
            await _recordInvocation(bindSpec, args,
                approved: true,
                success: success,
                outcome: outcome.content,
                auditDao: auditDao,
                session: session);
          } catch (_) {
            if (session == null) rethrow;
            // 返回已知结果，不把本地落盘故障改判为外部动作尚未执行。
            // 原身份失效仍立即拒绝，后续请求不能沿旧账号继续。
            session.scope.verify();
            await session.scope.beforeRequest();
            return ToolOutcome(
                content: '${outcome.content}\n[本地审计未保存；已收到工具结果，不会自动重做该操作]',
                webResults: outcome.webResults,
                localSources: outcome.localSources);
          }
          return outcome;
        } catch (e) {
          await _recordInvocation(
            bindSpec,
            args,
            approved: true,
            success: false,
            error: '$e',
            auditDao: auditDao,
            session: session,
          );
          rethrow;
        }
      },
    );
  }

  static Future<void> _recordInvocation(
    McpToolBindSpec spec,
    Map<String, dynamic> args, {
    required bool approved,
    required bool success,
    String outcome = '',
    String? error,
    ToolAuditDao? auditDao,
    McpExecutionSession? session,
  }) async {
    final now = DateTime.now();
    _auditTrail.insert(
      0,
      McpToolInvocationRecord(
        toolName: spec.name,
        sourceServerId: spec.sourceServerId,
        sourceServerName: spec.sourceServerName,
        trusted: spec.trusted,
        approved: approved,
        at: now,
        argCount: args.length,
      ),
    );
    if (_auditTrail.length > _auditLimit) {
      _auditTrail.removeRange(_auditLimit, _auditTrail.length);
    }
    if (auditDao == null) return;
    final record = ToolAuditRecord(
      toolName: spec.name,
      sourceType: 'mcp',
      sourceId: spec.sourceServerId,
      sourceName: spec.sourceServerName,
      trusted: spec.trusted,
      readOnly: spec.readOnly,
      approved: approved,
      success: success,
      argCount: args.length,
      argsPreview: args.isEmpty ? '' : _cap(jsonEncode(args), 500),
      resultPreview: _cap(outcome, 500),
      error: error,
      createdAt: now.millisecondsSinceEpoch,
    );
    if (session == null) {
      await auditDao.record(record);
    } else {
      await session.scope.commit(
          (tx) => tx.insert(auditDao.tableName, record.toJson()..remove('id')));
    }
  }
}
