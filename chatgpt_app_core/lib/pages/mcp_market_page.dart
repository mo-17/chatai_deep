import 'package:chatgpt_app_core/data/builtin_mcp_servers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          const SizedBox(width: 4),
          _accessBadge(context, e.access),
        ],
      ),
      subtitle: Text(e.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      trailing: Icon(e.directAddable
          ? Icons.add_circle_outline_rounded
          : Icons.open_in_new_rounded),
      onTap: () => e.directAddable
          ? Navigator.pop(context, e)
          : _showEntryInfo(context, e),
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

  Widget _accessBadge(BuildContext context, McpAccessKind access) {
    final (label, color) = switch (access) {
      McpAccessKind.freeDirect => ('直连', Colors.green),
      McpAccessKind.keyRequired => ('配置', Colors.blue),
      McpAccessKind.externalEntry => ('入口', Colors.red),
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

  void _showEntryInfo(BuildContext context, McpStoreEntry e) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(e.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.description),
              if (e.authHint.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(e.authHint),
              ],
              if (e.homepage.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(e.homepage),
              ],
            ],
          ),
        ),
        actions: [
          if (e.homepage.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: e.homepage));
                if (!ctx.mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(ctx);
                messenger
                    .showSnackBar(const SnackBar(content: Text('入口链接已复制')));
              },
              icon: const Icon(Icons.copy),
              label: const Text('复制入口'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Text(
        '直连：免费或匿名可用，可直接添加。配置：需要补 API Key 或请求头。'
        '入口：OAuth / 付费 / 高权限服务，仅展示官方入口，不直接写入直连列表。'
        '本地 stdio 型移动端无法直连，请在管理后台「MCP 服务」里配置，App 端打开「后端 MCP Host」开关即可使用。',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }
}
