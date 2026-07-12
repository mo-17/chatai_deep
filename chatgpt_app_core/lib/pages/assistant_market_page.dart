import 'package:chatgpt_app_core/data/builtin_assistants.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:flutter/material.dart';

///助手市场（遗留项 9）：浏览内置助手模板，点一个即「添加到我的助手」。
///对应源项目 `AssistantMarketScreen`：内置模板按分类陈列，添加后落库成普通助手。
///
///添加走「预填的编辑页」——复用 [AssistantEditPage] 的全部表单与校验，
///用户可先改后存（id 为 null -> saveAssistant 走插入）。关闭市场时列表页会重新加载。
class AssistantMarketPage extends StatefulWidget {
  const AssistantMarketPage({super.key});

  @override
  State<AssistantMarketPage> createState() => _AssistantMarketPageState();
}

class _AssistantMarketPageState extends State<AssistantMarketPage> {
  String _query = '';

  Map<String, List<BuiltinAssistant>> _filteredGroups() {
    final query = _query.trim().toLowerCase();
    final items = query.isEmpty
        ? BuiltinAssistants.all
        : BuiltinAssistants.all.where((a) {
            final text = '${a.category} ${a.name} ${a.description} ${a.prompt}'
                .toLowerCase();
            return text.contains(query);
          }).toList();
    final grouped = <String, List<BuiltinAssistant>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _filteredGroups();
    final categories = grouped.keys.toList();
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('助手市场'), centerTitle: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SearchBar(
              key: const ValueKey('assistant_market_search'),
              hintText: '搜索助手模板',
              leading: const Icon(Icons.search_rounded),
              elevation: const WidgetStatePropertyAll(0),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: categories.isEmpty
                ? AppVisualEmptyState(
                    animeKey: const ValueKey('assistant_market_empty'),
                    icon: Icons.auto_awesome_outlined,
                    title: '未找到匹配的助手',
                    message: '换一个关键词试试，或清空搜索查看全部模板。',
                    classic: Center(
                      key: const ValueKey('assistant_market_empty'),
                      child: Text(
                        '未找到匹配的助手',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    // 每个分类一个 section（header + 其下助手），最后留点底部留白。
                    padding: visual.isAnime
                        ? const EdgeInsets.only(bottom: 20)
                        : EdgeInsets.zero,
                    itemCount: categories.length,
                    itemBuilder: (context, i) {
                      final category = categories[i];
                      final items = grouped[category]!;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                            child: Text(
                              category,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                          for (final a in items) _tile(a),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuiltinAssistant a) {
    final visual = AppVisualTheme.of(context);
    final tile = ListTile(
      leading: visual.isAnime
          ? AssistantAvatar.raw(emoji: a.emoji)
          : CircleAvatar(child: Text(a.emoji)),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        a.description.isEmpty ? a.prompt : a.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: const Icon(Icons.add_circle_outline),
      onTap: () => _add(a),
    );
    if (!visual.isAnime) return tile;
    return AppVisualSurface(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      animeKey: ValueKey('assistant_market_card_${a.name}'),
      child: tile,
    );
  }

  void _add(BuiltinAssistant a) async {
    // 预填编辑页：模板转成新的 AssistantModel（id 为 null），用户可改后保存。
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AssistantEditPage(assistant: a.toAssistant()),
      ),
    );
    if (added == true && mounted) {
      HiDialog.showSnackBar(context, '已添加「${a.name}」到我的助手');
    }
  }
}
