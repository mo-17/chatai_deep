import 'dart:io';
import 'ohos_ocr.dart';
import 'pdf_ocr_result.dart';
import 'import_operation.dart';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';

/// 端上 OCR。Android / iOS 使用 ML Kit + pdfx，HarmonyOS 使用 Core Vision + PDF Kit。
/// 其它平台由 [isSupported] 守卫，调用方据此降级提示。
///
/// 图片：直接识别；扫描件 PDF：逐页渲染成图再识别（限 [maxPdfPages] 页）。
class OcrService {
  const OcrService._();

  /// PDF OCR 的最大页数（与 FileProcessor 文本抽取上限对齐）。
  static const int maxPdfPages = 20;

  /// 支持 OCR 的图片扩展名（知识库文件导入据此判断走 OCR 路径）。
  static const List<String> imageExtensions = [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp',
    'heic',
    'heif',
  ];

  /// 当前平台是否有 OCR 原生实现。
  static bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.operatingSystem == 'ohos';

  /// 文本抽取结果是否「像扫描件」需要回退 OCR：空 / 过短 / 抽取器给出的占位提示。
  /// 纯函数，便于单测。
  static bool pdfNeedsOcr(String? extracted) {
    final t = extracted?.trim() ?? '';
    if (t.length < 12) return true;
    return t.contains('未抽取到文本') ||
        t.contains('无可读页面') ||
        t.contains('PDF 解析失败');
  }

  /// 识别单张图片，返回纯文本（无文字时返回空串）。
  static Future<String> recognizeImageFile(String path,
      {ImportCancellation? cancellation}) async {
    cancellation?.check();
    if (Platform.operatingSystem == 'ohos') {
      return const OhosOcr().image(path, cancellation: cancellation);
    }
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final result =
          await recognizer.processImage(InputImage.fromFilePath(path));
      cancellation?.check();
      return result.text.trim();
    } finally {
      await recognizer.close();
    }
  }

  /// 兼容全文接口；需要页码的导入流程使用 [recognizePdfPages]。
  static Future<String> recognizePdf(String path,
          {int maxPages = maxPdfPages}) async =>
      (await recognizePdfPages(path, maxPages: maxPages)).text;

  /// 只识别请求的页，返回列表仍与原 PDF 的页序一致。
  static Future<PdfOcrResult> recognizePdfPages(String path,
      {int maxPages = maxPdfPages,
      List<int>? pageNumbers,
      ImportCancellation? cancellation,
      void Function(int, int)? onProgress}) async {
    cancellation?.check();
    if (maxPages < 1 || maxPages > maxPdfPages) {
      throw RangeError.range(maxPages, 1, maxPdfPages, 'maxPages');
    }
    final selected = pageNumbers?.toSet();
    if (selected != null &&
        (selected.isEmpty ||
            selected.length != pageNumbers!.length ||
            selected.any((page) => page < 1 || page > maxPages))) {
      throw ArgumentError('OCR 页码必须唯一且位于页数预算内');
    }
    if (Platform.operatingSystem == 'ohos') {
      return const OhosOcr().pdfPages(path,
          maxPages: maxPages,
          pageNumbers: pageNumbers,
          cancellation: cancellation,
          onProgress: onProgress);
    }
    final tmp = await Directory.systemTemp.createTemp('kb_ocr');
    TextRecognizer? recognizer;
    PdfDocument? doc;
    try {
      recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
      doc = await PdfDocument.openFile(path);
      final total = doc.pagesCount;
      final count = total < maxPages ? total : maxPages;
      if (total < 1 || (selected?.any((page) => page > count) ?? false)) {
        throw const FormatException('OCR 请求页码超出原 PDF');
      }
      final pages = List<String>.filled(count, '');
      var length = 0;
      for (var i = 1; i <= count; i++) {
        cancellation?.check();
        if (selected != null && !selected.contains(i)) continue;
        final page = await doc.getPage(i);
        try {
          final img = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.png,
          );
          if (img == null) throw FormatException('PDF 第 $i 页渲染失败');
          final file = File('${tmp.path}/p$i.png');
          await file.writeAsBytes(img.bytes);
          final text = await recognizeImageFileWith(recognizer, file.path);
          length += text.length;
          if (length > 1000000) throw const FormatException('OCR 文字超过导入上限');
          cancellation?.check();
          pages[i - 1] = text;
          onProgress?.call(i, count);
        } finally {
          await page.close();
        }
      }
      return PdfOcrResult(totalPages: total, pages: pages);
    } finally {
      try {
        await recognizer?.close();
      } finally {
        try {
          await doc?.close();
        } finally {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        }
      }
    }
  }

  /// 复用同一个 recognizer 识别图片（PDF 多页时避免反复创建/销毁）。
  static Future<String> recognizeImageFileWith(
      TextRecognizer recognizer, String path) async {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text.trim();
  }
}
