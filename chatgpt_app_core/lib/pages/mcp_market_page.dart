import 'package:chatgpt_app_core/data/builtin_mcp_servers.dart';
import 'package:flutter/material.dart';

/// MCP 服务商店（对应「助手市场」）：浏览精选的远程 MCP server，点一个即返回给
/// 设置页，预填进「添加直连 server」对话框，用户补好鉴权头/占位后保存。
///
/// 仅陈列远程 HTTP 型（方案 A 可直连）；本地 stdio 型需经后端 Host（方案 B），
/// 在页尾给出说明。点击返回所选 [McpStoreEntry]。
class McpMarketPage extends StatelessWidget {
  const McpMarketPage({super.key});

  @override
  Widget build(BuildContext context) {
    final grouped = McpStore.grouped(onlyHttp: true);
    final categories = grouped.keys.toList();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('MCP 服务商店'), centerTitle: true),
      body: ListView.builder(
        itemCount: categories.length + 1,
        itemBuilder: (context, i) {
          if (i == categories.length) return _footer(context);
          final category = categories[i];
          final items = grouped[category]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  category,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
              for (final e in items) _tile(context, e),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, McpStoreEntry e) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
          backgroundColor: cs.primaryContainer,
          child: Text(e.emoji, style: const TextStyle(fontSize: 18))),
      title: Row(
        children: [
          Flexible(child: Text(e.name, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          _authBadge(context, e.auth),
        ],
      ),
      subtitle: Text(e.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      trailing: const Icon(Icons.add_circle_outline_rounded),
      onTap: () => Navigator.pop(context, e),
    );
  }

  Widget _authBadge(BuildContext context, McpAuthKind auth) {
    final (label, color) = switch (auth) {
      McpAuthKind.none => ('免鉴权', Colors.green),
      McpAuthKind.header => ('需令牌', Colors.orange),
      McpAuthKind.apiKeyInUrl => ('需 Key', Colors.orange),
      McpAuthKind.oauth => ('需 OAuth', Colors.red),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _footer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Text(
        '只显示可直连的远程 HTTP server。本地 stdio 型（如官方 filesystem / git 等）'
        '移动端无法直连，请在管理后台「MCP 服务」里配置，App 端打开「后端 MCP Host」开关即可使用。',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }
}
