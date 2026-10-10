import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 独立文档写入器产生的样例，覆盖真实 Office package 的关系与内容结构。
/// word_sample.docx 使用 python-docx，excel_sample.xlsx 使用 openpyxl 生成。
void main() {
  test('真实 DOCX package 提取中文段落、表格和引用页眉页脚', () async {
    final bytes =
        await File('test/fixtures/office/word_sample.docx').readAsBytes();
    final extraction = OfficeTextExtractor.extractBytes(
        Uint8List.fromList(bytes),
        filename: 'word_sample.docx');
    expect(extraction.text, contains('Word 中文测试'));
    expect(extraction.text, contains('第一段：移动端上传解析验证。'));
    expect(extraction.text, contains('项目'));
    expect(extraction.text, contains('苹果'));
    expect(extraction.text, contains('12'));
    expect(extraction.text, contains('END_WORD_20261007'));
    expect(extraction.text, contains('附件样例页眉'));
    expect(extraction.text, contains('附件样例页脚'));
    expect(extraction.text.indexOf('第一段'),
        lessThan(extraction.text.indexOf('苹果')));
    expect(extraction.text.indexOf('苹果'),
        lessThan(extraction.text.indexOf('END_WORD')));
  });

  test('真实 XLSX package 保留多表、稀疏坐标、布尔与无缓存公式提示', () async {
    final bytes =
        await File('test/fixtures/office/excel_sample.xlsx').readAsBytes();
    final extraction = OfficeTextExtractor.extractBytes(
        Uint8List.fromList(bytes),
        filename: 'excel_sample.xlsx');
    expect(extraction.text, contains('销售明细'));
    expect(extraction.text, contains('备注'));
    expect(extraction.text, contains('苹果'));
    expect(extraction.text, contains('3.5'));
    expect(extraction.text.toLowerCase(), contains('true'));
    expect(extraction.text, contains('远端单元格'));
    expect(extraction.text, contains('END_EXCEL_20261007'));
    expect(extraction.text, contains('公式未计算'));
    expect(extraction.warnings, isNotEmpty);
  });
}
