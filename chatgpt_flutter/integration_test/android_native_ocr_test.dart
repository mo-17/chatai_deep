// 真机测试真实 ML Kit/pdfx 通道，不使用 OCR mock 或服务器。
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/document_scan.dart';
import 'package:chatgpt_app_core/chat/application/ocr_export.dart';
import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as pdf;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android 原生中文图片与扫描 PDF OCR', (tester) async {
    expect(Platform.isAndroid, isTrue, reason: '请在 Android 设备上运行');
    expect(OcrService.isSupported, isTrue);

    await tester.runAsync(() async {
      final root = await getTemporaryDirectory();
      final existingOcrDirectories = root
          .listSync()
          .where(
              (entry) => entry is Directory && entry.path.contains('/kb_ocr'))
          .map((entry) => entry.path)
          .toSet();
      final directory = await root.createTemp('android_native_ocr_');
      try {
        final first = await _fixture('中文识别测试', 'ANDROID OCR 2026');
        final second = await _fixture('第二页验证', 'PAGE TWO 12345');
        final image = await File('${directory.path}/sample.png')
            .writeAsBytes(first, flush: true);
        final imageText = await OcrService.recognizeImageFile(image.path);
        debugPrint('Android image OCR fixture: $imageText');
        // ML Kit 可能将「别」输出为异体字「別」；只在夹具断言中接受这两种字形。
        // 产品返回值保持原样，避免改写用户原文中的繁体字。
        final firstPageText = anyOf(contains('中文识别测试'), contains('中文识別测试'));
        expect(_compact(imageText), firstPageText);
        expect(_compact(imageText), contains('ANDROIDOCR2026'));

        final bytes = await scannedPagesPdf([first, second]);
        final document = pdf.PdfDocument(inputBytes: bytes);
        try {
          expect(document.pages.count, 2);
          for (var i = 0; i < document.pages.count; i++) {
            expect(document.pages[i].size, const Size(1200, 360));
          }
          expect(pdf.PdfTextExtractor(document).extractText().trim(), isEmpty,
              reason: '扫描 PDF 不能依靠已有文字层通过测试');
        } finally {
          document.dispose();
        }
        final scan = await File('${directory.path}/scan.pdf')
            .writeAsBytes(bytes, flush: true);
        final progress = <int>[];
        final result = await OcrService.recognizePdfPages(scan.path,
            onProgress: (page, total) {
          expect(total, 2);
          progress.add(page);
        });
        expect(result.totalPages, 2);
        expect(result.pages, hasLength(2));
        debugPrint('Android scanned PDF OCR fixtures: ${result.pages}');
        expect(_compact(result.pages[0]), firstPageText);
        expect(_compact(result.pages[1]), contains('第二页验证'));
        expect(_compact(result.pages[1]), contains('PAGETWO12345'));
        expect(progress, [1, 2]);

        final selected =
            await OcrService.recognizePdfPages(scan.path, pageNumbers: [2]);
        expect(selected.pages[0], isEmpty);
        expect(_compact(selected.pages[1]), contains('第二页验证'));

        final searchableBytes = await searchableOcrPdf(
            source: first,
            pdf: false,
            result: PdfOcrResult(totalPages: 1, pages: ['校对后的文字']));
        final searchableDocument = pdf.PdfDocument(inputBytes: searchableBytes);
        try {
          expect(searchableDocument.pages[0].size, const Size(1200, 360));
          expect(pdf.PdfTextExtractor(searchableDocument).extractText(),
              contains('校对后的文字'));
        } finally {
          searchableDocument.dispose();
        }
        final searchable = await File('${directory.path}/searchable.pdf')
            .writeAsBytes(searchableBytes, flush: true);
        // 再经原生栅格化识别，确认可见原图未被裁剪；不能依靠隐藏文字层通过。
        final visible = await OcrService.recognizePdfPages(searchable.path);
        expect(_compact(visible.pages.single), firstPageText);
        expect(_compact(visible.pages.single), contains('ANDROIDOCR2026'));
        // 连续调用也要释放 PDF 页、识别器和临时目录。
        final remaining = root.listSync().where((entry) =>
            entry is Directory &&
            entry.path.contains('/kb_ocr') &&
            !existingOcrDirectories.contains(entry.path));
        expect(remaining, isEmpty);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String _compact(String text) => text.replaceAll(RegExp(r'\s+'), '');

Future<Uint8List> _fixture(String chinese, String english) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  final text = TextPainter(
    text: TextSpan(
      text: '$chinese\n$english',
      style: const TextStyle(
          color: Colors.black,
          fontSize: 64,
          height: 1.8,
          fontFamily: 'sans-serif'),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 1100);
  text.paint(canvas, const Offset(50, 40));
  text.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(1200, 360);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
