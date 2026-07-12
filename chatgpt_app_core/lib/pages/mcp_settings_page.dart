import 'package:chatgpt_app_core/chat/application/mcp/mcp_backend_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/data/builtin_mcp_servers.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/mcp_market_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/widget/ai_provider/section_card.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';

/// MCP 服务设置页。两条接入路径并存：
///  - 方案 A「直连 server」：客户端直连远程 Streamable HTTP 型 MCP server；
///  - 方案 B「后端 Host」：开关启用后，工具由后端聚合并代为执行（可用上 stdio
///    型 server）。两路发现的工具都并入会话的工具回路，执行前默认需确认。
class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({super.key});

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  late final AISettingsProvider _store = context.read<AISettingsProvider>();

  /// 改一项就克隆、应用、落盘，并清掉工具发现缓存让改动即时生效。
  void _patch(void Function(AISettings) mutate) {
    final s = _store.settings.clone();
    mutate(s);
    _store.update(s);
    McpToolSource.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AISettingsProvider>();
    final s = _store.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('MCP 服务')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          _buildIntro(),
          const SizedBox(height: 8),
          const SectionLabel('后端 MCP Host（方案 B）'),
          _buildBackendCard(s),
          const SizedBox(height: 16),
          _buildDirectHeader(),
          _buildDirectList(s),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildDirectHeader() {
    final market = TextButton.icon(
      icon: const Icon(Icons.storefront_outlined, size: 18),
      label: const Text('商店'),
      onPressed: _openMarket,
    );
    final add = TextButton.icon(
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('添加'),
      onPressed: () => _editServer(),
    );
    if (AppVisualTheme.of(context).isAnime) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel(
              '直连 MCP server（方案 A）',
              padding: EdgeInsets.only(bottom: 4),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 8, runSpacing: 8, children: [market, add]),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const SectionLabel(
            '直连 MCP server（方案 A）',
            padding: EdgeInsets.only(bottom: 8),
          ),
          const Spacer(),
          market,
          add,
        ],
      ),
    );
  }

  Widget _buildIntro() {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(
        'MCP 工具来自外部、不可信，默认每次调用前需你确认（标记为「信任」的来源除外）。'
        '直连仅支持远程 HTTP 型 server；本地 stdio 型 server 请用后端 Host。',
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }

  // ── 方案 B：后端 Host ───────────────────────────────────
  Widget _buildBackendCard(AISettings s) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final guest = LoginDao.isGuest();
    return SectionCard(
      children: [
        SwitchListTile(
          value: s.mcpBackendEnabled,
          onChanged:
              guest ? null : (v) => _patch((x) => x.mcpBackendEnabled = v),
          title: const Text('启用后端 MCP'),
          subtitle: Text(
            guest ? '游客模式不可用，登录后开启' : '工具由后端聚合，执行经 /uapi/mcp/call 代理',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        if (s.mcpBackendEnabled) ...[
          SwitchListTile(
            value: s.mcpBackendTrusted,
            onChanged: (v) => _patch((x) => x.mcpBackendTrusted = v),
            title: const Text('信任后端工具（免确认）'),
            subtitle: Text('开启后调用这些工具不再逐次确认',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.network_check_rounded),
            title: const Text('测试后端工具清单'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            onTap: _testBackend,
          ),
        ],
      ],
    );
  }

  Future<void> _testBackend() async {
    final client = BackendMcpClient();
    String msg;
    try {
      final tools = await client.listTools();
      msg = tools.isEmpty
          ? '后端已连通，但未聚合到任何工具（检查后端 MCP_SERVERS 配置）'
          : '后端聚合到 ${tools.length} 个工具：\n${tools.map((t) => '• ${t.name}').take(20).join('\n')}';
    } catch (e) {
      msg = '失败：$e';
    } finally {
      client.close();
    }
    _showResult('后端 MCP', msg);
  }

  // ── 方案 A：直连 server 列表 ─────────────────────────────
  Widget _buildDirectList(AISettings s) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (s.mcpServers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text('还没有直连 server，点右上角「添加」配置一个远程 MCP 端点。',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      );
    }
    return SectionCard(
      children: [
        for (final server in s.mcpServers)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: Switch(
              value: server.enabled,
              onChanged: (v) => _patch((x) {
                final i = x.mcpServers.indexWhere((e) => e.id == server.id);
                if (i >= 0) {
                  x.mcpServers[i] = x.mcpServers[i].copyWith(enabled: v);
                }
              }),
            ),
            title: Row(
              children: [
                Flexible(
                    child: Text(server.name, overflow: TextOverflow.ellipsis)),
                if (server.trusted) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.verified_user_rounded,
                      size: 14, color: cs.primary),
                ],
              ],
            ),
            subtitle: Text(server.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _editServer(existing: server);
                if (v == 'test') _testDirect(server);
                if (v == 'delete') _deleteServer(server);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'test', child: Text('测试连接')),
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _testDirect(McpServerConfig server) async {
    final client = DirectMcpClient(url: server.url, headers: server.headers);
    String msg;
    try {
      final tools = await client.listTools();
      msg = tools.isEmpty
          ? '已连通，但该 server 未声明任何工具'
          : '连通，发现 ${tools.length} 个工具：\n${tools.map((t) => '• ${t.name}').take(20).join('\n')}';
    } catch (e) {
      msg = '失败：$e';
    } finally {
      client.close();
    }
    _showResult(server.name, msg);
  }

  void _deleteServer(McpServerConfig server) {
    _patch((x) => x.mcpServers.removeWhere((e) => e.id == server.id));
  }

  /// 新增 / 编辑一个直连 server。对话框抽成独立 [_ServerEditDialog]，由其自身
  /// State.dispose() 释放 TextEditingController——只会在对话框 route 真正卸载
  /// （退出动画结束）后执行，避免「保存触发 provider 重建时控制器已被 dispose」
  /// 的竞态（TextEditingController used after disposed）。
  /// 打开 MCP 服务商店，选中一条后预填进添加对话框。
  Future<void> _openMarket() async {
    final picked = await Navigator.push<McpStoreEntry>(
      context,
      MaterialPageRoute(builder: (_) => const McpMarketPage()),
    );
    if (picked != null && mounted) await _editServer(prefill: picked);
  }

  Future<void> _editServer({
    McpServerConfig? existing,
    McpStoreEntry? prefill,
  }) async {
    final result = await showDialog<_ServerEditResult>(
      context: context,
      builder: (_) => _ServerEditDialog(existing: existing, prefill: prefill),
    );
    if (result == null) return;
    final name = result.name.trim();
    final url = result.url.trim();
    if (url.isEmpty) return;
    _patch((x) {
      final cfg = McpServerConfig(
        id: existing?.id ?? _genId(prefill?.id ?? name, x.mcpServers),
        name: name.isEmpty ? 'MCP' : name,
        url: url,
        headers: _parseHeaders(result.headersText),
        enabled: existing?.enabled ?? true,
        trusted: result.trusted,
        permission: result.permission,
        enabledProjectIds: existing?.enabledProjectIds ?? const [],
      );
      final i = x.mcpServers.indexWhere((e) => e.id == cfg.id);
      if (i >= 0) {
        x.mcpServers[i] = cfg;
      } else {
        x.mcpServers.add(cfg);
      }
    });
  }

  Map<String, String> _parseHeaders(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if (k.isNotEmpty) out[k] = v;
    }
    return out;
  }

  /// 由名称派生稳定 id（[a-z0-9_]），并保证在现有列表里唯一。
  String _genId(String name, List<McpServerConfig> existing) {
    var base = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.isEmpty) base = 'srv';
    var id = base;
    var n = 1;
    final ids = existing.map((e) => e.id).toSet();
    while (ids.contains(id)) {
      id = '${base}_${++n}';
    }
    return id;
  }

  void _showResult(String title, String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(msg)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('确定')),
        ],
      ),
    );
  }
}

