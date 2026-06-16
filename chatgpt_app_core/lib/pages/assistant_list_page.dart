import 'dart:io';

import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/skill_script_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_market_page.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:file_picker/file_picker.dart';
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
          // file_picker 暂无鸿蒙实现，OHOS 隐藏 zip 导入入口。
          if (Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: '导入技能（.zip，含 SKILL.md）',
              onPressed: _importSkillZip,
            ),
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

  /// 导入技能 zip（Agent Skill：SKILL.md + references/）：解析成
  /// 「助手（正文→系统提示词）+ 知识库文档（references→RAG）」并落库。
  /// 仅适用纯指令型 skill；带脚本/需沙箱的 skill 在移动端无法执行。
  void _importSkillZip() async {
    // 选 zip 文件。
    String? path;
    String? pickedName;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      path = result?.files.single.path;
      pickedName = result?.files.single.name;
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取文件失败：$e');
      return;
    }
    if (path == null) return;

    // 解析。
    SkillPackage pkg;
    try {
      final bytes = await File(path).readAsBytes();
      final fallback = (pickedName != null && pickedName.contains('.'))
          ? pickedName.substring(0, pickedName.lastIndexOf('.'))
          : pickedName;
      pkg = SkillImportService.parseArchive(bytes, fallbackName: fallback);
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(
          context, e is FormatException ? e.message : '解析失败：$e');
      return;
    }

    // 预览确认。
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${pkg.emoji} 导入技能「${pkg.name}」'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pkg.description.isNotEmpty) ...[
                Text(pkg.description,
                    style: TextStyle(color: Colors.grey[700], fontSize: 13)),
                const SizedBox(height: 12),
              ],
              Text('将新建助手：${pkg.name}'),
              Text('系统提示词：约 ${pkg.systemPrompt.length} 字'),
              Text(pkg.references.isEmpty
                  ? '参考资料：无'
                  : '参考资料：${pkg.references.length} 篇 → 导入知识库，'
                      '并自动绑定「知识库检索」工具\n'
                      '· ${pkg.references.map((r) => r.title).join('\n· ')}'),
              if (pkg.scripts.isNotEmpty)
                Text(
                  '脚本：${pkg.scripts.length} 个 → 绑定「运行脚本」工具，'
                  '运行前在沙箱执行并需你确认（仅 Android/iOS 等支持，鸿蒙不可执行）\n'
                  '· ${pkg.scripts.map((s) => s.name).join('\n· ')}',
                  style: TextStyle(color: Colors.orange[800], fontSize: 13),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;

    // 落库。
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final kbDao = await KnowledgeDao.create(dbManager);
      final scriptDao = await SkillScriptDao.create(dbManager);
      // 导入时 AI 安全审计的实时 LLM 调用（auditCall）暂留待接入聊天路径；
      // 现以 pending 入库，执行时由 run_script 工具展示代码预览 + 用户确认兜底。
      final result = await SkillImportService.import(
        pkg,
        assistantDao: _dao!,
        knowledgeDao: kbDao,
        scriptDao: scriptDao,
      );
      if (!mounted) return;
      final parts = <String>[
        if (result.docCount > 0) '${result.docCount} 篇资料进知识库',
        if (result.scriptCount > 0) '${result.scriptCount} 个脚本',
      ];
      final extra = parts.isEmpty ? '' : '，${parts.join('、')}';
      HiDialog.showSnackBar(context, '已导入技能「${result.name}」$extra');
      await _loadData();
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '导入失败：$e');
    }
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
