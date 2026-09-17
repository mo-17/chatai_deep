import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// 知识库管理页（L4a）：导入文档（粘贴文本 / PDF、文本文件）/ 列表 / 删除。
/// 导入的文档供绑定了「知识库检索」工具的助手按关键词检索作答。
class KnowledgeBasePage extends StatefulWidget {
  const KnowledgeBasePage({super.key});

  @override
  State<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends State<KnowledgeBasePage> {
  KnowledgeDao? _dao;
  List<KnowledgeDoc> _docs = [];
  bool _loading = true;
  Object? _loadError;

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
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      _dao = await KnowledgeDao.create(dbManager);
      if (!mounted) return;
      await _loadData();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadData() async {
    final list = await _dao!.getDocuments();
    setState(() => _docs = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知识库'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.manage_search_outlined),
            tooltip: '重建检索索引',
            onPressed: _loading || _dao == null ? null : _rebuildVectorIndex,
          ),
          // file_picker 暂无鸿蒙实现，OHOS 隐藏文件导入入口（粘贴文本仍可用）。
          if (Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: '导入文件（PDF / 文本 / 图片，扫描件与图片走 OCR）',
              onPressed: _loading || _dao == null ? null : _importFile,
            ),
        ],
      ),
      body: _body,
      floatingActionButton: FloatingActionButton(
        onPressed: _loading || _dao == null ? null : _addDocument,
        tooltip: '粘贴文本导入',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _body {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppVisualEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '知识库加载失败',
        message: _loadError.toString(),
        action: FilledButton.icon(
          onPressed: _doInit,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    return _docs.isEmpty ? _emptyView : _listView;
  }

  Widget get _emptyView => AppVisualEmptyState(
        icon: Icons.local_library_outlined,
        title: '还没有知识库文档',
        message: '粘贴文本或导入 PDF / 文本 / 图片，再给助手绑定「知识库检索」工具即可问答。',
        classic: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('📚', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                  '还没有文档。右下角粘贴文本、或右上角导入 PDF/文本文件，\n'
                  '再给助手绑定「知识库检索」工具即可问答。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget get _listView => ListView.builder(
        padding: AppVisualTheme.of(context).isAnime
            ? const EdgeInsets.fromLTRB(12, 12, 12, 20)
            : EdgeInsets.zero,
        itemCount: _docs.length,
        itemBuilder: (context, index) {
          final d = _docs[index];
          final tile = ListTile(
            leading:
                const CircleAvatar(child: Icon(Icons.description_outlined)),
            title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${d.chunkCount} 个片段'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () => _delete(d),
            ),
          );
          return AppVisualSurface(
            padding: EdgeInsets.zero,
            margin: AppVisualTheme.of(context).isAnime
                ? const EdgeInsets.only(bottom: 8)
                : EdgeInsets.zero,
            child: tile,
          );
        },
      );

  /// 导入文件（PDF / 文本 / 图片）：可多选 → 抽正文（图片或扫描件走 OCR）→ 切块落库。
  void _importFile() async {
    List<String> paths;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowMultiple: true,
        withData: false,
        allowedExtensions: [
          ...FileProcessor.pickerExtensions,
          ...OcrService.imageExtensions,
        ],
      );
      paths = [
        for (final file in result?.files ?? const <PlatformFile>[])
          if (file.path != null) file.path!,
      ];
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取文件失败：$e');
      return;
    }
    if (paths.isEmpty) return;
    if (!mounted) return;
    final result = await _withLoading(
      paths.length == 1 ? '正在导入文件…' : '正在导入 ${paths.length} 个文件…',
      () => KnowledgeFileImporter(_dao!).importPaths(paths),
    );
    if (!mounted) return;
    HiDialog.showSnackBar(context, result.message);
    if (result.failedItems.isNotEmpty) _showImportDetails(result);
    if (result.imported > 0) await _loadData();
  }

  void _rebuildVectorIndex() async {
    if (_dao == null) return;
    final stats = await _withLoading(
      '正在重建检索索引…',
      () => _dao!.rebuildVectorIndex(),
    );
    if (!mounted) return;
    HiDialog.showSnackBar(
      context,
      stats.chunks == 0
          ? '暂无可索引片段'
          : '已重建 ${stats.indexed}/${stats.chunks} 个检索片段',
    );
  }

  void _showImportDetails(KnowledgeFileImportResult result) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('部分文件未导入'),
        content: SingleChildScrollView(child: Text(result.detailMessage)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 执行一个耗时任务并显示模态加载框（OCR 可能较慢）。
  Future<T> _withLoading<T>(String label, Future<T> Function() task) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Flexible(child: Text(label)),
            ],
          ),
        ),
      ),
    );
    try {
      return await task();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _addDocument() async {
    final titleCtl = TextEditingController();
    final contentCtl = TextEditingController();
    String? contentError;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('导入文档'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtl,
                  decoration: const InputDecoration(
                    labelText: '标题',
                    hintText: '如：产品手册 / 退款政策',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtl,
                  minLines: 5,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: '内容（粘贴文本）',
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                    errorText: contentError,
                  ),
                  onChanged: (_) {
                    if (contentError != null) {
                      setDialogState(() => contentError = null);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (contentCtl.text.trim().isEmpty) {
                  setDialogState(() => contentError = '内容不能为空');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    final title = titleCtl.text;
    final text = contentCtl.text.trim();
    titleCtl.dispose();
    contentCtl.dispose();
    if (ok != true) return;
    final docId = await _dao!.addDocument(title, text);
    if (!mounted) return;
    HiDialog.showSnackBar(
        context,
        docId == null
            ? '导入失败'
            : '已导入「${title.trim().isEmpty ? '未命名文档' : title.trim()}」');
    await _loadData();
  }

  void _delete(KnowledgeDoc d) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文档'),
        content: Text('确定删除「${d.title}」及其全部片段吗？'),
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
    if (confirmed != true || d.id == null) return;
    await _dao!.deleteDocument(d.id!);
    if (!mounted) return;
    HiDialog.showSnackBar(context, '已删除「${d.title}」');
    await _loadData();
  }
}
