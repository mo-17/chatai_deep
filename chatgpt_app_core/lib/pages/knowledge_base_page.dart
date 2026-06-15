import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// 知识库管理页（L4a）：导入文档（粘贴文本 / PDF、文本文件）/ 列表 / 删除。
/// 导入的文档供绑定了「知识库检索」工具的助手按关键词检索作答。
class KnowledgeBasePage extends StatefulWidget {
  const KnowledgeBasePage({Key? key}) : super(key: key);

  @override
  State<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends State<KnowledgeBasePage> {
  KnowledgeDao? _dao;
  List<KnowledgeDoc> _docs = [];

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
    _dao = await KnowledgeDao.create(dbManager);
    await _loadData();
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
          // file_picker 暂无鸿蒙实现，OHOS 隐藏文件导入入口（粘贴文本仍可用）。
          if (Platform.operatingSystem != 'ohos')
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: '导入文件（PDF / 文本 / 图片，扫描件与图片走 OCR）',
              onPressed: _importFile,
            ),
        ],
      ),
      body: _docs.isEmpty ? _emptyView : _listView,
      floatingActionButton: FloatingActionButton(
        onPressed: _addDocument,
        tooltip: '粘贴文本导入',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _emptyView => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('📚', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('还没有文档。右下角粘贴文本、或右上角导入 PDF/文本文件，\n'
                '再给助手绑定「知识库检索」工具即可问答。',
                style: TextStyle(color: Colors.grey[600]),
                textAlign: TextAlign.center),
          ],
        ),
      );

  Widget get _listView => ListView.builder(
        itemCount: _docs.length,
        itemBuilder: (context, index) {
          final d = _docs[index];
          return ListTile(
            leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
            title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${d.chunkCount} 个片段'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () => _delete(d),
            ),
          );
        },
      );

  /// 导入文件（PDF / 文本 / 图片）：选文件 → 抽正文（图片或扫描件走 OCR）→ 切块落库。
  void _importFile() async {
    String? path;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          ...FileProcessor.pickerExtensions,
          ...OcrService.imageExtensions,
        ],
      );
      path = result?.files.single.path;
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '选取文件失败：$e');
      return;
    }
    if (path == null) return;
    final name = path.split(RegExp(r'[/\\]')).last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final isImage = OcrService.imageExtensions.contains(ext);

    String? text;
    try {
      if (isImage) {
        // 图片：必须 OCR。
        if (!OcrService.isSupported) {
          if (mounted) HiDialog.showSnackBar(context, '当前平台不支持 OCR（仅 Android/iOS）');
          return;
        }
        text = await _withLoading('正在识别图片…',
            () => OcrService.recognizeImageFile(path!));
      } else {
        // PDF / 文本：先抽文本层；PDF 像扫描件且支持 OCR 时回退逐页 OCR。
        text = await FileProcessor.extractTextForImport(path);
        if (ext == 'pdf' &&
            OcrService.isSupported &&
            OcrService.pdfNeedsOcr(text)) {
          text = await _withLoading('扫描件，正在 OCR 识别…',
              () => OcrService.recognizePdf(path!));
        }
      }
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, '识别失败：$e');
      return;
    }

    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      HiDialog.showSnackBar(context, '未能从「$name」提取到文字');
      return;
    }
    final title = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    final docId = await _dao!.addDocument(title, text);
    if (!mounted) return;
    HiDialog.showSnackBar(
        context, docId == null ? '导入失败（无可用内容）' : '已导入「$title」');
    await _loadData();
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
                decoration: const InputDecoration(
                  labelText: '内容（粘贴文本）',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
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
    final text = contentCtl.text.trim();
    if (text.isEmpty) {
      if (mounted) HiDialog.showSnackBar(context, '内容不能为空');
      return;
    }
    final docId = await _dao!.addDocument(titleCtl.text, text);
    if (!mounted) return;
    HiDialog.showSnackBar(
        context, docId == null ? '导入失败' : '已导入「${titleCtl.text.trim().isEmpty ? '未命名文档' : titleCtl.text.trim()}」');
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
