import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/mcp/mcp_backend_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client_pool.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:http/http.dart' as http;
import 'package:openai_flutter/utils/ai_logger.dart';

/// 写操作确认回调（复用会话页的 ToolActionContext.confirm 形态）。
typedef McpConfirm = Future<bool> Function(String title, String detail);

/// 供「助手编辑页」绑定用的 MCP 工具元信息（不含执行体）。
class McpToolBindSpec {
  final String name;
  final String description;
  const McpToolBindSpec({required this.name, required this.description});
}

class _Cached<T> {
  final DateTime at;
  final T value;
  const _Cached(this.at, this.value);
  bool get fresh =>
      DateTime.now().difference(at) < McpToolSource.cacheTtl;
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

  /// 配置变更后清空缓存（设置页保存时调用）。同时清空直连连接池，
  /// 避免改了 URL / 请求头后仍复用旧连接。
  static void clearCache() {
    _directCache.clear();
    _backendCache = null;
    McpClientPool.clear();
  }

  /// 发现并装配当前设置下所有可用的 MCP 工具。任一来源失败都被吞掉
  /// （记日志，返回已成功的部分），绝不阻断会话发送。
  static Future<List<ChatTool>> discover(
    AISettings s, {
    McpConfirm? confirm,
    http.Client? client,
  }) async {
    if (!s.mcpConfigured) return const [];
    final tools = <ChatTool>[];

    // 方案 A：客户端直连各远程 server。
    for (final server in s.enabledMcpServers) {
      try {
        final info = await _listDirect(server, client: client);
        for (final spec in info.specs) {
          tools.add(_directTool(server, spec, confirm, client));
        }
        // Resources / Prompts（item 7）：按 server 声明的能力暴露只读合成工具。
        if (info.supportsResources) {
          tools.addAll(_resourceTools(server, client));
        }
        if (info.supportsPrompts) {
          tools.addAll(_promptTools(server, client));
        }
      } catch (e) {
        AILogger.log('MCP 直连 "${server.id}" 发现工具失败：$e');
      }
    }

    // 方案 B：后端聚合的 MCP 工具。
    if (s.mcpBackendEnabled) {
      try {
        final backendTools = await _listBackend(client: client);
        for (final t in backendTools) {
          tools.add(_backendTool(t, s.mcpBackendTrusted, confirm, client));
        }
      } catch (e) {
        AILogger.log('MCP 后端发现工具失败：$e');
      }
    }
    return tools;
  }

  /// 列出当前设置下可绑定的 MCP 工具元信息（供助手编辑页勾选）。
  /// 复用 [discover] 的发现逻辑，只取名称/描述，不构造执行体。
  static Future<List<McpToolBindSpec>> listSpecs(
    AISettings s, {
    http.Client? client,
  }) async {
    final tools = await discover(s, confirm: null, client: client);
    return [
      for (final t in tools)
        McpToolBindSpec(name: t.name, description: t.description),
    ];
  }

  // ── 直连（方案 A）────────────────────────────────────────
  static Future<_DirectInfo> _listDirect(
    McpServerConfig server, {
    http.Client? client,
  }) async {
    final key = '${server.id}|${server.url}';
    final cached = _directCache[key];
    if (cached != null && cached.fresh) return cached.value;
    // 复用池中连接（免重复握手）；列工具出错则驱逐，下次重连。
    final c = McpClientPool.acquire(server, client: client);
    try {
      final specs = await c.listTools();
      final info = _DirectInfo(specs, c.supportsResources, c.supportsPrompts);
      _directCache[key] = _Cached(DateTime.now(), info);
      return info;
    } catch (_) {
      McpClientPool.evict(server);
      rethrow;
    }
  }

