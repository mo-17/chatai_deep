import 'dart:async';
import 'package:flutter/services.dart';
import 'pdf_ocr_result.dart';
import 'import_operation.dart';

/// 与壳内 Core Vision / PDF Kit 的窄接口。可独立验证通道合同。
class OhosOcr {
  static const _channel = MethodChannel('com.hzb.flutter_ai/ocr');
  static int _sequence = 0;
  static final _progress = <String, void Function(int, int)>{};
  static bool _listening = false;
  static void _listenProgress() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (call.method != 'progress' || args is! Map) return;
      final page = args['page'], total = args['total'];
      if (page is int &&
          total is int &&
          page > 0 &&
          page <= total &&
          total <= 20) {
        _progress[args['id']]?.call(page, total);
      }
    });
  }

  final Duration timeout;
  const OhosOcr({this.timeout = const Duration(minutes: 2)});

  Future<String> image(String path, {ImportCancellation? cancellation}) =>
      _run('image', path, 1, cancellation: cancellation);
  Future<String> pdf(String path, {int maxPages = 20}) {
    if (maxPages < 1 || maxPages > 20) {
      throw RangeError.range(maxPages, 1, 20, 'maxPages');
    }
    return _run('pdf', path, maxPages);
  }

  Future<PdfOcrResult> pdfPages(String path,
      {int maxPages = 20,
      List<int>? pageNumbers,
      ImportCancellation? cancellation,
      void Function(int, int)? onProgress}) async {
    if (maxPages < 1 || maxPages > 20) {
      throw RangeError.range(maxPages, 1, 20, 'maxPages');
    }
    final selected = pageNumbers?.toSet();
    if (selected != null &&
        (selected.isEmpty ||
            selected.length != pageNumbers!.length ||
            selected.any((page) => page < 1 || page > maxPages))) {
      throw ArgumentError('OCR 页码必须唯一且位于页数预算内');
    }
    final value = await _request('pdfPages', path, maxPages,
        pageNumbers: pageNumbers,
        cancellation: cancellation,
        onProgress: onProgress);
    if (value is! Map ||
        value['totalPages'] is! int ||
        value['pages'] is! List) {
      throw const FormatException('OCR 返回无效分页结果');
    }
    final total = value['totalPages'] as int;
    final raw = value['pages'] as List;
    final count = total < maxPages ? total : maxPages;
    if (total < 1 ||
        raw.length != count ||
        raw.any((page) => page is! String) ||
        (selected?.any((page) => page > count) ?? false)) {
      throw const FormatException('OCR 返回无效页数或正文');
    }
    final pages = raw.cast<String>();
    if (pages.fold<int>(0, (n, page) => n + page.length) > 1000000 ||
        (selected != null &&
            pages.asMap().entries.any((entry) =>
                !selected.contains(entry.key + 1) && entry.value.isNotEmpty))) {
      throw const FormatException('OCR 返回超限或未请求的页面');
    }
    return PdfOcrResult(
        totalPages: total, pages: pages.map((page) => page.trim()).toList());
  }

  Future<String> _run(String kind, String path, int pages,
      {ImportCancellation? cancellation}) async {
    final text = await _request(kind, path, pages, cancellation: cancellation);
    if (text is! String || text.length > 1000000) {
      throw const FormatException('OCR 返回无效或超限结果');
    }
    return text.trim();
  }

  Future<Object?> _request(String kind, String path, int pages,
      {List<int>? pageNumbers,
      ImportCancellation? cancellation,
      void Function(int, int)? onProgress}) async {
    if (!path.startsWith('/')) throw ArgumentError('OCR 需要本机文件路径');
    cancellation?.check();
    final id = '${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
    if (onProgress != null) {
      _listenProgress();
      _progress[id] = onProgress;
    }
    final stopListening = cancellation?.listen(() => cancelNativeRequest(
        () => _channel.invokeMethod<void>('cancel', {'id': id})));
    try {
      final result = await _channel.invokeMethod<Object?>('recognize', {
        'id': id,
        'kind': kind,
        'path': path,
        'maxPages': pages,
        if (pageNumbers != null) 'pageNumbers': pageNumbers,
        if (onProgress != null) 'reportProgress': true,
      }).timeout(timeout);
      cancellation?.check();
      return result;
    } on TimeoutException {
      unawaited(_channel
          .invokeMethod<void>('cancel', {'id': id}).catchError((Object _) {}));
      cancellation?.check();
      rethrow;
    } catch (_) {
      cancellation?.check();
      rethrow;
    } finally {
      stopListening?.call();
      _progress.remove(id);
    }
  }
}