/// 直连 server 编辑对话框的回传值（原始文本，请求头由调用方解析）。
class _ServerEditResult {
  final String name;
  final String url;
  final String headersText;
  final bool trusted;
  final McpToolPermission permission;
  const _ServerEditResult({
    required this.name,
    required this.url,
    required this.headersText,
    required this.trusted,
    required this.permission,
  });
}

/// 直连 MCP server 的新增 / 编辑对话框。控制器由本 State 持有并在 dispose 中释放，
/// 保证仅在对话框 route 卸载后才回收，避免对话框退出动画期间被重建时引用到已
/// dispose 的控制器。
class _ServerEditDialog extends StatefulWidget {
  final McpServerConfig? existing;

  /// 来自商店的预填条目（新增时用其名称 / URL / 鉴权提示初始化）。
  final McpStoreEntry? prefill;
  const _ServerEditDialog({this.existing, this.prefill});

  @override
  State<_ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<_ServerEditDialog> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _urlCtl;
  late final TextEditingController _headersCtl;
  late bool _trusted;
  late McpToolPermission _permission;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final p = widget.prefill;
    _nameCtl = TextEditingController(text: e?.name ?? p?.name ?? '');
    _urlCtl = TextEditingController(text: e?.url ?? p?.url ?? '');
    // 编辑：回填已存请求头；商店新增且为「需令牌」型：预填一行 Authorization 引导。
    final headersText = e != null
        ? e.headers.entries.map((h) => '${h.key}: ${h.value}').join('\n')
        : (p?.auth == McpAuthKind.header ? 'Authorization: Bearer ' : '');
    _headersCtl = TextEditingController(text: headersText);
    _trusted = e?.trusted ?? false;
    _permission = e?.permission ?? McpToolPermission.confirmWrite;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _urlCtl.dispose();
    _headersCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? '添加 MCP server' : '编辑 MCP server'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((widget.prefill?.authHint ?? '').isNotEmpty) ...[
              if (visual.isAnime)
                AppVisualSurface(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lightbulb_outline_rounded,
                        color: AppStatusPalette.of(
                          context,
                          AppStatusKind.warning,
                        ).foreground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(widget.prefill!.authHint)),
                    ],
                  ),
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('💡 ${widget.prefill!.authHint}',
                      style: const TextStyle(fontSize: 12)),
                ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(
                  labelText: '名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtl,
              decoration: const InputDecoration(
                labelText: '端点 URL',
                hintText: 'https://example.com/mcp',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _headersCtl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '请求头（每行 Key: Value，可选）',
                hintText: 'Authorization: Bearer xxxxx',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('信任此 server（免确认）'),
              value: _trusted,
              onChanged: (v) => setState(() => _trusted = v),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<McpToolPermission>(
              initialValue: _permission,
              decoration: const InputDecoration(
                labelText: '工具权限',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: McpToolPermission.confirmWrite,
                  child: Text('可调用工具（写入需确认）'),
                ),
                DropdownMenuItem(
                  value: McpToolPermission.readOnly,
                  child: Text('仅资源/提示词只读'),
                ),
              ],
              onChanged: (v) => setState(
                  () => _permission = v ?? McpToolPermission.confirmWrite),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            _ServerEditResult(
              name: _nameCtl.text,
              url: _urlCtl.text,
              headersText: _headersCtl.text,
              trusted: _trusted,
              permission: _permission,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
