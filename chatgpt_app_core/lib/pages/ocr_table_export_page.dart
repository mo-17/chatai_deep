import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../backup/backup_service.dart';
import '../chat/application/creative_file_transfer_gateway.dart';
import '../chat/application/ocr_export.dart';
import '../chat/application/pdf_ocr_result.dart';
import '../dao/ai_catalog_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';

class OcrTableExportPage extends StatefulWidget {
  final String filename;
  final PdfOcrResult result;
  final bool Function() isCurrent;
  const OcrTableExportPage(
      {super.key,
      required this.filename,
      required this.result,
      required this.isCurrent});
  @override
  State<OcrTableExportPage> createState() => _OcrTableExportPageState();
}

class _OcrTableExportPageState extends State<OcrTableExportPage> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    AiCatalogIdentity.changes.addListener(_changed);
    BackendConfig.changes.addListener(_changed);
    BackupService.restoreTick.addListener(_changed);
    try {
      _text.text =
          tableCsv(ocrTableRows(widget.result), safeForSpreadsheet: false);
    } catch (_) {
      _error = '版面无法整理为表格，请先校对文字或减少页数';
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AiCatalogIdentity.changes.removeListener(_changed);
    BackendConfig.changes.removeListener(_changed);
    BackupService.restoreTick.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _save(bool xlsx) async {
    if (_busy || !widget.isCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = parseTableCsv(_text.text);
      if (rows.isEmpty) throw const FormatException('表格没有内容');
      final bytes = xlsx
          ? tableXlsx(rows)
          : Uint8List.fromList(utf8.encode('\uFEFF${tableCsv(rows)}'));
      if (!mounted || !widget.isCurrent()) return;
      final name = widget.filename.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final saved =
          await CreativeFileTransferGateway(maxBytes: 16 * 1024 * 1024)
              .saveBytes(bytes,
                  fileName: '$name.${xlsx ? 'xlsx' : 'csv'}',
                  dialogTitle: '导出校对表格',
                  allowedExtensions: [xlsx ? 'xlsx' : 'csv']);
      if (mounted && widget.isCurrent() && saved.saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('表格已导出')));
      }
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _error =
            error is FormatException ? error.message.toString() : '表格未导出，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('表格预览与导出')),
      body: !widget.isCurrent()
          ? const Center(child: Text('账号或后端已变化，请返回重新打开'))
          : SafeArea(
              child: Column(children: [
              const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                      '下方是根据版面推测的表格草稿，请核对列顺序、合并单元格和数字。每行一条记录，逗号分列；含逗号的文字保留双引号。')),
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                          controller: _text,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: '可编辑表格（CSV）',
                              alignLabelWithHint: true)))),
              if (_error != null)
                Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(spacing: 12, children: [
                    OutlinedButton(
                        onPressed: _busy ? null : () => _save(false),
                        child: const Text('导出 CSV')),
                    FilledButton(
                        onPressed: _busy ? null : () => _save(true),
                        child: const Text('导出 Excel')),
                  ])),
            ])));
}
