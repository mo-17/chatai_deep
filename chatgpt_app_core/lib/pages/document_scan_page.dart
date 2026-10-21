import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../chat/application/document_scan.dart';
import '../chat/application/ocr_task_center.dart';
import '../backup/backup_service.dart';
import '../dao/ai_catalog_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';

class DocumentScanPage extends StatefulWidget {
  final OcrTaskCenter service;
  const DocumentScanPage({super.key, required this.service});
  @override
  State<DocumentScanPage> createState() => _DocumentScanPageState();
}

class _DocumentScanPageState extends State<DocumentScanPage> {
  final _pages = <Uint8List>[];
  Uint8List? _preview;
  double _aspect = 1;
  List<List<double>> _corners = [
    [.04, .04],
    [.96, .04],
    [.96, .96],
    [.04, .96]
  ];
  bool _busy = false;
  String? _error;
  bool get _current => mounted && widget.service.current;
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

  @override
  void dispose() {
    AiCatalogIdentity.changes.removeListener(_changed);
    BackendConfig.changes.removeListener(_changed);
    BackupService.restoreTick.removeListener(_changed);
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (_current) {
        setState(() => _error = error is FormatException
            ? error.message.toString()
            : '照片未处理完成，请检查相机/相册权限，或从文件入口添加图片');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(ImageSource source) => _action(() async {
        if (_pages.length >= 20) throw const FormatException('最多扫描 20 页');
        final photo = await ImagePicker().pickImage(
            source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
        if (photo == null || !_current) return;
        if (await photo.length() > 8 * 1024 * 1024) {
          throw const FormatException('照片超过 8 MiB，请缩小后重试');
        }
        final bytes = await photo.readAsBytes();
        if (!_current) return;
        final preview = await compute(prepareScanPreview, bytes);
        if (!_current) return;
        final codec = await ui.instantiateImageCodec(preview);
        try {
          final frame = await codec.getNextFrame();
          try {
            if (_current) {
              setState(() {
                _preview = preview;
                _aspect = frame.image.width / frame.image.height;
                _corners = [
                  [.04, .04],
                  [.96, .04],
                  [.96, .96],
                  [.04, .96]
                ];
              });
            }
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      });
  Future<void> _acceptPage() => _action(() async {
        final preview = _preview;
        if (preview == null) return;
        final output =
            await compute(rectifyScan, {'bytes': preview, 'corners': _corners});
        if (_current) {
          setState(() {
            _pages.add(output);
            _preview = null;
          });
        }
      });
  Future<void> _save() => _action(() async {
        final pdf = await scannedPagesPdf(List.unmodifiable(_pages));
        if (!_current) return;
        await widget.service
            .add('扫描资料_${DateTime.now().millisecondsSinceEpoch}.pdf', pdf);
        if (mounted && _current) Navigator.pop(context, true);
      });
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('拍照扫描')),
      body: !_current
          ? const Center(child: Text('账号或后端已变化，请返回重新打开'))
          : SafeArea(
              child: Column(children: [
              const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('照片在本机裁边和透视校正。保存为待处理任务后，需再次确认才上传 OCR。')),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                  child: _preview != null
                      ? _crop()
                      : _pages.isEmpty
                          ? const Center(child: Text('拍摄或从相册选择资料照片'))
                          : ListView.builder(
                              itemCount: _pages.length,
                              itemBuilder: (context, index) => ListTile(
                                  leading: Image.memory(_pages[index],
                                      width: 56,
                                      height: 64,
                                      fit: BoxFit.contain,
                                      cacheWidth: 112),
                                  title: Text('第 ${index + 1} 页'),
                                  subtitle: Text(
                                      '${(_pages[index].length / 1024).round()} KiB'),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                            tooltip: '上移',
                                            onPressed: _busy || index == 0
                                                ? null
                                                : () => setState(() {
                                                      final page = _pages
                                                          .removeAt(index);
                                                      _pages.insert(
                                                          index - 1, page);
                                                    }),
                                            icon:
                                                const Icon(Icons.arrow_upward)),
                                        IconButton(
                                            tooltip: '删除页',
                                            onPressed: _busy
                                                ? null
                                                : () => setState(() =>
                                                    _pages.removeAt(index)),
                                            icon: const Icon(
                                                Icons.delete_outline)),
                                      ])))),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (_preview == null) ...[
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _choose(ImageSource.camera),
                              icon: const Icon(Icons.photo_camera_outlined),
                              label: const Text('拍照')),
                          OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _choose(ImageSource.gallery),
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('从相册选择')),
                          FilledButton(
                              onPressed: _busy || _pages.isEmpty ? null : _save,
                              child: Text('保存 ${_pages.length} 页到任务中心')),
                        ] else ...[
                          TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() => _preview = null),
                              child: const Text('放弃本张')),
                          FilledButton(
                              onPressed: _busy ? null : _acceptPage,
                              child: const Text('裁边校正并添加本页')),
                        ],
                      ])),
            ])));
  Widget _crop() => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        const Text('拖动四个圆点对齐纸张边角'),
        const SizedBox(height: 12),
        Expanded(
            child: Center(
                child: AspectRatio(
                    aspectRatio: _aspect,
                    child: LayoutBuilder(
                        builder: (context, size) =>
                            Stack(fit: StackFit.expand, children: [
                              Image.memory(_preview!, fit: BoxFit.fill),
                              IgnorePointer(
                                  child: CustomPaint(
                                      painter: _ScanCorners(_corners))),
                              for (var i = 0; i < 4; i++)
                                Positioned(
                                    left: _corners[i][0] * size.maxWidth - 18,
                                    top: _corners[i][1] * size.maxHeight - 18,
                                    child: Semantics(
                                        label: const [
                                          '左上角',
                                          '右上角',
                                          '右下角',
                                          '左下角'
                                        ][i],
                                        child: GestureDetector(
                                            onPanUpdate: _busy
                                                ? null
                                                : (event) => setState(() {
                                                      _corners = [
                                                        ..._corners
                                                            .map((p) => [...p])
                                                      ];
                                                      _corners[i] = [
                                                        (_corners[i][0] +
                                                                event.delta.dx /
                                                                    size.maxWidth)
                                                            .clamp(0.0, 1.0),
                                                        (_corners[i][1] +
                                                                event.delta.dy /
                                                                    size.maxHeight)
                                                            .clamp(0.0, 1.0)
                                                      ];
                                                    }),
                                            child: Container(
                                                width: 36,
                                                height: 36,
                                                decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                                    border: Border.all(
                                                        color: Colors.white,
                                                        width: 2),
                                                    shape: BoxShape.circle))))),
                            ]))))),
      ]));
}

class _ScanCorners extends CustomPainter {
  final List<List<double>> points;
  _ScanCorners(this.points);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(points[0][0] * size.width, points[0][1] * size.height);
    for (final p in points.skip(1)) {
      path.lineTo(p[0] * size.width, p[1] * size.height);
    }
    path.close();
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _ScanCorners oldDelegate) =>
      oldDelegate.points != points;
}
