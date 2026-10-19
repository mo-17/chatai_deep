import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';
import 'knowledge_evidence.dart';
import 'knowledge_repository.dart';

enum KnowledgeReportKind { report, comparison, studyNotes }

class KnowledgeReport {
  final String title;
  final KnowledgeReportKind kind;
  final List<KnowledgeAnswer> answers;
  KnowledgeReport(
      {required this.title, required this.kind, required this.answers}) {
    if (answers.isEmpty ||
        answers.length > 50 ||
        answers.any((a) =>
            a.status != KnowledgeAnswerStatus.cited || a.claims.isEmpty)) {
      throw const KnowledgeScopeException('请选择1～50条通过引用核验的回答');
    }
  }
  String get text {
    final out = StringBuffer('$title\n');
    out.writeln(switch (kind) {
      KnowledgeReportKind.report => '资料整理报告',
      KnowledgeReportKind.comparison => '资料对比表',
      KnowledgeReportKind.studyNotes => '学习笔记'
    });
    out.writeln('依据问答时的原文快照整理；引文存在不等于结论经过独立事实核验。\n');
    final refs = <String, int>{};
    final quotes = <KnowledgeQuote>[];
    for (var i = 0; i < answers.length; i++) {
      final answer = answers[i];
      out.writeln('${i + 1}. ${answer.question}');
      if (kind == KnowledgeReportKind.comparison) {
        out.writeln('问题/观点 | 结论 | 原文来源');
      }
      for (final claim in answer.claims) {
        final ids = <int>[];
        for (final quote in claim.evidence) {
          final key = '${quote.source.digest}:${quote.quote}';
          if (!refs.containsKey(key)) {
            refs[key] = quotes.length + 1;
            quotes.add(quote);
          }
          ids.add(refs[key]!);
        }
        out.writeln(
            '${kind == KnowledgeReportKind.studyNotes ? '要点：' : ''}${claim.text} '
            '${ids.map((id) => '[$id]').join(' ')}');
      }
      if (kind == KnowledgeReportKind.studyNotes) {
        out.writeln('自测：请用自己的话回答上述问题，并核对来源。');
      }
      out.writeln();
    }
    out.writeln('原文引用与版本');
    for (var i = 0; i < quotes.length; i++) {
      final q = quotes[i];
      out.writeln(
          '[${i + 1}] ${q.source.title} · ${q.source.location} · v${q.source.revision}\n'
          '原文：${q.quote}\n快照SHA-256：${q.source.digest}\n');
    }
    if (out.length > 150000) {
      throw const KnowledgeScopeException('导出内容过多，请减少问答数量');
    }
    return out.toString();
  }

  /// 同一问题的不同结论按行并列，保留来源，避免导出时虚构综合结论。
  List<List<String>> get comparisonRows => [
        ['问题', '资料中的结论', '原文来源'],
        for (final answer in answers)
          for (final claim in answer.claims)
            [
              answer.question,
              claim.text,
              claim.evidence
                  .map((q) =>
                      '${q.source.title} · ${q.source.location} · v${q.source.revision}\n原文：${q.quote}')
                  .join('\n\n')
            ],
      ];

  String get _appendix => '原文引用与版本${text.split('原文引用与版本').last}';

  Uint8List docx() {
    final document = XmlBuilder();
    document.processing(
        'xml', 'version="1.0" encoding="UTF-8" standalone="yes"');
    document.element('w:document', namespaces: {
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main': 'w'
    }, nest: () {
      document.element('w:body', nest: () {
        void paragraph(String line) {
          document.element('w:p',
              nest: () => document.element('w:r', nest: () {
                    document.element('w:rPr',
                        nest: () => document.element('w:rFonts', attributes: {
                              'w:ascii': 'Arial',
                              'w:eastAsia': 'Microsoft YaHei'
                            }));
                    document.element('w:t',
                        attributes: {'xml:space': 'preserve'},
                        nest: () => document.text(line));
                  }));
        }

        if (kind == KnowledgeReportKind.comparison) {
          paragraph(title);
          paragraph('资料观点对比；下列为问答时快照，不代表独立事实核验。');
          document.element('w:tbl', nest: () {
            document.element('w:tblPr', nest: () {
              document.element('w:tblW',
                  attributes: {'w:w': '5000', 'w:type': 'pct'});
              document.element('w:tblBorders', nest: () {
                for (final edge in [
                  'top',
                  'left',
                  'bottom',
                  'right',
                  'insideH',
                  'insideV'
                ]) {
                  document.element('w:$edge', attributes: {
                    'w:val': 'single',
                    'w:sz': '4',
                    'w:color': 'CBD5E1'
                  });
                }
              });
            });
            for (final row in comparisonRows) {
              document.element('w:tr', nest: () {
                for (final cell in row) {
                  document.element('w:tc', nest: () {
                    document.element('w:tcPr',
                        nest: () => document.element('w:tcW',
                            attributes: {'w:w': '3000', 'w:type': 'dxa'}));
                    for (final line in cell.split('\n')) {
                      paragraph(line);
                    }
                  });
                }
              });
            }
          });
          for (final line in _appendix.split('\n')) {
            paragraph(line);
          }
        } else {
          for (final line in text.split('\n')) {
            paragraph(line);
          }
        }
        document.element('w:sectPr', nest: () {
          document
              .element('w:pgSz', attributes: {'w:w': '11906', 'w:h': '16838'});
          document.element('w:pgMar', attributes: {
            'w:top': '720',
            'w:right': '720',
            'w:bottom': '720',
            'w:left': '720'
          });
        });
      });
    });
    final zip = Archive();
    void add(String name, String body) {
      zip.addFile(
          ArchiveFile(name, utf8.encode(body).length, utf8.encode(body)));
    }

    add(
        '[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>');
    add(
        '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>');
    add('word/document.xml', document.buildDocument().toXmlString());
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }

  Future<Uint8List> pdf() async {
    final doc = PdfDocument();
    try {
      doc.pageSettings.margins.all = 36;
      final font = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, 11);
      var page = doc.pages.add();
      if (kind == KnowledgeReportKind.comparison) {
        page.graphics.drawString(title, font,
            bounds: Rect.fromLTWH(0, 0, page.getClientSize().width, 30));
        final grid = PdfGrid()..columns.add(count: 3);
        final rows = comparisonRows;
        final header = grid.headers.add(1)[0];
        for (var i = 0; i < 3; i++) {
          header.cells[i].value = rows.first[i];
        }
        for (final row in rows.skip(1)) {
          final next = grid.rows.add();
          for (var i = 0; i < 3; i++) {
            next.cells[i].value = row[i];
          }
        }
        grid.style.font = font;
        grid.style.cellPadding =
            PdfPaddings(left: 5, right: 5, top: 5, bottom: 5);
        grid.draw(
            page: page,
            bounds: Rect.fromLTWH(0, 40, page.getClientSize().width,
                page.getClientSize().height - 40),
            format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate));
        page = doc.pages.add();
      }
      PdfTextElement(
              text: kind == KnowledgeReportKind.comparison ? _appendix : text,
              font: font)
          .draw(
              page: page,
              bounds: Rect.fromLTWH(0, 0, page.getClientSize().width,
                  page.getClientSize().height),
              format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate));
      return Uint8List.fromList(await doc.save());
    } finally {
      doc.dispose();
    }
  }
}
