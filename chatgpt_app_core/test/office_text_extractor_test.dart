import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _s = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _r =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _pr = 'http://schemas.openxmlformats.org/package/2006/relationships';

void main() {
  group('OfficeTextExtractor', () {
    test('识别四种扩展名和 MIME，路径大小写不影响判断', () {
      for (final ext in ['doc', 'docx', 'xls', 'xlsx']) {
        expect(
            OfficeTextExtractor.isOfficeFile('C:\\目录\\报告.${ext.toUpperCase()}'),
            isTrue);
        expect(
            OfficeTextExtractor.mimeFor('报告.$ext'), startsWith('application/'));
      }
      expect(OfficeTextExtractor.isOfficeFile('docx'), isFalse);
      expect(OfficeTextExtractor.isOfficeFile('报告.docx.exe'), isFalse);
      expect(OfficeTextExtractor.mimeFor('报告.txt'), 'application/octet-stream');
    });

    test('DOCX 保持段落表格正文次序和 tab/换行/中文 Unicode', () {
      final result = _extractDocx('''
        <w:p><w:r><w:t xml:space="preserve">  中文😀</w:t><w:tab/><w:t>乙</w:t><w:br/><w:t>丙 &amp; 丁</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>左</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>右</w:t></w:r></w:p><w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p/></w:tc><w:tc><w:p><w:r><w:t>末</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:t>正文结尾</w:t></w:r></w:p>
      ''');
      expect(result.text, '  中文😀\t乙\n丙 & 丁\n左\t右\n第二段\n\t末\n正文结尾');
      expect(result.warnings, isEmpty);
    });

    test('DOCX 不输出删除修订和域代码，保留插入及域缓存', () {
      final result = _extractDocx('''
        <w:p><w:del><w:r><w:delText>已删除</w:delText></w:r></w:del><w:ins><w:r><w:t>插入</w:t></w:r></w:ins><w:r><w:instrText>HYPERLINK file:///etc/passwd</w:instrText><w:t>链接显示</w:t></w:r></w:p>
      ''');
      expect(result.text, '插入链接显示');
    });

    test('DOCX 读取被引用的页眉页脚，并去重多个 section 的同一关系', () {
      final bytes = _docx('''
        <w:p><w:r><w:t>正文</w:t></w:r></w:p>
        <w:sectPr><w:headerReference r:id="h"/><w:footerReference r:id="f"/></w:sectPr>
        <w:sectPr><w:headerReference r:id="h"/></w:sectPr>
      ''', extra: {
        'word/_rels/document.xml.rels': _rels([
          _rel('h', 'header', 'stories/head.xml'),
          _rel('f', 'footer', 'stories/foot.xml'),
        ]),
        'word/stories/head.xml':
            '<w:hdr xmlns:w="$_w"><w:p><w:r><w:t>页眉中文</w:t></w:r></w:p></w:hdr>',
        'word/stories/foot.xml':
            '<w:ftr xmlns:w="$_w"><w:p><w:r><w:t>页脚</w:t></w:r></w:p></w:ftr>',
      });
      expect(_extract(bytes, 'docx').text, '[页眉]\n页眉中文\n正文\n[页脚]\n页脚');
    });

    test('DOCX 支持 Strict 命名空间和非默认主文档位置', () {
      final bytes = _package(
          'docx',
          'custom/main.xml',
          {
            'custom/main.xml':
                '<x:document xmlns:x="http://purl.oclc.org/ooxml/wordprocessingml/main"><x:body><x:p><x:r><x:t>严格版</x:t></x:r></x:p></x:body></x:document>',
          },
          strict: true);
      expect(_extract(bytes, 'docx').text, '严格版');
    });

    test('DOCX AlternateContent 只提取一份内容', () {
      final result = _extractDocx('''
        <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice Requires="w"><w:p><w:r><w:t>新版</w:t></w:r></w:p></mc:Choice><mc:Fallback><w:p><w:r><w:t>回退重复</w:t></w:r></w:p></mc:Fallback></mc:AlternateContent>
      ''');
      expect(result.text, '新版');
    });

    test('DOCX 支持 UTF-16 BOM 和代理对', () {
      const xml =
          '<w:document xmlns:w="$_w"><w:body><w:p><w:r><w:t>中文😀</w:t></w:r></w:p></w:body></w:document>';
      final units = xml.codeUnits;
      final data = ByteData(units.length * 2 + 2)
        ..setUint16(0, 0xfeff, Endian.little);
      for (var i = 0; i < units.length; i++) {
        data.setUint16(i * 2 + 2, units[i], Endian.little);
      }
      final bytes = _package('docx', 'word/document.xml',
          {'word/document.xml': data.buffer.asUint8List()});
      expect(_extract(bytes, 'docx').text, '中文😀');
    });

    test('XLSX 按 workbook 关系选择和排序命名工作表，不猜 sheet1', () {
      final result = _extract(
          _xlsx(
            sheets:
                '<sheet name="二号中文" sheetId="2" r:id="second"/><sheet name="一号" sheetId="1" r:id="first"/>',
            relationships: [
              _rel('first', 'worksheet', '/xl/worksheets/first.xml'),
              _rel('second', 'worksheet', 'worksheets/second.xml'),
              _rel('strings', 'sharedStrings', 'strings/custom.xml')
            ],
            entries: {
              'xl/strings/custom.xml':
                  '<sst xmlns="$_s"><si><r><t>富</t></r><r><t>文本😀</t></r><rPh><t>不输出拼音</t></rPh></si></sst>',
              'xl/worksheets/second.xml': _sheet(
                  '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>inline中文</t></is></c><c r="D1"><v>42</v></c><c r="E1" t="b"><v>1</v></c></row><row r="3"><c r="B3" t="b"><v>0</v></c><c r="E3" t="str"><v>末尾</v></c></row>'),
              'xl/worksheets/first.xml':
                  _sheet('<row r="1"><c r="A1"><v>-1.25E+2</v></c></row>'),
            },
          ),
          'xlsx');
      expect(result.text,
          '[工作表：二号中文]\n富文本😀\t\tinline中文\t42\tTRUE\n\t\t\t\t\n\tFALSE\t\t\t末尾\n\n[工作表：一号]\n-1.25E+2');
      expect(result.warnings, isEmpty);
    });

    test('XLSX 缺 row/c 地址时推断位置，同时保留显式空格', () {
      final bytes = _singleSheet(
          '<row><c r="B3" t="inlineStr"><is><t>中文</t></is></c><c><v>2</v></c></row>');
      expect(_extract(bytes, 'xlsx').text, '[工作表：测试]\n\t\t\n\t\t\n\t中文\t2');
    });

    test('XLSX 使用公式缓存且缺缓存公式明确标记，不执行任何公式', () {
      final result = _extract(_singleSheet('''
        <row r="1"><c r="A1"><f>1+1</f><v>2</v></c><c r="B1"><f>WEBSERVICE("https://example.com")</f></c><c r="C1" t="str"><f>"文本"</f><v>文本</v></c></row>
      '''), 'xlsx');
      expect(result.text, '[工作表：测试]\n2\t[公式未计算：无缓存结果]\t文本');
      expect(result.text, isNot(contains('WEBSERVICE')));
      expect(result.warnings, hasLength(2));
    });

    test('XLSX rich inline 文本解码 escape 并用 TSV 引号保持换行', () {
      final bytes = _singleSheet(
          '<row r="1"><c r="A1" t="inlineStr"><is><r><t>甲_x000A_乙</t></r><r><t>_x005F_x000D_</t></r></is></c><c r="B1" t="inlineStr"><is><t>&quot;中文&quot;</t></is></c></row>');
      expect(_extract(bytes, 'xlsx').text, '[工作表：测试]\n"甲\n乙_x000D_"\t"""中文"""');
    });

    test('XLSX 格式化数值保留原值并告知显示格式未转换', () {
      final result = _extract(
          _singleSheet('<row r="1"><c r="A1" s="1"><v>45292</v></c></row>'),
          'xlsx');
      expect(result.text, '[工作表：测试]\n45292');
      expect(result.warnings.single, contains('显示格式未重建'));
    });

    test('不支持的扩展名、空输入和错误预算返回 FormatException', () {
      expect(() => _extract(Uint8List(0), 'docx'), throwsFormatException);
      expect(() => _extract(Uint8List(0), 'txt'), throwsFormatException);
      expect(
          () => OfficeTextExtractor.extractBytes(_docx('<w:p/>'),
              filename: 'x.docx', maxCharacters: 0),
          throwsFormatException);
    });

    test('拒绝加密 OOXML 的 OLE 容器', () {
      expect(
          () => _extract(
              Uint8List.fromList(
                  [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
              'docx'),
          throwsFormatException);
    });

    test('拒绝损坏 ZIP、损坏 XML 和无正文的 DOCX', () {
      final bytes = _docx('<w:p><w:r><w:t>正文</w:t></w:r></w:p>');
      expect(
          () => _extract(
              Uint8List.sublistView(bytes, 0, bytes.length - 3), 'docx'),
          throwsFormatException);
      expect(() => _extract(_docx('<w:p><w:r></w:p>'), 'docx'),
          throwsFormatException);
      expect(
          () => _extract(
              _package('docx', 'word/document.xml',
                  {'word/document.xml': '<w:document xmlns:w="$_w"/>'}),
              'docx'),
          throwsFormatException);
    });

    test('拒绝 DOCX/XLSX 互相伪装和缺失关系的文件', () {
      expect(() => _extract(_docx('<w:p/>'), 'xlsx'), throwsFormatException);
      expect(
          () => _extract(
              _zip({
                'word/document.xml':
                    '<w:document xmlns:w="$_w"><w:body/></w:document>'
              }),
              'docx'),
          throwsFormatException);
      expect(
          () => _extract(
              _docx('<w:sectPr><w:headerReference r:id="missing"/></w:sectPr>'),
              'docx'),
          throwsFormatException);
    });

    test('拒绝 DTD/实体、超深 XML 和超节点数量', () {
      const dtd =
          '<!DOCTYPE w:document [<!ENTITY secret SYSTEM "file:///etc/passwd">]><w:document xmlns:w="$_w"><w:body><w:p><w:r><w:t>&secret;</w:t></w:r></w:p></w:body></w:document>';
      expect(
          () => _extract(
              _package('docx', 'word/document.xml', {'word/document.xml': dtd}),
              'docx'),
          throwsFormatException);
      expect(() => _extractDocx('${'<w:sdt>' * 129}<w:p/>${'</w:sdt>' * 129}'),
          throwsFormatException);
      expect(() => _extractDocx('<w:p/>' * 250001), throwsFormatException);
    });

    test('拒绝外部必需关系和越过包根目录的关系', () {
      final external = _xlsx(
          sheets: '<sheet name="恶意" sheetId="1" r:id="a"/>',
          relationships: [
            _rel('a', 'worksheet', 'https://example.com/data', external: true)
          ]);
      expect(() => _extract(external, 'xlsx'), throwsFormatException);
      final traversal = _xlsx(
          sheets: '<sheet name="恶意" sheetId="1" r:id="a"/>',
          relationships: [_rel('a', 'worksheet', '../../outside.xml')]);
      expect(() => _extract(traversal, 'xlsx'), throwsFormatException);
    });

    test('拒绝未知和不完整 XML 实体，但允许 CDATA 和合法 Unicode 引用', () {
      for (final value in ['&unknown;', 'bare&', '&#x0;']) {
        expect(() => _extractDocx('<w:p><w:r><w:t>$value</w:t></w:r></w:p>'),
            throwsFormatException);
      }
      expect(
          _extractDocx(
                  '<w:p><w:r><w:t><![CDATA[&literal;]]>&#x4E2D;&#x1F600;</w:t></w:r></w:p>')
              .text,
          '&literal;中😀');
    });

    test('拒绝 XML 原始控制字符和非法字符引用', () {
      for (final value in ['原始\u0001字符', '&#1;', '&#xFFFF;']) {
        expect(() => _extractDocx('<w:p><w:r><w:t>$value</w:t></w:r></w:p>'),
            throwsFormatException);
      }
    });

    test('外部超链接关系不下载，不影响普通正文', () {
      final result = _extract(
          _docx(
              '<w:p><w:hyperlink r:id="web"><w:r><w:t>本地显示文本</w:t></w:r></w:hyperlink></w:p>',
              extra: {
                'word/_rels/document.xml.rels': _rels([
                  _rel('web', 'hyperlink', 'https://example.com',
                      external: true)
                ])
              }),
          'docx');
      expect(result.text, '本地显示文本');
    });

    test('拒绝非法共享字符串和数值/布尔值', () {
      for (final cell in [
        '<c r="A1" t="s"><v>99</v></c>',
        '<c r="A1" t="b"><v>2</v></c>',
        '<c r="A1"><v>not-a-number</v></c>'
      ]) {
        expect(() => _extract(_singleSheet('<row r="1">$cell</row>'), 'xlsx'),
            throwsFormatException);
      }
    });

    test('拒绝工作表行列重复、错位和越界', () {
      for (final rows in [
        '<row r="1"><c r="A2"><v>1</v></c></row>',
        '<row r="1"><c r="A1"/><c r="A1"/></row>',
        '<row r="1"><c r="XFE1"/></row>',
        '<row r="1048577"><c/></row>',
        '<row r="1"/><row r="1"/>',
      ]) {
        expect(
            () => _extract(_singleSheet(rows), 'xlsx'), throwsFormatException);
      }
    });

    test('字符预算不会静默截断 DOCX 或 XLSX', () {
      final word = _docx('<w:p><w:r><w:t>完整正文不可截断</w:t></w:r></w:p>');
      expect(
          () => OfficeTextExtractor.extractBytes(word,
              filename: 'x.docx', maxCharacters: 5),
          throwsFormatException);
      final sheet = _singleSheet(
          '<row r="1"><c r="A1" t="inlineStr"><is><t>完整文本</t></is></c></row>');
      expect(
          () => OfficeTextExtractor.extractBytes(sheet,
              filename: 'x.xlsx', maxCharacters: 10),
          throwsFormatException);
    });

    test('稀疏巨大工作表不能通过空行/空列放大文本', () {
      final bytes = _singleSheet(
          '<row r="1048576"><c r="XFD1048576" t="inlineStr"><is><t>末</t></is></c></row>');
      expect(() => _extract(bytes, 'xlsx'), throwsFormatException);
    });

    test('ZIP 元数据预检拒绝超多 entry 和超大 entry', () {
      final tooMany = _docx('<w:p/>');
      final end = tooMany.length - 22;
      ByteData.sublistView(tooMany).setUint16(end + 8, 4097, Endian.little);
      ByteData.sublistView(tooMany).setUint16(end + 10, 4097, Endian.little);
      expect(() => _extract(tooMany, 'docx'), throwsFormatException);
      final oversized = _zip({'word/document.xml': 'small'});
      final central = _central(oversized);
      final data = ByteData.sublistView(oversized);
      data.setUint32(central + 24, 32 * 1024 * 1024 + 1, Endian.little);
      expect(() => _extract(oversized, 'docx'), throwsFormatException);
    });

    test('ZIP 实际解压超过伪造的声明大小时立即失败', () {
      final bytes = _zip({'word/document.xml': 'a' * (2 * 1024 * 1024)});
      final data = ByteData.sublistView(bytes);
      final central = _central(bytes);
      final local = data.getUint32(central + 42, Endian.little);
      data.setUint32(central + 24, 1, Endian.little);
      data.setUint32(local + 22, 1, Endian.little);
      expect(() => _extract(bytes, 'docx'), throwsFormatException);
    });

    test('ZIP 检查实际 CRC、加密标志和路径穿越', () {
      final badCrc = _zip({'word/document.xml': 'value'});
      final central = _central(badCrc);
      final data = ByteData.sublistView(badCrc);
      final local = data.getUint32(central + 42, Endian.little);
      data.setUint32(central + 16, 0, Endian.little);
      data.setUint32(local + 14, 0, Endian.little);
      expect(() => _extract(badCrc, 'docx'), throwsFormatException);
      final encrypted = _zip({'word/document.xml': 'value'});
      final encryptedData = ByteData.sublistView(encrypted);
      encryptedData.setUint16(_central(encrypted) + 8, 1, Endian.little);
      expect(() => _extract(encrypted, 'docx'), throwsFormatException);
      expect(
          () => _extract(
              _docx('<w:p/>', extra: {'../outside.txt': 'bad'}), 'docx'),
          throwsFormatException);
    });
  });
}

OfficeTextExtraction _extract(Uint8List bytes, String ext) =>
    OfficeTextExtractor.extractBytes(bytes, filename: '报告.$ext');

OfficeTextExtraction _extractDocx(String body) => _extract(_docx(body), 'docx');

Uint8List _docx(String body, {Map<String, Object> extra = const {}}) =>
    _package('docx', 'word/document.xml', {
      'word/document.xml':
          '<w:document xmlns:w="$_w" xmlns:r="$_r"><w:body>$body</w:body></w:document>',
      ...extra,
    });

Uint8List _singleSheet(String rows) => _xlsx(
      sheets: '<sheet name="测试" sheetId="1" r:id="a"/>',
      relationships: [_rel('a', 'worksheet', 'worksheets/data.xml')],
      entries: {'xl/worksheets/data.xml': _sheet(rows)},
    );

Uint8List _xlsx(
        {required String sheets,
        required List<String> relationships,
        Map<String, Object> entries = const {}}) =>
    _package('xlsx', 'xl/workbook.xml', {
      'xl/workbook.xml':
          '<workbook xmlns="$_s" xmlns:r="$_r"><sheets>$sheets</sheets></workbook>',
      'xl/_rels/workbook.xml.rels': _rels(relationships),
      ...entries,
    });

String _sheet(String rows) =>
    '<worksheet xmlns="$_s"><sheetData>$rows</sheetData></worksheet>';

String _rel(String id, String kind, String target, {bool external = false}) =>
    '<Relationship Id="$id" Type="$_r/$kind" Target="$target"${external ? ' TargetMode="External"' : ''}/>';

String _rels(List<String> relationships) =>
    '<Relationships xmlns="$_pr">${relationships.join()}</Relationships>';

Uint8List _package(String ext, String mainPath, Map<String, Object> entries,
        {bool strict = false}) =>
    _zip({
      '[Content_Types].xml':
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/$mainPath" ContentType="application/vnd.openxmlformats-officedocument.${ext == 'docx' ? 'wordprocessingml.document' : 'spreadsheetml.sheet'}.main+xml"/></Types>',
      '_rels/.rels':
          '<Relationships xmlns="$_pr"><Relationship Id="main" Type="${strict ? 'http://purl.oclc.org/ooxml/officeDocument/relationships' : _r}/officeDocument" Target="$mainPath"/></Relationships>',
      ...entries,
    });

Uint8List _zip(Map<String, Object> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile.bytes(
        entry.key,
        entry.value is String
            ? utf8.encode(entry.value as String)
            : entry.value as Uint8List));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

int _central(Uint8List bytes) => ByteData.sublistView(bytes)
    .getUint32(bytes.length - 22 + 16, Endian.little);
