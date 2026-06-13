import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_market_page.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';

///助手管理页（阶段七）：列表 + 新建 / 编辑 / 删除。
///对应源项目 `src/screens/assistant/AssistantScreen.tsx` 的精简版。
class AssistantListPage extends StatefulWidget {
  const AssistantListPage({Key? key}) : super(key: key);

  @override
  State<AssistantListPage> createState() => _AssistantListPageState();
}

class _AssistantListPageState extends State<AssistantListPage> {
  AssistantDao? _dao;
  List<AssistantModel> _assistants = [];

  @override
  void initState() {
    super.initState();
    _doInit();
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
  }

  void _doInit() async {
    final dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    _dao = await AssistantDao.create(dbManager);
    await _loadData();
  }

  Future<void> _loadData() async {
    final list = await _dao!.getAssistants();
    setState(() => _assistants = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('助手管理'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            tooltip: '助手市场',
            onPressed: _openMarket,
          ),
        ],
      ),
      body: _assistants.isEmpty ? _emptyView : _listView,
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        tooltip: '新建助手',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _emptyView => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🤖', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('还没有助手，点右下角新建，或从右上角「助手市场」挑一个',
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center),
          ],
        ),
      );

  Widget get _listView => ListView.builder(
        itemCount: _assistants.length,
        itemBuilder: (context, index) {
          final a = _assistants[index];
          return ListTile(
            leading: CircleAvatar(
              child: Text(a.emoji.isNotEmpty ? a.emoji : '🤖'),
            ),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              _subtitleOf(a),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () => _delete(a),
            ),
            onTap: () => _edit(a),
          );
        },
      );

  String _subtitleOf(AssistantModel a) {
    final parts = <String>[
      if (a.model.trim().isNotEmpty) a.model,
      if (!a.useTools) '工具已关',
      if (a.prompt.trim().isNotEmpty) a.prompt.trim(),
    ];
    return parts.isEmpty ? '无系统提示词' : parts.join(' · ');
  }

  void _edit(AssistantModel? assistant) async {
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => AssistantEditPage(assistant: assistant)));
    if (changed == true) _loadData();
  }

  ///助手市场（遗留项 9）：浏览内置模板并添加。关闭后刷新列表（可能已添加几个）。
  void _openMarket() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const AssistantMarketPage()));
    _loadData();
  }

  void _delete(AssistantModel a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除助手'),
        content: Text('确定删除「${a.name}」吗？已绑定的会话将回落为无助手。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || a.id == null) return;
    await _dao!.deleteAssistant(a.id!);
    if (!mounted) return;
    HiDialog.showSnackBar(context, '已删除「${a.name}」');
    _loadData();
  }
}
