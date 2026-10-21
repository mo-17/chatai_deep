import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../chat/application/pdf_ocr_result.dart';
import '../dao/ai_catalog_dao.dart';
import '../backup/backup_service.dart';
import 'package:login_sdk/dao/backend_host.dart';

/// 校对只返回编辑后的页文字；原始行、置信度及坐标保留为核对依据。
class OcrReviewPage extends StatefulWidget {
  final String filename;
  final PdfOcrResult result;
  final Uint8List? imageBytes;
  final bool Function() isCurrent;
  const OcrReviewPage(
      {super.key,
      required this.filename,
      required this.result,
      required this.isCurrent,
      this.imageBytes});
  @override
  State<OcrReviewPage> createState() => _OcrReviewPageState();
}

class _OcrReviewPageState extends State<OcrReviewPage> {
  late final List<String> _pages = [...widget.result.pages];
  late final TextEditingController _text =
      TextEditingController(text: _pages.first);
  int _page = 0;
  OcrLine? _selected;
  String? _error;
  @override
  void initState() {
    super.initState();
    AiCatalogIdentity.changes.addListener(_changed);
    BackendConfig.changes.addListener(_changed);
    BackupService.restoreTick.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _store() => _pages[_page] = _text.text;
  void _switch(int page) {
    _store();
    setState(() {
      _page = page;
      _text.text = _pages[_page];
      _selected = null;
      _error = null;
    });
  }

  void _save() {
    if (!widget.isCurrent()) {
      setState(() => _error = '账号或后端已变化，请返回重新打开');
      return;
    }
    _store();
    try {
      Navigator.pop(context, widget.result.corrected(_pages));
    } on FormatException catch (error) {
      setState(() => _error = error.message.toString());
    }
  }

  @override
  void dispose() {
    AiCatalogIdentity.changes.removeListener(_changed);
    BackendConfig.changes.removeListener(_changed);
    BackupService.restoreTick.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isCurrent()) {
      return Scaffold(
          appBar: AppBar(title: const Text('校对已暂停')),
          body: const Center(child: Text('账号或后端已变化，请返回重新打开')));
    }
    final detail = widget.result.detailFor(_page + 1);
    final low =
        detail?.lines.where((line) => line.needsReview).toList() ?? <OcrLine>[];
    return Scaffold(
        appBar: AppBar(
            title: Text('校对 · ${widget.filename}',
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                IconButton(
                    tooltip: '上一页',
                    onPressed: _page == 0 ? null : () => _switch(_page - 1),
                    icon: const Icon(Icons.chevron_left)),
                Text('第 ${_page + 1}/${_pages.length} 页'),
                IconButton(
                    tooltip: '下一页',
                    onPressed: _page + 1 == _pages.length
                        ? null
                        : () => _switch(_page + 1),
                    icon: const Icon(Icons.chevron_right)),
                const Spacer(),
                TextButton(
                    onPressed: () =>
                        setState(() => _text.text = widget.result.pages[_page]),
                    child: const Text('还原本页')),
              ])),
          if (low.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        icon: const Icon(Icons.warning_amber),
                        label: Text('${low.length} 行置信度偏低，点击核对'),
                        onPressed: () => _showLines(low)))),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('置信度仅供定位易错文字，不代表内容正确率。保存后才会使用校对文字。',
                  style: TextStyle(fontSize: 12))),
          Expanded(child: LayoutBuilder(builder: (context, size) {
            final preview = _preview(detail);
            final editor = Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  key: const ValueKey('ocr-page-text'),
                  controller: _text,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                      labelText: '本页文字',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder()),
                ));
            return size.maxWidth >= 760
                ? Row(children: [
                    Expanded(child: preview),
                    Expanded(child: editor)
                  ])
                : Column(children: [
                    Expanded(flex: 3, child: preview),
                    Expanded(flex: 4, child: editor)
                  ]);
          })),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Expanded(
                    child:
                        Text('修改仅保存在当前账号本机', style: TextStyle(fontSize: 12))),
                FilledButton.icon(
                    onPressed: widget.isCurrent() ? _save : null,
                    icon: const Icon(Icons.check),
                    label: const Text('保存校对')),
              ])),
        ])));
  }

  Widget _preview(OcrPageDetail? detail) {
    final bytes = detail?.preview ?? widget.imageBytes;
    if (bytes == null) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('此任务未包含页图预览，可导出原件后对照核对。新任务将请求页图。')));
    }
    final aspect = detail != null && detail.width > 0 && detail.height > 0
        ? detail.width / detail.height
        : 1.0;
    return Padding(
        padding: const EdgeInsets.all(12),
        child: InteractiveViewer(
            maxScale: 6,
            child: Center(
                child: AspectRatio(
                    aspectRatio: aspect,
                    child: Stack(fit: StackFit.expand, children: [
                      Image.memory(bytes,
                          key: ValueKey(_page),
                          fit: BoxFit.contain,
                          cacheWidth: 1200,
                          errorBuilder: (_, __, ___) =>
                              const Center(child: Text('页图无法显示，可导出原件核对'))),
                      if (_selected?.box.length == 4 &&
                          detail != null &&
                          detail.width > 0 &&
                          detail.height > 0)
                        IgnorePointer(
                            child: CustomPaint(
                                painter: _OcrLinePainter(_selected!, detail))),
                    ])))));
  }

  Future<void> _showLines(List<OcrLine> lines) async {
    final selected = await showModalBottomSheet<OcrLine>(
        context: context,
        builder: (context) => SafeArea(
            child: ListView.builder(
                itemCount: lines.length,
                itemBuilder: (context, index) => ListTile(
                    title: Text(lines[index].text),
                    subtitle: Text(
                        '识别置信度 ${(lines[index].confidence! * 100).round()}%'),
                    onTap: () => Navigator.pop(context, lines[index])))));
    if (!mounted || selected == null || !widget.isCurrent()) return;
    setState(() => _selected = selected);
    final start = _text.text.indexOf(selected.text);
    if (start >= 0) {
      _text.selection = TextSelection(
          baseOffset: start, extentOffset: start + selected.text.length);
    }
  }
}

class _OcrLinePainter extends CustomPainter {
  final OcrLine line;
  final OcrPageDetail page;
  _OcrLinePainter(this.line, this.page);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (var i = 0; i < line.box.length; i++) {
      final x = (line.box[i][0] / page.width).clamp(0.0, 1.0) * size.width;
      final y = (line.box[i][1] / page.height).clamp(0.0, 1.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = Colors.amber.withValues(alpha: .35));
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.deepOrange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _OcrLinePainter oldDelegate) =>
      oldDelegate.line != line || oldDelegate.page != page;
}
