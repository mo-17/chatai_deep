import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 知识库文件导入：FileProcessor.extractTextForImport 抽纯正文。
void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('kb_import_test');
  });
  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('文本文件：返回纯正文（无附件包裹标记）', () async {
    final f = File('${tmp.path}/note.md');
    await f.writeAsString('# 标题\n\n正文内容 abc');
    final text = await FileProcessor.extractTextForImport(f.path);
    expect(text, isNotNull);
    expect(text, contains('正文内容 abc'));
    expect(text, isNot(contains('附件'))); // 不带 _wrapFileText 包裹
  });

  test('不支持的扩展名返回 null', () async {
    final f = File('${tmp.path}/pic.png');
    await f.writeAsBytes([1, 2, 3]);
    expect(await FileProcessor.extractTextForImport(f.path), isNull);
  });

  test('pickerExtensions 覆盖 pdf 与常见文本类型', () {
    expect(FileProcessor.pickerExtensions, contains('pdf'));
    expect(FileProcessor.pickerExtensions, contains('txt'));
    expect(FileProcessor.pickerExtensions, contains('md'));
  });
}
