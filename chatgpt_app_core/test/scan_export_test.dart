import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/document_scan.dart';
import 'package:chatgpt_app_core/chat/application/ocr_export.dart';
import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List photo() {
    final image = img.Image(width: 160, height: 120, numChannels: 3);
    for (var y = 0; y < 120; y++) {
      for (var x = 0; x < 160; x++) {
        if (y < 60) {
          image.setPixelRgb(x, y, x < 80 ? 255 : 0, x < 80 ? 0 : 255, 0);
        } else {
          image.setPixelRgb(
              x, y, x < 80 ? 255 : 0, x < 80 ? 255 : 0, x < 80 ? 0 : 255);
        }
      }
    }
    return img.encodePng(image);
  }

  test('四角透视校正保持角点内容并输出有界 JPEG', () {
    final preview = prepareScanPreview(photo());
    final bytes = rectifyScan({
      'bytes': preview,
      'corners': [
        [.1, .1],
        [.85, .15],
        [.9, .9],
        [.15, .85]
      ]
    });
    expect(bytes.length, lessThanOrEqualTo(320 * 1024));
    final decoded = img.decodeJpg(bytes)!;
    final left = decoded.getPixel(2, 2),
        right = decoded.getPixel(decoded.width - 3, 2),
        bottom = decoded.getPixel(decoded.width - 3, decoded.height - 3);
    expect(left.r, greaterThan(left.g + 100));
    expect(right.g, greaterThan(right.r + 100));
    expect(bottom.b, greaterThan(bottom.r + 100));
    expect(mathMax(decoded.width, decoded.height), lessThanOrEqualTo(1600));
  });
  test('拒绝交叉、重叠或越界的扫描角点', () {
    for (final points in [
      [
        [0.0, 0.0],
        [1.0, 1.0],
        [1.0, 0.0],
        [0.0, 1.0]
      ],
      [
        [0.0, 0.0],
        [0.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0]
      ],
      [
        [-.1, 0.0],
        [1.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0]
      ],
    ]) {
      expect(() => validateScanCorners(points), throwsFormatException);
    }
    expect(() => prepareScanPreview(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });
  test('扫描照片合成为真实多页 PDF，不携带已有文字层', () async {
    final page = rectifyScan({
      'bytes': prepareScanPreview(photo()),
      'corners': [
        [0.0, 0.0],
        [1.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0]
      ]
    });
    final bytes = await scannedPagesPdf([page, page]);
    final doc = PdfDocument(inputBytes: bytes);
    try {
      expect(doc.pages.count, 2);
      expect(PdfTextExtractor(doc).extractText().trim(), isEmpty);
    } finally {
      doc.dispose();
    }
    await expectLater(scannedPagesPdf([]), throwsFormatException);
  });
  test('扫描 PDF 保留横页、竖页和方形页的完整尺寸', () async {
    const sizes = [Size(1200, 360), Size(360, 1200), Size(400, 400)];
    final pages = sizes
        .map((size) => img.encodePng(img.Image(
            width: size.width.toInt(),
            height: size.height.toInt(),
            numChannels: 3)))
        .toList();
    final doc = PdfDocument(inputBytes: await scannedPagesPdf(pages));
    try {
      expect(doc.pages.count, sizes.length);
      for (var i = 0; i < sizes.length; i++) {
        expect(doc.pages[i].size, sizes[i], reason: '第 ${i + 1} 页不得交换宽高裁剪图片');
      }
    } finally {
      doc.dispose();
    }
  });
  test('校对文字写入可搜索 PDF，保留原页数与中文', () async {
    final page = rectifyScan({
      'bytes': prepareScanPreview(photo()),
      'corners': [
        [0.0, 0.0],
        [1.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0]
      ]
    });
    final source = await scannedPagesPdf([page, page]);
    final output = await searchableOcrPdf(
        source: source,
        pdf: true,
        result:
            PdfOcrResult(totalPages: 2, pages: ['中文校对 HELLO', '第二页 WORLD']));
    final doc = PdfDocument(inputBytes: output);
    try {
      expect(doc.pages.count, 2);
      final text = PdfTextExtractor(doc).extractText();
      expect(text, contains('中文校对'));
      expect(text, contains('HELLO'));
      expect(text, contains('WORLD'));
    } finally {
      doc.dispose();
    }
  });
  test('单图可搜索 PDF 保留横页、竖页和方形页的完整尺寸', () async {
    for (final size in const [
      Size(1200, 360),
      Size(360, 1200),
      Size(400, 400)
    ]) {
      final source = img.encodePng(img.Image(
          width: size.width.toInt(),
          height: size.height.toInt(),
          numChannels: 3));
      final bytes = await searchableOcrPdf(
          source: source,
          pdf: false,
          result: PdfOcrResult(totalPages: 1, pages: ['中文校对 HELLO']));
      final doc = PdfDocument(inputBytes: bytes);
      try {
        expect(doc.pages.count, 1);
        expect(doc.pages[0].size, size);
        expect(PdfTextExtractor(doc).extractText(), contains('中文校对'));
      } finally {
        doc.dispose();
      }
    }
  });
  test('CSV 支持逗号、引号和多行单元格，导出时保护公式样式文本', () {
    final rows = [
      ['标题', '多行\n正文', 'a,b', '含"引号"'],
      ['=cmd', '+1', '-10', '@value']
    ];
    final preview = tableCsv(rows, safeForSpreadsheet: false);
    expect(parseTableCsv(preview), rows);
    final safe = parseTableCsv(tableCsv(rows));
    expect(safe.last, ["'=cmd", "'+1", "'-10", "'@value"]);
    expect(() => parseTableCsv('"unclosed'), throwsFormatException);
  });
  test('BMP 图片可导出搜索 PDF，Excel 拒绝超限或非法字符', () async {
    final source = img.encodeBmp(img.decodePng(photo())!);
    final bytes = await searchableOcrPdf(
        source: source,
        pdf: false,
        result: PdfOcrResult(totalPages: 1, pages: ['BMP 资料']));
    final document = PdfDocument(inputBytes: bytes);
    try {
      expect(PdfTextExtractor(document).extractText(), contains('BMP 资料'));
    } finally {
      document.dispose();
    }
    expect(
        () => tableXlsx([
              ['a\u0000b']
            ]),
        throwsFormatException);
    expect(
        () => tableXlsx([
              ['a' * 32768]
            ]),
        throwsFormatException);
    expect(() => tableXlsx([List.filled(16385, 'a')]), throwsFormatException);
  });
  test('Excel 使用字符串单元格，生成可由现有解析器读取的 OOXML', () {
    final bytes = tableXlsx([
      ['姓名', '金额'],
      ['甲', '=1+1'],
      ['乙', '含 & < 符号']
    ]);
    final archive = ZipDecoder().decodeBytes(bytes);
    final sheet = utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(sheet, contains('inlineStr'));
    expect(sheet, isNot(contains('<f>')));
    final text =
        OfficeTextExtractor.extractBytes(bytes, filename: 'table.xlsx').text;
    expect(text, contains('姓名'));
    expect(text, contains('=1+1'));
    expect(text, contains('含 & < 符号'));
  });
  test('版面行分组使用校对后的文本而不偷偷导出旧识别文字', () {
    OcrLine line(String text, double x, double y) => OcrLine(text: text, box: [
          [x, y],
          [x + 30, y],
          [x + 30, y + 10],
          [x, y + 10]
        ]);
    final result = PdfOcrResult(totalPages: 1, pages: [
      '名称\n金额\n正确名称\n99'
    ], details: [
      OcrPageDetail(page: 1, width: 200, height: 100, lines: [
        line('名称', 0, 0),
        line('金额', 100, 0),
        line('错误名称', 0, 20),
        line('9', 100, 20)
      ])
    ]);
    expect(ocrTableRows(result), [
      ['名称', '金额'],
      ['正确名称', '99']
    ]);
  });
}

int mathMax(int a, int b) => a > b ? a : b;
