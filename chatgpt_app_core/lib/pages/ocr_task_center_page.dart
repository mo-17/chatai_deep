import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/platform/app_io.dart';
import '../backup/backup_service.dart';
import '../chat/application/creative_file_transfer_gateway.dart';
import '../chat/application/knowledge_import_error.dart';
import '../chat/application/ocr_task_center.dart';
import '../dao/ai_catalog_dao.dart';
import '../db/ocr_task_dao.dart';
import '../platform/app_file_picker.dart';
import '../util/bounded_file_reader.dart';
import 'ocr_review_page.dart';
import 'document_scan_page.dart';
import 'ocr_table_export_page.dart';
import '../chat/application/ocr_export.dart';

class OcrTaskCenterPage extends StatefulWidget {
  final OcrTaskCenter? service;
  const OcrTaskCenterPage({super.key, this.service});
  @override
  State<OcrTaskCenterPage> createState() => _OcrTaskCenterPageState();
}

class _OcrTaskCenterPageState extends State<OcrTaskCenterPage> {
  OcrTaskCenter? _service;
  List<OcrTaskRecord> _tasks = [];
  String? _error;
  bool _busy = false;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    AiCatalogIdentity.changes.addListener(_environmentChanged);
    BackendConfig.changes.addListener(_environmentChanged);
    BackupService.restoreTick.addListener(_environmentChanged);
    _open();
  }

  Future<void> _open() async {
    try {
      final service = widget.service ?? await OcrTaskCenter.open();
      if (!mounted) return;
      _service = service;
      service.addListener(_changed);
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  void _changed() {
    unawaited(_reload());
  }

  void _environmentChanged() {
    if (_service?.current == false) _service?.retire();
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final ticket = ++_revision;
    try {
      final rows = await _service!.list();
      if (mounted && ticket == _revision) {
        setState(() {
          _tasks = rows;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && ticket == _revision) {
        setState(() => _error = _message(error));
      }
    }
  }

  @override
  void dispose() {
    _service?.removeListener(_changed);
    AiCatalogIdentity.changes.removeListener(_environmentChanged);
    BackendConfig.changes.removeListener(_environmentChanged);
    BackupService.restoreTick.removeListener(_environmentChanged);
    super.dispose();
  }

  bool get _current => mounted && _service?.current == true;
  void _notice(String text) {
    if (_current) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  static String _message(Object error) => error is KnowledgeImportFailure
      ? error.message
      : error is FormatException
          ? error.message.toString()
          : '操作未完成，请返回检查账号、网络或存储后重试';
  Future<void> _action(Future<void> Function() action) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _notice(_message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _action(() async {
        final result = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: const [
              'pdf',
              'png',
              'jpg',
              'jpeg',
              'webp',
              'bmp'
            ],
            allowMultiple: true,
            withData: false,
            dialogTitle: '添加 OCR 文件');
        if (result == null || !_current) return;
        if (result.files.length > OcrTaskDao.maxTasks) {
          throw const FormatException('每批最多选择 20 个文件');
        }
        var added = 0;
        final failures = <String>[];
        for (final file in result.files) {
          if (!_current) return;
          try {
            final Uint8List bytes;
            if (file.bytes != null) {
              bytes = file.bytes!;
            } else if (file.path != null) {
              bytes = await readFileBytesBounded(appFile(file.path!),
                  maxBytes: 8 * 1024 * 1024);
            } else {
              throw const FormatException('没有可读取的文件内容');
            }
            if (!_current) return;
            await _service!.add(file.name, bytes);
            added++;
          } catch (error) {
            failures.add('${file.name}：${_message(error)}');
          }
        }
        _notice(
            '已添加 $added 个任务${failures.isEmpty ? '' : '，${failures.length} 个未添加'}');
        if (mounted && failures.isNotEmpty && _current) {
          await showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                      title: const Text('部分文件未添加'),
                      content: SingleChildScrollView(
                          child: Text(failures.join('\n'))),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('知道了'))
                      ]));
        }
      });

  Future<void> _start(List<OcrTaskRecord> tasks) => _action(() async {
        if (tasks.isEmpty) return;
        final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('上传并识别'),
                    content: SingleChildScrollView(
                        child: Text(
                            '将 ${tasks.length} 个文件上传到 ${_service!.origin}。PDF 会整份上传。\n\n'
                            '服务器在任务结束后删除原件；本机保留原件副本、识别结果和校对文字，直到你删除任务。'
                            '离开页面仍可处理；应用中断或服务器重启后，可回来手动重试。\n\n'
                            '每个文件最多 8 MiB，PDF 最多 20 页，按顺序识别。')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('开始识别'))
                    ]));
        if (ok == true && _current) {
          await _service!.start(tasks.map((task) => task.id).toList());
        }
      });

  Future<void> _review(OcrTaskRecord task) => _action(() async {
        final data = await _service!.load(task.id);
        if (!mounted || !_current || data?.result == null) return;
        final corrected = await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => OcrReviewPage(
                    filename: task.name,
                    result: data!.result!,
                    imageBytes: task.pdf ? null : data.bytes,
                    isCurrent: () => _service!.current)));
        if (corrected != null && _current) {
          await _service!.saveCorrection(task.id, corrected);
        }
      });

  Future<void> _menu(OcrTaskRecord task, String action) => _action(() async {
        final service = _service!;
        if (action == 'cancel') {
          await service.cancel(task.id);
          return;
        }
        if (action == 'delete') {
          final ok = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                      title: const Text('删除 OCR 任务'),
                      content: const Text('删除本机保存的原件副本和识别结果。已导入知识库的资料会保留。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('删除'))
                      ]));
          if (ok == true && _current) await service.delete(task.id);
          return;
        }
        final data = await service.load(task.id);
        if (!_current || data == null) return;
        if (action == 'source') {
          await CreativeFileTransferGateway(maxBytes: 8 * 1024 * 1024)
              .saveBytes(data.bytes,
                  fileName: task.name, dialogTitle: '导出原件副本');
        } else if (action == 'copy') {
          await Clipboard.setData(ClipboardData(text: data.result!.text));
          _notice('已复制校对文字');
        } else if (action == 'knowledge') {
          await service.importKnowledge(task.id);
          _notice('已导入知识库');
        } else if (action == 'table') {
          if (!mounted) return;
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => OcrTableExportPage(
                      filename: task.name,
                      result: data.result!,
                      isCurrent: () => service.current)));
        } else if (action == 'pdf') {
          final bytes = await searchableOcrPdf(
              source: data.bytes, pdf: task.pdf, result: data.result!);
          service.verify();
          final name = task.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
          final saved =
              await CreativeFileTransferGateway(maxBytes: 16 * 1024 * 1024)
                  .saveBytes(bytes,
                      fileName: '${name}_可搜索.pdf',
                      dialogTitle: '导出可搜索 PDF',
                      allowedExtensions: ['pdf']);
          if (saved.saved) _notice('已导出可搜索 PDF，原件已有文字的页面保持原文本层');
        }
      });

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final available = service?.current == true;
    return Scaffold(
        appBar: AppBar(title: const Text('OCR 任务中心'), actions: [
          IconButton(
              tooltip: '拍照扫描',
              onPressed: available && !_busy
                  ? () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => DocumentScanPage(service: service!)))
                  : null,
              icon: const Icon(Icons.document_scanner_outlined)),
          IconButton(
              tooltip: '添加文件',
              onPressed: available && !_busy ? _pick : null,
              icon: const Icon(Icons.add)),
        ]),
        body: !available
            ? Center(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(service != null
                        ? '账号或后端已变化，请返回重新打开任务中心'
                        : _error ?? '正在打开任务中心…')))
            : Column(children: [
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              '${_tasks.length}/20 个任务 · 原件 ${(_tasks.fold<int>(0, (sum, task) => sum + task.size) / 1048576).toStringAsFixed(1)}/40 MiB\n'
                              '原件和结果仅保存在当前账号本机，需主动删除',
                              style: const TextStyle(fontSize: 12))),
                      FilledButton(
                          onPressed:
                              _busy || !_tasks.any((task) => task.retryable)
                                  ? null
                                  : () => _start(_tasks
                                      .where((task) => task.retryable)
                                      .toList()),
                          child: const Text('开始待处理')),
                    ])),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.all(8), child: Text(_error!)),
                Expanded(
                    child: _tasks.isEmpty
                        ? const Center(child: Text('点击右上角添加图片或 PDF，再确认上传识别'))
                        : RefreshIndicator(
                            onRefresh: _reload,
                            child: ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _tasks.length,
                                itemBuilder: (context, index) {
                                  final task = _tasks[index];
                                  return ListTile(
                                      key: ValueKey(task.id),
                                      leading: Icon(task.pdf
                                          ? Icons.picture_as_pdf_outlined
                                          : Icons.image_outlined),
                                      title: Text(task.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      subtitle: Text(
                                          '${_label(task.state)}${service!.activeId == task.id ? ' · ${service.progress}' : ''}'
                                          '${task.error.isEmpty ? '' : '\n${task.error}'}'),
                                      onTap: _busy || !task.hasResult
                                          ? null
                                          : () => _review(task),
                                      trailing: PopupMenuButton<String>(
                                          enabled: !_busy,
                                          onSelected: (action) =>
                                              action == 'retry'
                                                  ? _start([task])
                                                  : action == 'review'
                                                      ? _review(task)
                                                      : _menu(task, action),
                                          itemBuilder: (_) => [
                                                if (task.retryable)
                                                  const PopupMenuItem(
                                                      value: 'retry',
                                                      child: Text('识别 / 重试')),
                                                if (task.hasResult)
                                                  const PopupMenuItem(
                                                      value: 'review',
                                                      child: Text('核对并编辑文字')),
                                                if (task.state ==
                                                    OcrTaskState
                                                        .completed) ...const [
                                                  PopupMenuItem(
                                                      value: 'copy',
                                                      child: Text('复制校对文字')),
                                                  PopupMenuItem(
                                                      value: 'knowledge',
                                                      child: Text('导入知识库')),
                                                  PopupMenuItem(
                                                      value: 'table',
                                                      child: Text(
                                                          '表格预览 / CSV / Excel')),
                                                  PopupMenuItem(
                                                      value: 'pdf',
                                                      child: Text('导出可搜索 PDF')),
                                                ],
                                                const PopupMenuItem(
                                                    value: 'source',
                                                    child: Text('导出原件副本')),
                                                if (task.state ==
                                                        OcrTaskState.queued ||
                                                    task.state ==
                                                        OcrTaskState.running)
                                                  const PopupMenuItem(
                                                      value: 'cancel',
                                                      child: Text('取消识别')),
                                                const PopupMenuItem(
                                                    value: 'delete',
                                                    child: Text('删除任务与副本')),
                                              ]));
                                }))),
              ]));
  }

  static String _label(OcrTaskState state) => switch (state) {
        OcrTaskState.waiting => '待确认上传',
        OcrTaskState.queued => '等待处理',
        OcrTaskState.running => '正在识别',
        OcrTaskState.review => '识别完成，待校对',
        OcrTaskState.completed => '已保存校对',
        OcrTaskState.failed => '识别失败',
        OcrTaskState.cancelled => '已取消',
        OcrTaskState.interrupted => '上次处理已中断',
      };
}
