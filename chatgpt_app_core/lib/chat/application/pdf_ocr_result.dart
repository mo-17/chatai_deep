/// 每项对应原 PDF 的一页；空白页和未请求的页也保留位置。
class PdfOcrResult {
  final int totalPages;
  final List<String> pages;

  PdfOcrResult({required this.totalPages, required List<String> pages})
      : pages = List.unmodifiable(pages);

  String get text {
    final content = pages.join('\n\n').trim();
    final note = totalPages > pages.length
        ? '[注：原文共 $totalPages 页，仅 OCR 前 ${pages.length} 页]'
        : '';
    return [content, note].where((part) => part.isNotEmpty).join('\n\n');
  }
}
