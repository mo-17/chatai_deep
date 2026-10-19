import 'dart:async';
import 'package:flutter/services.dart';

/// 与壳内 Core Vision / PDF Kit 的窄接口。可独立验证通道合同。
class OhosOcr {
  static const _channel = MethodChannel('com.hzb.flutter_ai/ocr');
  static int _sequence = 0;
  final Duration timeout;
  const OhosOcr({this.timeout = const Duration(minutes: 2)});

  Future<String> image(String path) => _run('image', path, 1);
  Future<String> pdf(String path, {int maxPages = 20}) {
    if (maxPages < 1 || maxPages > 20) {
      throw RangeError.range(maxPages, 1, 20, 'maxPages');
    }
    return _run('pdf', path, maxPages);
  }

  Future<String> _run(String kind, String path, int pages) async {
    if (!path.startsWith('/')) throw ArgumentError('OCR 需要本机文件路径');
    final id = '${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
    try {
      final text = await _channel.invokeMethod<String>('recognize', {
        'id': id,
        'kind': kind,
        'path': path,
        'maxPages': pages,
      }).timeout(timeout);
      if (text == null || text.length > 1000000) {
        throw const FormatException('OCR 返回无效或超限结果');
      }
      return text.trim();
    } on TimeoutException {
      unawaited(_channel
          .invokeMethod<void>('cancel', {'id': id}).catchError((Object _) {}));
      rethrow;
    }
  }
}
