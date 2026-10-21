import 'package:login_sdk/platform/app_io.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:login_sdk/dao/backend_host.dart';

class KnowledgePdfPage extends StatefulWidget {
  final KnowledgeEvidence source;
  final String? quote;
  const KnowledgePdfPage({super.key, required this.source, this.quote});
  @override
  State<KnowledgePdfPage> createState() => _KnowledgePdfPageState();
}

class _KnowledgePdfPageState extends State<KnowledgePdfPage> {
  static const _channel = MethodChannel('aipu/knowledge-pdf');
  late final _identity = AiCatalogIdentity.capture();
  Uint8List? _image;
  Size _pageSize = Size.zero;
  List<Rect> _highlights = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final source = widget.source;
      if (source.pageNumber == null) throw const FormatException('该资料未保存真实页码');
      final file = await KnowledgeLibrary.verifiedPdf(source.sourceAsset,
          account: _identity.account ?? 'guest');
      if (!mounted || !_identity.current) return;
      if (file == null) {
        throw const FormatException('本机没有通过摘要校验的PDF原件；可继续查看引文快照');
      }
      if (!Platform.isAndroid &&
          !Platform.isIOS &&
          Platform.operatingSystem != 'ohos') {
        throw const FormatException('本平台暂不支持原件渲染，请查看引文快照');
      }
      final doc = PdfDocument(inputBytes: await file.readAsBytes());
      try {
        final i = source.pageNumber! - 1;
        if (i < 0 || i >= doc.pages.count) {
          throw const FormatException('原件不包含引用页码');
        }
        _pageSize = doc.pages[i].size;
        final quote = widget.quote;
        _highlights = quote == null
            ? []
            : PdfTextExtractor(doc)
                .findText([quote], startPageIndex: i, endPageIndex: i)
                .map((m) => m.bounds)
                .toList();
      } finally {
        doc.dispose();
      }
      if (!mounted || !_identity.current) return;
      final png = await _channel.invokeMethod<Uint8List>('render', {
        'path': file.path,
        'page': source.pageNumber! - 1
      }).timeout(const Duration(seconds: 30));
      if (!mounted || !_identity.current) return;
      if (png == null) throw const FormatException('PDF页面未能渲染');
      setState(() => _image = png);
    } catch (e) {
      if (mounted && _identity.current) {
        setState(() =>
            _error = e is FormatException ? e.message : '原件预览未完成，请查看引文快照');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title:
              Text('${widget.source.title} · 第 ${widget.source.pageNumber} 页')),
      body: ListenableBuilder(
          listenable: Listenable.merge(
              [AiCatalogIdentity.changes, BackendConfig.changes]),
          builder: (_, __) => !_identity.current
              ? const Center(child: Text('账号已变化，请关闭原件'))
              : _error != null
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!)))
                  : _image == null
                      ? const Center(child: CircularProgressIndicator())
                      : Column(children: [
                          if (_highlights.isEmpty)
                            const Padding(
                                padding: EdgeInsets.all(8),
                                child: Text('已定位原始页；未找到可高亮的连续文本，请结合引文快照核对。')),
                          Expanded(
                              child: InteractiveViewer(
                                  maxScale: 6,
                                  child: Center(
                                      child: AspectRatio(
                                          aspectRatio: _pageSize.width /
                                              _pageSize.height,
                                          child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                Image.memory(_image!,
                                                    fit: BoxFit.fill),
                                                LayoutBuilder(
                                                    builder: (_, c) =>
                                                        Stack(children: [
                                                          for (final r
                                                              in _highlights)
                                                            Positioned(
                                                                left: r.left *
                                                                    c.maxWidth /
                                                                    _pageSize
                                                                        .width,
                                                                top: r.top *
                                                                    c
                                                                        .maxHeight /
                                                                    _pageSize
                                                                        .height,
                                                                width: r.width *
                                                                    c.maxWidth /
                                                                    _pageSize
                                                                        .width,
                                                                height: r
                                                                        .height *
                                                                    c
                                                                        .maxHeight /
                                                                    _pageSize
                                                                        .height,
                                                                child: IgnorePointer(
                                                                    child: ColoredBox(
                                                                        color: Colors
                                                                            .amber
                                                                            .withValues(alpha: .35))))
                                                        ])),
                                              ]))))),
                        ])));
}
