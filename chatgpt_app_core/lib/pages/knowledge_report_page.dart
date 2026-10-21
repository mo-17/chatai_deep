import 'package:login_sdk/platform/app_io.dart';
import 'package:chatgpt_app_core/chat/application/creative_file_transfer_gateway.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_report.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chatgpt_app_core/platform/app_paths.dart';
import 'package:share_plus/share_plus.dart';

class KnowledgeReportPage extends StatefulWidget {
  final List<KnowledgeAnswer> answers;
  const KnowledgeReportPage({super.key, required this.answers});
  @override
  State<KnowledgeReportPage> createState() => _KnowledgeReportPageState();
}

class _KnowledgeReportPageState extends State<KnowledgeReportPage> {
  final _title = TextEditingController(text: '我的资料报告');
  late final _identity = AiCatalogIdentity.capture();
  final _selected = <int>{};
  KnowledgeReportKind _kind = KnowledgeReportKind.report;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _selected.addAll(List.generate(widget.answers.length, (i) => i));
  }

  Future<void> _export(bool pdf) async {
    if (_busy || !_identity.current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    File? temporary;
    try {
      final report = KnowledgeReport(
          title: _title.text.trim().isEmpty ? '资料报告' : _title.text.trim(),
          kind: _kind,
          answers: [for (final i in _selected) widget.answers[i]]);
      final bytes = pdf ? await report.pdf() : report.docx();
      if (!mounted || !_identity.current) return;
      if (Platform.operatingSystem == 'ohos') {
        final saved = await CreativeFileTransferGateway(
          maxBytes: 256 * 1024 * 1024,
        ).saveBytes(bytes,
            fileName: '资料报告.${pdf ? 'pdf' : 'docx'}',
            allowedExtensions: [pdf ? 'pdf' : 'docx']);
        if (saved.saved && mounted && _identity.current) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已保存报告')));
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = appFile(
          '${dir.path}/aipu-report-${DateTime.now().microsecondsSinceEpoch}.${pdf ? 'pdf' : 'docx'}');
      temporary = file;
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted || !_identity.current) {
        await file.delete();
        return;
      }
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path)],
          sharePositionOrigin:
              box == null ? null : box.localToGlobal(Offset.zero) & box.size));
    } catch (_) {
      if (mounted) setState(() => _error = '导出未完成，请选择已核验回答并重试');
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {/* 系统临时目录后续回收。 */}
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    if (!_identity.current) return;
    try {
      final report = KnowledgeReport(
          title: _title.text.trim(),
          kind: _kind,
          answers: [for (final i in _selected) widget.answers[i]]);
      await Clipboard.setData(ClipboardData(text: report.text));
    } catch (_) {
      if (mounted) setState(() => _error = '请先选择已核验的回答');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('带引用的成果导出')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: _title,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '标题')),
        DropdownButtonFormField<KnowledgeReportKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: '成果类型'),
            items: const [
              DropdownMenuItem(
                  value: KnowledgeReportKind.report, child: Text('资料整理报告')),
              DropdownMenuItem(
                  value: KnowledgeReportKind.comparison, child: Text('资料观点对比')),
              DropdownMenuItem(
                  value: KnowledgeReportKind.studyNotes, child: Text('学习笔记'))
            ],
            onChanged: _busy ? null : (v) => setState(() => _kind = v!)),
        const Text('仅导出核验通过的结论及原文快照；不会额外调用模型或替你判定事实。'),
        for (var i = 0; i < widget.answers.length; i++)
          CheckboxListTile(
              value: _selected.contains(i),
              title: Text(widget.answers[i].question),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        if (v == true) {
                          _selected.add(i);
                        } else {
                          _selected.remove(i);
                        }
                      })),
        if (_error != null) Text(_error!),
        Wrap(spacing: 12, children: [
          FilledButton(
              onPressed: _busy ? null : () => _export(false),
              child: const Text('导出 Word')),
          FilledButton(
              onPressed: _busy ? null : () => _export(true),
              child: const Text('导出 PDF')),
          OutlinedButton(
              onPressed: _busy ? null : _copy, child: const Text('复制带引用的文本')),
        ]),
        if (_busy) const LinearProgressIndicator(),
      ]));
  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }
}
