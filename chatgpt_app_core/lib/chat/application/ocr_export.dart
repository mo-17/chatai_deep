import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';
import 'ocr_service.dart';
import 'pdf_ocr_result.dart';
import 'document_scan.dart';

/// 版面推测只作为可编辑草稿；无坐标时保留校对后的逐行文本。
List<List<String>> ocrTableRows(PdfOcrResult result) {
  final output = <List<String>>[];
  for (var page = 0; page < result.pages.length; page++) {
    final edited = result.pages[page].split('\n');
    final detail = result.detailFor(page + 1);
    if (detail == null ||
        detail.lines.isEmpty ||
        detail.lines.length != edited.length ||
        detail.lines.any((line) => line.box.length != 4)) {
      output.addAll(edited
          .where((line) => line.trim().isNotEmpty)
          .map((line) => line.split(RegExp(r'\t| {2,}'))));
      continue;
    }
    final cells = <({String text, double x, double y, double height})>[];
    for (var i = 0; i < detail.lines.length; i++) {
      final box = detail.lines[i].box;
      final left = box.map((p) => p[0]).reduce(math.min),
          top = box.map((p) => p[1]).reduce(math.min);
      final bottom = box.map((p) => p[1]).reduce(math.max);
      cells.add((
        text: edited[i],
        x: left,
        y: (top + bottom) / 2,
        height: math.max(1, bottom - top)
      ));
    }
    cells.sort((a, b) => a.y.compareTo(b.y));
    final rows = <List<({String text, double x, double y, double height})>>[];
    for (final cell in cells) {
      if (rows.isEmpty ||
          (cell.y - rows.last.first.y).abs() >
              math.max(cell.height, rows.last.first.height) * .6) {
        rows.add([]);
      }
      rows.last.add(cell);
    }
    for (final row in rows) {
      row.sort((a, b) => a.x.compareTo(b.x));
      output.add(row.map((c) => c.text).toList());
    }
  }
  if (output.length > 4000 ||
      output.fold<int>(0, (n, row) => n + row.length) > 20000) {
    throw const FormatException('表格行数或单元格过多，请分批导出');
  }
  return output;
}

String tableCsv(List<List<String>> rows, {bool safeForSpreadsheet = true}) =>
    rows
        .map((row) => row.map((value) {
              // CSV 不具备字符串类型，防止表格软件把识别内容当公式执行。
              final safe = safeForSpreadsheet &&
                      RegExp(r'^[\s\u0000-\u0020]*[=+@-]').hasMatch(value)
                  ? "'$value"
                  : value;
              return '"${safe.replaceAll('"', '""')}"';
            }).join(','))
        .join('\r\n');

List<List<String>> parseTableCsv(String text) {
  if (text.length > 200000) throw const FormatException('表格最多 20 万字符');
  final rows = <List<String>>[], row = <String>[];
  var field = StringBuffer(), quoted = false, closed = false, cells = 0;
  void nextField() {
    if (++cells > 20000) throw const FormatException('表格最多 2 万个单元格');
    row.add(field.toString());
    field = StringBuffer();
    closed = false;
  }

  void nextRow() {
    nextField();
    rows.add([...row]);
    row.clear();
    if (rows.length > 4000) throw const FormatException('表格最多 4000 行');
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"' && field.isEmpty && !closed) {
      quoted = true;
    } else if (ch == ',') {
      nextField();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      nextRow();
    } else {
      if (closed) throw const FormatException('CSV 引号闭合后只能接逗号或换行');
      field.write(ch);
    }
  }
  if (quoted) throw const FormatException('CSV 引号未闭合');
  if (field.isNotEmpty ||
      row.isNotEmpty ||
      (text.isNotEmpty && !text.endsWith('\n') && !text.endsWith('\r'))) {
    nextRow();
  }
  return rows;
}

