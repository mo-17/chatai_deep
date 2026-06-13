import 'package:chatgpt_app_core/data/builtin_assistants.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';

///助手市场（遗留项 9）：浏览内置助手模板，点一个即「添加到我的助手」。
///对应源项目 `AssistantMarketScreen`：内置模板按分类陈列，添加后落库成普通助手。
///
///添加走「预填的编辑页」——复用 [AssistantEditPage] 的全部表单与校验，
///用户可先改后存（id 为 null -> saveAssistant 走插入）。关闭市场时列表页会重新加载。
class AssistantMarketPage extends StatefulWidget {
  const AssistantMarketPage({Key? key}) : super(key: key);

  @override
  State<AssistantMarketPage> createState() => _AssistantMarketPageState();
}

class _AssistantMarketPageState extends State<AssistantMarketPage> {
  @override
  Widget build(BuildContext context) {
    final grouped = BuiltinAssistants.grouped();
    final categories = grouped.keys.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('助手市场'), centerTitle: true),
      body: ListView.builder(
        // 每个分类一个 section（header + 其下助手），最后留点底部留白。
        itemCount: categories.length,
        itemBuilder: (context, i) {
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
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              for (final a in items) _tile(a),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuiltinAssistant a) => ListTile(
        leading: CircleAvatar(child: Text(a.emoji)),
        title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          a.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.add_circle_outline),
        onTap: () => _add(a),
      );

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