  static ChatTool _directTool(
    McpServerConfig server,
    RawMcpTool spec,
    McpConfirm? confirm,
    http.Client? client,
  ) {
    final exposedName = _safeName('mcp__${server.id}__${spec.name}');
    return ChatTool(
      name: exposedName,
      description: _withSource(spec.description, server.name),
      parameters: spec.inputSchema,
      execute: (args) async {
        if (!server.trusted &&
            !await _confirm(confirm, server.name, spec.name, args)) {
          return _denied;
        }
        // 复用池中已初始化的连接；出错则驱逐，让下一次调用重连。
        final c = McpClientPool.acquire(server, client: client);
        try {
          final text = await c.callTool(spec.name, args);
          return ToolOutcome(content: text);
        } catch (e) {
          McpClientPool.evict(server);
          return ToolOutcome(content: 'MCP 工具「${spec.name}」执行失败：$e');
        }
      },
    );
  }

  // ── Resources / Prompts 合成工具（item 7，只读、免确认）──────
  static List<ChatTool> _resourceTools(
      McpServerConfig server, http.Client? client) {
    return [
      ChatTool(
        name: _safeName('mcp__${server.id}__resources_list'),
        description: '[MCP·${server.name}] 列出该来源可读的资源（uri/名称/类型）。',
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (args) async {
          final c = McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: jsonEncode(await c.listResources()));
          } catch (e) {
            McpClientPool.evict(server);
            return ToolOutcome(content: '列资源失败：$e');
          }
        },
      ),
      ChatTool(
        name: _safeName('mcp__${server.id}__resources_read'),
        description: '[MCP·${server.name}] 读取指定 uri 的资源正文（uri 来自 resources_list）。',
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
          final c = McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: await c.readResource(uri));
          } catch (e) {
            McpClientPool.evict(server);
            return ToolOutcome(content: '读资源失败：$e');
          }
        },
      ),
    ];
  }

  static List<ChatTool> _promptTools(
      McpServerConfig server, http.Client? client) {
    return [
      ChatTool(
        name: _safeName('mcp__${server.id}__prompts_list'),
        description: '[MCP·${server.name}] 列出该来源的提示词模板（名称/说明/参数）。',
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
        execute: (args) async {
          final c = McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: jsonEncode(await c.listPrompts()));
          } catch (e) {
            McpClientPool.evict(server);
            return ToolOutcome(content: '列提示词失败：$e');
          }
        },
      ),
      ChatTool(
        name: _safeName('mcp__${server.id}__prompts_get'),
        description: '[MCP·${server.name}] 取指定提示词模板渲染后的文本（name 来自 prompts_list）。',
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
          final c = McpClientPool.acquire(server, client: client);
          try {
            return ToolOutcome(content: await c.getPrompt(name, promptArgs));
          } catch (e) {
            McpClientPool.evict(server);
            return ToolOutcome(content: '取提示词失败：$e');
          }
        },
      ),
    ];
  }

  // ── 后端 Host（方案 B）──────────────────────────────────
  static Future<List<BackendMcpTool>> _listBackend({http.Client? client}) async {
    final cached = _backendCache;
    if (cached != null && cached.fresh) return cached.value;
    final c = BackendMcpClient(client: client);
    try {
      final tools = await c.listTools();
      _backendCache = _Cached(DateTime.now(), tools);
      return tools;
    } finally {
      c.close();
    }
  }

  static ChatTool _backendTool(
    BackendMcpTool tool,
    bool trusted,
    McpConfirm? confirm,
    http.Client? client,
  ) {
    return ChatTool(
      name: tool.name, // 后端已加前缀，原样透传以便后端路由
      description: _withSource(tool.description, '后端 MCP'),
      parameters: tool.parameters,
      execute: (args) async {
        if (!trusted &&
            !await _confirm(confirm, '后端 MCP', tool.name, args)) {
          return _denied;
        }
        final c = BackendMcpClient(client: client);
        try {
          final text = await c.callTool(tool.name, args);
          return ToolOutcome(content: text);
        } catch (e) {
          return ToolOutcome(content: 'MCP 工具「${tool.name}」执行失败：$e');
        } finally {
          c.close();
        }
      },
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
}