Uint8List tableXlsx(List<List<String>> rows) {
  if (rows.length > 4000 ||
      rows.any((r) => r.length > 16384) ||
      rows.fold<int>(0, (n, r) => n + r.length) > 20000) {
    throw const FormatException('表格超过导出上限');
  }
  for (final value in rows.expand((row) => row)) {
    if (value.length > 32767) {
      throw const FormatException('Excel 单元格最多 32767 个字符，请拆分内容');
    }
    if (value.runes.any((n) => !(n == 9 ||
        n == 10 ||
        n == 13 ||
        (n >= 32 && n <= 0xd7ff) ||
        (n >= 0xe000 && n <= 0xfffd) ||
        (n >= 0x10000 && n <= 0x10ffff)))) {
      throw const FormatException('表格包含无法写入 Excel 的控制字符，请先删除');
    }
  }
  final archive = Archive();
  void add(String name, String value) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('[Content_Types].xml',
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>');
  add('_rels/.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');
  add('xl/workbook.xml',
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="OCR" sheetId="1" r:id="rId1"/></sheets></workbook>');
  add('xl/_rels/workbook.xml.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>');
  final builder = XmlBuilder();
  builder.element('worksheet',
      namespaces: {
        'http://schemas.openxmlformats.org/spreadsheetml/2006/main': ''
      },
      nest: () => builder.element('sheetData', nest: () {
            for (var r = 0; r < rows.length; r++) {
              builder.element('row', attributes: {'r': '${r + 1}'}, nest: () {
                for (var c = 0; c < rows[r].length; c++) {
                  builder.element('c',
                      attributes: {
                        'r': '${_column(c)}${r + 1}',
                        't': 'inlineStr'
                      },
                      nest: () => builder.element('is',
                          nest: () => builder.element('t',
                              attributes: {'xml:space': 'preserve'},
                              nest: () => builder.text(rows[r][c]))));
                }
              });
            }
          }));
  add('xl/worksheets/sheet1.xml', builder.buildDocument().toXmlString());
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _column(int column) {
  var n = column + 1, name = '';
  while (n > 0) {
    n--;
    name = String.fromCharCode(65 + n % 26) + name;
    n = n ~/ 26;
  }
  return name;
}

Future<Uint8List> searchableOcrPdf(
    {required Uint8List source,
    required bool pdf,
    required PdfOcrResult result}) async {
  final document = pdf ? PdfDocument(inputBytes: source) : PdfDocument();
  try {
    if (!pdf) {
      // PDF 原生支持 JPEG/PNG，其他已支持的 OCR 图片格式先在本机转码。
      final jpeg = source.length >= 3 &&
          source[0] == 0xff &&
          source[1] == 0xd8 &&
          source[2] == 0xff;
      final png = source.length >= 8 &&
          source[0] == 0x89 &&
          source[1] == 0x50 &&
          source[2] == 0x4e &&
          source[3] == 0x47;
      final bitmap =
          PdfBitmap(jpeg || png ? source : prepareScanPreview(source));
      document.pageSettings.margins.all = 0;
      // 横向原图必须匹配页面方向，防止添加文字层时将可见原图裁成竖页。
      document.pageSettings.orientation = bitmap.width > bitmap.height
          ? PdfPageOrientation.landscape
          : PdfPageOrientation.portrait;
      document.pageSettings.size =
          Size(bitmap.width.toDouble(), bitmap.height.toDouble());
      document.pages.add().graphics.drawImage(
          bitmap,
          Rect.fromLTWH(
              0, 0, bitmap.width.toDouble(), bitmap.height.toDouble()));
    }
    if (document.pages.count != result.totalPages ||
        result.pages.length != result.totalPages) {
      throw const FormatException('原件与识别页数不一致');
    }
    for (var i = 0; i < result.pages.length; i++) {
      if (pdf &&
          !OcrService.pdfNeedsOcr(PdfTextExtractor(document)
              .extractText(startPageIndex: i, endPageIndex: i))) {
        continue;
      }
      final page = document.pages[i], size = page.getClientSize();
      final lines = result.pages[i].split('\n');
      final detail = result.detailFor(i + 1);
      page.graphics.save();
      try {
        page.graphics.setTransparency(0);
        if (detail != null &&
            detail.width > 0 &&
            detail.height > 0 &&
            detail.lines.length == lines.length &&
            detail.lines.every((line) => line.box.length == 4)) {
          for (var n = 0; n < lines.length; n++) {
            final box = detail.lines[n].box;
            final x = box.map((p) => p[0]).reduce(math.min) /
                detail.width *
                size.width;
            final y = box.map((p) => p[1]).reduce(math.min) /
                detail.height *
                size.height;
            final right = box.map((p) => p[0]).reduce(math.max) /
                detail.width *
                size.width;
            final bottom = box.map((p) => p[1]).reduce(math.max) /
                detail.height *
                size.height;
            _hiddenText(page, lines[n], Rect.fromLTRB(x, y, right, bottom));
          }
        } else {
          _hiddenText(page, result.pages[i],
              Rect.fromLTWH(0, 0, size.width, size.height));
        }
      } finally {
        page.graphics.restore();
      }
    }
    final bytes = Uint8List.fromList(await document.save());
    if (bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('导出 PDF 超过 16 MiB，请拆分资料');
    }
    return bytes;
  } finally {
    document.dispose();
  }
}

void _hiddenText(PdfPage page, String text, Rect bounds) {
  if (text.isEmpty || bounds.width <= 0 || bounds.height <= 0) return;
  final rows = <String>[];
  for (final line in text.split('\n')) {
    final runes = line.runes.toList();
    for (var i = 0; i < runes.length; i += 80) {
      rows.add(String.fromCharCodes(
          runes.sublist(i, math.min(i + 80, runes.length))));
    }
  }
  if (rows.isEmpty) return;
  final base = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, 1);
  final maxWidth =
      rows.map((line) => base.measureString(line).width).reduce(math.max);
  final size = math.min(
      12.0,
      math.min(bounds.width / math.max(1, maxWidth),
          bounds.height / (rows.length * 1.8)));
  final font = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, size);
  page.graphics.drawString(rows.join('\n'), font,
      bounds: bounds, format: PdfStringFormat(wordWrap: PdfWordWrapType.none));
}
