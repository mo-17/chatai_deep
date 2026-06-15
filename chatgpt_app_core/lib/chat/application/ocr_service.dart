import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:pdfx/pdfx.dart';

/// 端上 OCR（L4a 增强）。基于 Google ML Kit 文字识别（中文脚本）+ pdfx 栅格化。
///
/// **仅 Android / iOS 有原生实现**——其它平台（桌面 / HarmonyOS / web）由
/// [isSupported] 守卫，调用方据此降级提示，不触发原生方法。
///
/// 图片：直接识别；扫描件 PDF：逐页渲染成图再识别（限 [maxPdfPages] 页）。
class OcrService {
  const OcrService._();

  /// PDF OCR 的最大页数（与 FileProcessor 文本抽取上限对齐）。
  static const int maxPdfPages = 20;

  /// 支持 OCR 的图片扩展名（知识库文件导入据此判断走 OCR 路径）。
  static const List<String> imageExtensions = [
    'png', 'jpg', 'jpeg', 'webp', 'bmp', 'heic', 'heif',
  ];

  /// 当前平台是否有 OCR 原生实现。
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

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
  static Future<String> recognizeImageFile(String path) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final result =
          await recognizer.processImage(InputImage.fromFilePath(path));
      return result.text.trim();
    } finally {
      await recognizer.close();
    }
  }

  /// 逐页渲染 PDF 为图片并 OCR，拼成全文（限 [maxPages] 页）。
  static Future<String> recognizePdf(String path,
      {int maxPages = maxPdfPages}) async {
    final tmp = await Directory.systemTemp.createTemp('kb_ocr');
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    final doc = await PdfDocument.openFile(path);
    final buf = StringBuffer();
    try {
      final total = doc.pagesCount;
      final count = total < maxPages ? total : maxPages;
      for (var i = 1; i <= count; i++) {
        final page = await doc.getPage(i);
        try {
          // 2x 渲染提升识别率。
          final img = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.png,
          );
          if (img == null) continue;
          final f = File('${tmp.path}/p$i.png');
          await f.writeAsBytes(img.bytes);
          final text = await recognizeImageFileWith(recognizer, f.path);
          if (text.isNotEmpty) buf..writeln(text)..writeln();
        } catch (e) {
          AILogger.log('ocr page $i failed: $e');
        } finally {
          await page.close();
        }
      }
      if (total > maxPages) {
        buf.writeln('[注：原文共 $total 页，仅 OCR 前 $maxPages 页]');
      }
      return buf.toString().trim();
    } finally {
      await recognizer.close();
      await doc.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 复用同一个 recognizer 识别图片（PDF 多页时避免反复创建/销毁）。
  static Future<String> recognizeImageFileWith(
      TextRecognizer recognizer, String path) async {
    final result =
        await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text.trim();
  }
}
