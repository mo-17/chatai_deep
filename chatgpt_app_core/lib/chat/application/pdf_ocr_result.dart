import 'dart:convert';
import 'dart:typed_data';

class OcrLine {
  final String text;
  final double? confidence;
  final List<List<double>> box;
  OcrLine(
      {required this.text, this.confidence, List<List<double>> box = const []})
      : box = List.unmodifiable(box.map((p) => List<double>.unmodifiable(p)));
  bool get needsReview => confidence != null && confidence! < .85;
  Map<String, Object?> toJson() => {
        'text': text,
        if (confidence != null) 'confidence': confidence,
        'box': box
      };
}

class OcrPageDetail {
  final int page;
  final double width, height;
  final List<OcrLine> lines;
  final Uint8List? preview;
  OcrPageDetail(
      {required this.page,
      this.width = 0,
      this.height = 0,
      List<OcrLine> lines = const [],
      Uint8List? preview})
      : lines = List.unmodifiable(lines),
        preview = preview == null
            ? null
            : Uint8List.fromList(preview).asUnmodifiableView();
  Map<String, Object?> toJson() => {
        'page': page,
        'width': width,
        'height': height,
        'lines': lines.map((line) => line.toJson()).toList(),
        if (preview != null) 'preview': base64Encode(preview!),
      };
}

/// 每项对应原 PDF 的一页；空白页和未请求的页也保留位置。
class PdfOcrResult {
  final int totalPages;
  final List<String> pages;
  final List<OcrPageDetail> details;

  PdfOcrResult(
      {required this.totalPages,
      required List<String> pages,
      List<OcrPageDetail> details = const []})
      : pages = List.unmodifiable(pages),
        details = List.unmodifiable(details);

  OcrPageDetail? detailFor(int page) {
    for (final detail in details) {
      if (detail.page == page) return detail;
    }
    return null;
  }

  PdfOcrResult corrected(List<String> edited) {
    if (edited.length != pages.length || edited.join().length > 200000) {
      throw const FormatException('校对文字页数或字数超过上限');
    }
    return PdfOcrResult(
        totalPages: totalPages, pages: edited, details: details);
  }

  Map<String, Object?> toJson() => {
        'totalPages': totalPages,
        'pages': [
          for (var i = 0; i < pages.length; i++)
            {
              ...?detailFor(i + 1)?.toJson(),
              'page': i + 1,
              'text': pages[i],
            }
        ]
      };

  /// 服务端及本机持久化结果共用严格边界；旧服务无坐标时仍可读取文字。
  static PdfOcrResult fromJson(Object? value, {Set<int>? expectedPages}) {
    Never invalid() => throw const FormatException('OCR 结果格式无效');
    if (value is! Map || value['totalPages'] is! int || value['pages'] is! List) {
      invalid();
    }
    final total = value['totalPages'] as int;
    final rawPages = value['pages'] as List;
    if (total < 1 || total > 20 || rawPages.length > 20) invalid();
    final pages = List.filled(total, '');
    final received = <int>{};
    final details = <OcrPageDetail>[];
    var characters = 0, lineCount = 0, lineCharacters = 0, previewBytes = 0;
    for (final raw in rawPages) {
      if (raw is! Map || raw['page'] is! int || raw['text'] is! String) {
        invalid();
      }
      final number = raw['page'] as int;
      if (number < 1 || number > total || !received.add(number)) invalid();
      pages[number - 1] = raw['text'] as String;
      characters += pages[number - 1].length;
      if (characters > 200000) invalid();
      double dimension(String key) {
        final n = raw[key];
        if (n == null) return 0;
        if (n is! num || !n.isFinite || n < 0 || n > 20000) invalid();
        return n.toDouble();
      }

      final width = dimension('width'), height = dimension('height');
      final rawLines = raw['lines'] ?? const [];
      if (rawLines is! List) invalid();
      final lines = <OcrLine>[];
      for (final line in rawLines) {
        if (++lineCount > 4000 || line is! Map || line['text'] is! String) {
          invalid();
        }
        lineCharacters += (line['text'] as String).length;
        if (lineCharacters > 200000) invalid();
        final score = line['confidence'];
        if (score != null &&
            (score is! num || !score.isFinite || score < 0 || score > 1)) {
          invalid();
        }
        final points = line['box'] ?? const [];
        if (points is! List || points.length > 4) invalid();
        final box = <List<double>>[];
        for (final point in points) {
          if (point is! List ||
              point.length != 2 ||
              point.any((v) => v is! num || !v.isFinite || v < 0 || v > 20000)) {
            invalid();
          }
          box.add(point.map((v) => (v as num).toDouble()).toList());
        }
        lines.add(OcrLine(
            text: line['text'] as String,
            confidence: (score as num?)?.toDouble(),
            box: box));
      }
      Uint8List? preview;
      final encoded = raw['preview'];
      if (encoded != null) {
        if (encoded is! String || encoded.length > 90 * 1024) invalid();
        preview = base64Decode(encoded);
        previewBytes += preview.length;
        if (preview.length > 64 * 1024 ||
            previewBytes > 1280 * 1024 ||
            preview.length < 3 ||
            preview[0] != 255 ||
            preview[1] != 216 ||
            preview[2] != 255) {
          invalid();
        }
      }
      details.add(OcrPageDetail(
          page: number,
          width: width,
          height: height,
          lines: lines,
          preview: preview));
    }
    final expected = expectedPages ?? {for (var i = 1; i <= total; i++) i};
    if (received.length != expected.length || !received.containsAll(expected)) {
      invalid();
    }
    return PdfOcrResult(totalPages: total, pages: pages, details: details);
  }

  String get text {
    final content = pages.join('\n\n').trim();
    final note = totalPages > pages.length
        ? '[注：原文共 $totalPages 页，仅 OCR 前 ${pages.length} 页]'
        : '';
    return [content, note].where((part) => part.isNotEmpty).join('\n\n');
  }
}
