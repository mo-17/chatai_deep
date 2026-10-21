import 'dart:io' as native;
import 'dart:convert';
import 'package:chatgpt_app_core/platform/zlib_decoder_web.dart' as browser;
import 'package:flutter_test/flutter_test.dart';

class _Bounded implements Sink<List<int>> {
  _Bounded(this.limit);
  final int limit;
  int count = 0;
  @override
  void add(List<int> bytes) {
    count += bytes.length;
    if (count > limit) throw const FormatException('超过解压预算');
  }

  @override
  void close() {}
}

void main() {
  for (final raw in [false, true]) {
    test('浏览器纯 Dart inflater 兼容 native zlib raw=$raw', () {
      final text = utf8.encode(List.filled(300, '中文正文abc').join());
      final compressed = native.ZLibEncoder(raw: raw).convert(text);
      expect(browser.ZLibDecoder(raw: raw).convert(compressed), text);
    });
    test('浏览器 inflater 在预算处中止而非先解压完整压缩炸弹 raw=$raw', () {
      final compressed = native.ZLibEncoder(raw: raw)
          .convert(List.filled(8 * 1024 * 1024, 65));
      final sink = _Bounded(1024);
      final decoder =
          browser.ZLibDecoder(raw: raw).startChunkedConversion(sink);
      decoder.add(compressed);
      expect(decoder.close, throwsFormatException);
      expect(sink.count, lessThan(1400));
    });
  }
}
