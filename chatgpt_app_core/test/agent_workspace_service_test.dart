import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late HiDBManager manager;
  late AgentWorkspaceService service;
  late Directory temp;
  setUp(() async {
    manager = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    service = await AgentWorkspaceService.create(manager, cid: 7);
    temp = await Directory.systemTemp.createTemp('agent_workspace_test_');
  });
  tearDown(() async {
    await manager.db.close();
    await temp.delete(recursive: true);
  });

  test('全文保存，读取上限分页完全覆盖，包括末尾和 Unicode', () async {
    final content = '${'小说😀\n' * 18000}末尾';
    final file = await service.importText(name: '小说.txt', content: content);
    expect(file.characterCount, content.length);
    expect((await service.getRevision(file.id)).content, content);
    var offset = 0;
    final chunks = <String>[];
    do {
      final read = await service.readFile(file.id, offset: offset);
      chunks.add(read['content'] as String);
      expect(read['content'].length, lessThanOrEqualTo(12000));
      expect(read['startOffset'], offset);
      expect(read['endOffset'], offset + read['content'].length);
      expect(read['totalChars'], content.length);
      expect(read['offsetUnit'], 'utf16');
      expect(read['endExclusive'], true);
      if (read['nextOffset'] == null) break;
      offset = read['nextOffset'] as int;
    } while (true);
    expect(chunks.join(), content);
    expect(
        (await service.readFile(file.id, tail: true, maxChars: 5))['content'],
        content.substring(content.length - 5));
    await expectLater(
        service.readFile(file.id, maxChars: 12001), throwsFormatException);
    await expectLater(service.readFile(file.id, offset: content.length + 1),
        throwsFormatException);
  });

  test('导入实际字节限制和 BOM/CRLF，来源稳定且不泄漏路径', () async {
    final path = '${temp.path}/demo.txt';
    final bytes = utf8.encode('\uFEFF第一行\r\n第二行\r末行');
    await File(path).writeAsBytes(bytes);
    await expectLater(service.importPath(path, maxBytes: bytes.length - 1),
        throwsFormatException);
    final file = await service.importPath(path, maxBytes: bytes.length);
    expect(file.sizeBytes, bytes.length);
    expect((await service.getRevision(file.id)).content, '第一行\n第二行\n末行');
    expect(
        (await service.importPath(path, maxBytes: bytes.length)).id, file.id);
    expect(await service.manifest(), isNot(contains(temp.path)));
    expect(file.toJson().keys, isNot(contains('sourceKey')));
    await File(path).writeAsString('新版');
    final changed = await service.importPath(path, maxBytes: bytes.length);
    expect(changed.id, isNot(file.id));
    expect((await service.getRevision(file.id)).content, '第一行\n第二行\n末行');
  });

  test('相同内容不同来源区分，账号及 cid 隔离', () async {
    final first = await service.importText(
        name: 'same.txt', content: 'abc', sourceKey: '/source/a');
    final retry = await service.importText(
        name: 'same.txt', content: 'abc', sourceKey: '/source/a');
    final other = await service.importText(
        name: 'same.txt', content: 'abc', sourceKey: '/source/b');
    expect(retry.id, first.id);
    expect(other.id, isNot(first.id));
    final differentCid = await AgentWorkspaceService.create(manager, cid: 8);
    expect(await differentCid.listFiles(), isEmpty);
    expect(await differentCid.getFile(first.id), isNull);
    await expectLater(
        differentCid.getRevision(first.id), throwsFormatException);
    await expectLater(differentCid.readFile(first.id), throwsFormatException);
    await expectLater(
        differentCid.writeFile(
            fileId: first.id, name: 'same.txt', content: 'hack'),
        throwsFormatException);
    final otherManager = HiDBManager.test(
        await databaseFactoryFfi.openDatabase('${temp.path}/other-account.db'));
    try {
      expect(
          await (await AgentWorkspaceService.create(otherManager, cid: 7))
              .listFiles(),
          isEmpty);
    } finally {
      await otherManager.db.close();
    }
  });

  test('输出按同名增版本，重复写幂等，旧版本和输入不可变', () async {
    final input = await service.importText(name: 'report.md', content: '用户原文');
    await expectLater(
        service.writeFile(fileId: input.id, name: input.name, content: '覆盖'),
        throwsFormatException);
    final one = await service.writeFile(
        name: 'report.md', content: '# 报告\n一', note: '初稿');
    final retry = await service.writeFile(
        name: 'report.md', content: '# 报告\n一', note: '重复');
    expect(retry.id, one.id);
    expect(retry.revision, 1);
    final two = await service.writeFile(
        name: 'report.md', content: '# 报告\n二', note: '修订');
    expect(two.id, one.id);
    expect(two.revision, 2);
    expect((await service.getRevision(one.id, revision: 1)).content, '# 报告\n一');
    expect((await service.getRevision(one.id)).note, '修订');
    expect((await service.revisions(one.id)).map((r) => r.revision), [2, 1]);
    expect((await service.getRevision(input.id)).content, '用户原文');
    final concurrent = await Future.wait(List.generate(
        4, (_) => service.writeFile(name: 'report.md', content: '# 报告\n三')));
    expect(concurrent.map((f) => f.revision).toSet(), {3});
    expect((await service.revisions(one.id)).length, 3);
    await expectLater(
        service.writeFile(fileId: one.id, name: 'renamed.md', content: 'x'),
        throwsFormatException);
  });

  test('文件名只允许 basename，输出格式及上限严格检查', () async {
    for (final name in [
      '../x.txt',
      '/tmp/x.txt',
      r'C:\x.txt',
      '..',
      '',
      'a\n.txt'
    ]) {
      await expectLater(
          service.writeFile(name: name, content: 'x'), throwsFormatException);
    }
    await expectLater(
        service.writeFile(name: 'x.pdf', content: 'x'), throwsFormatException);
    await expectLater(
        service.writeFile(
            name: 'big.txt',
            content: 'x' * (AgentWorkspaceService.defaultMaxBytes + 1)),
        throwsFormatException);
    final valid =
        await service.writeFile(name: 'result.CSV', content: 'name,value\na,1');
    expect(valid.name, 'result.CSV');
    final link = Link('${temp.path}/link.txt');
    await File('${temp.path}/target.txt').writeAsString('test');
    await link.create('${temp.path}/target.txt');
    await expectLater(
        service.importPath(link.path, maxBytes: 100), throwsFormatException);
    await expectLater(
        service.importPath(temp.path, maxBytes: 100), throwsFormatException);
    await File('${temp.path}/bad.bin').writeAsBytes([0, 1, 2]);
    await expectLater(service.importPath('${temp.path}/bad.bin', maxBytes: 100),
        throwsFormatException);
  });

  test('按行和章节范围续读、搜索定位但不伪装全文阅读', () async {
    final body = '# 第一章\n${'章节正文\n' * 5000}## 小节\n尾部\n# 第二章\nABCD\nabcd\n';
    final file = await service.importText(name: 'novel.md', content: body);
    expect(file.toJson()['sections'], hasLength(3));
    expect(
        (await service.readFile(file.id, startLine: 1, endLine: 2))['content'],
        '# 第一章\n章节正文\n');
    var offset = 0;
    final chunks = <String>[];
    while (true) {
      final read = await service.readFile(file.id,
          section: '第一章', offset: offset, maxChars: 10000);
      chunks.add(read['content'] as String);
      if (read['nextOffset'] == null) break;
      offset = read['nextOffset'] as int;
    }
    expect(chunks.join(), body.substring(0, body.indexOf('# 第二章')));
    final search = await service.searchFile(file.id, 'abcd', maxResults: 1);
    expect(search['totalMatches'], 2);
    expect(search['truncated'], true);
    expect(search['countsAsReading'], false);
    final match = (search['matches'] as List).single as Map;
    expect(match['offset'], body.indexOf('ABCD'));
    expect(
        (await service.readFile(file.id,
            offset: match['offset'] as int, maxChars: 4))['content'],
        'ABCD');
    await expectLater(
        service.readFile(file.id, section: '不存在'), throwsFormatException);
    await expectLater(service.readFile(file.id, startLine: 2, page: 1),
        throwsFormatException);
  });

  test('PDF 超过 20 页完全提取，每页分页读取覆盖全文，空扫描页明确', () async {
    final document = PdfDocument();
    for (var i = 0; i < 25; i++) {
      final page = document.pages.add();
      if (i != 21) {
        page.graphics.drawString(
            'PAGE ${i + 1} text', PdfStandardFont(PdfFontFamily.helvetica, 14));
      }
    }
    final path = '${temp.path}/pages.pdf';
    await File(path).writeAsBytes(await document.save());
    document.dispose();
    final file = await service.importPath(path,
        maxBytes: AgentWorkspaceService.defaultMaxBytes);
    expect(file.pageCount, 25);
    final revision = await service.getRevision(file.id);
    expect(revision.content, contains('PAGE 25 text'));
    final chunks = <String>[];
    for (var page = 1; page <= 25; page++) {
      var offset = 0;
      while (true) {
        final read = await service.readFile(file.id,
            page: page, maxChars: 5, offset: offset);
        chunks.add(read['content'] as String);
        expect(read['startPage'], page);
        expect(read['endPage'], page);
        if (page == 22) {
          expect(read['needsOcr'], true);
          expect(read['warning'], contains('扫描'));
        }
        if (read['nextOffset'] == null) break;
        offset = read['nextOffset'] as int;
      }
    }
    expect(chunks.join(), revision.content);
    expect((await service.readFile(file.id))['emptyPages'], [22]);
    final lastSearch = await service.searchFile(file.id, 'PAGE 25');
    expect((lastSearch['matches'] as List).single['page'], 25);
  });

  test('分页文本以规范页拼接为准，页分隔符也完整覆盖', () async {
    final file = await service.importText(
        name: 'pages.pdf',
        content: '不可使用的正文',
        pageTexts: ['\uFEFFa\r\nb', '', 'last']);
    final pages = await Future.wait(
        List.generate(3, (i) => service.readFile(file.id, page: i + 1)));
    expect(pages.map((p) => p['content']).join(), 'a\nb\n\n\n\nlast');
    expect(file.characterCount, 'a\nb\n\n\n\nlast'.length);
    expect(
        (await service.getRevision(file.id)).pageTexts, ['a\nb', '', 'last']);
  });

  test('UTF-16 分段不切断 emoji，nextOffset 连续且字数上限不超出', () async {
    final content = '${'x' * 11999}😀尾部';
    final file =
        await service.importText(name: 'unicode.txt', content: content);
    final first = await service.readFile(file.id);
    expect(first['content'], 'x' * 11999);
    expect(first['endOffset'], 11999);
    expect(first['nextOffset'], 11999);
    final second =
        await service.readFile(file.id, offset: first['nextOffset'] as int);
    expect(second['content'], '😀尾部');
    expect('${first['content']}${second['content']}', content);
    expect(utf8.decode(utf8.encode(second['content'] as String)),
        second['content']);
    await expectLater(
        service.readFile(file.id, offset: 12000), throwsFormatException);
    await expectLater(service.readFile(file.id, offset: 11999, maxChars: 1),
        throwsFormatException);
  });

  test('文本导入允许按设置扩大到 32MiB，字节而非字符计数', () async {
    final content = 'x' * (AgentWorkspaceService.defaultMaxBytes + 1);
    await expectLater(service.importText(name: 'large.txt', content: content),
        throwsFormatException);
    final file = await service.importText(
        name: 'large.txt',
        content: content,
        maxBytes: AgentWorkspaceService.absoluteMaxBytes);
    expect(file.characterCount, content.length);
    expect(
        (await service.readFile(file.id, tail: true))['content'], 'x' * 12000);
    await expectLater(
        service.importText(name: 'bytes.txt', content: '汉字', maxBytes: 5),
        throwsFormatException);
    await expectLater(
        service.importText(
            name: 'bad.txt',
            content: 'x',
            maxBytes: AgentWorkspaceService.absoluteMaxBytes + 1),
        throwsFormatException);
    await expectLater(
        service.importPath('${temp.path}/absent.txt',
            maxBytes: AgentWorkspaceService.absoluteMaxBytes + 1),
        throwsFormatException);
    await expectLater(
        service.importText(
            name: 'too-many.pdf',
            content: '',
            pageTexts: List.filled(1001, '')),
        throwsFormatException);
  });

  test('单文件读取缓存随版本更新，章节 manifest 受限但可精确读取后续章节', () async {
    final body = List.generate(60, (i) => '# 章节$i\n内容$i\n').join();
    final input = await service.importText(name: 'chapters.md', content: body);
    expect(input.sectionCount, 60);
    expect(input.sections.length, 40);
    expect((await service.readFile(input.id, section: '章节59'))['content'],
        '# 章节59\n内容59\n');
    final output = await service.writeFile(name: 'draft.txt', content: '旧版');
    expect((await service.readFile(output.id))['content'], '旧版');
    await service.writeFile(name: 'draft.txt', content: '新版');
    final read = await service.readFile(output.id);
    expect(read['content'], '新版');
    expect(read['revision'], 2);
  });

  test('中文小说标题识别全角缩进，超长标题 manifest 不膨胀', () async {
    final longTitle = '标题' * 100;
    final file = await service.importText(
        name: 'chapters.txt',
        content:
            '\u3000\u3000第一章 初见\n正文一\n\u3000\u3000第二章 离开\n正文二\n# $longTitle\n长标题正文');
    expect((await service.readFile(file.id, section: '第一章 初见'))['content'],
        '\u3000\u3000第一章 初见\n正文一\n');
    expect(file.sections.last['title'].length, 80);
    expect(file.sections.last['titleTruncated'], true);
    expect((await service.readFile(file.id, section: longTitle))['content'],
        '# $longTitle\n长标题正文');
    final concurrent = await Future.wait(List.generate(
        4,
        (_) => service.importText(
            name: 'retry.txt', content: 'same', sourceKey: 'same-source')));
    expect(concurrent.map((f) => f.id).toSet().length, 1);
  });

  test('manifest 100 文件时默认仅列 50 并给出分页提示，无正文或来源路径', () async {
    for (var i = 0; i < 100; i++) {
      await service.importText(
          name: '附件$i.txt',
          content: '私密正文$i',
          sourceKey: '/private/user/original/$i.txt');
    }
    final encoded = await service.manifest();
    final manifest = jsonDecode(encoded) as Map<String, dynamic>;
    final files = manifest['files'] as List;
    expect(files.length, 50);
    expect(manifest['totalFiles'], 100);
    expect(manifest['listedFiles'], 50);
    expect(manifest['nextOffset'], 50);
    expect(manifest['truncated'], true);
    expect(manifest['paginationHint'],
        contains('list_files(offset: 50, limit: 50)'));
    expect(manifest['paginationHint'], contains('未列出的文件不代表不存在'));
    expect(encoded.length,
        lessThanOrEqualTo(AgentWorkspaceService.maxManifestChars));
    expect(encoded, isNot(contains('私密正文')));
    expect(encoded, isNot(contains('/private/user/original')));
    expect(files.any((f) => (f as Map).containsKey('content')), false);
    expect(files.any((f) => (f as Map).containsKey('sourceKey')), false);
    final smaller = jsonDecode(await service.manifest(maxFiles: 5)) as Map;
    expect(smaller['nextOffset'], 5);
    expect((smaller['files'] as List).length, 5);
  });

  test('manifest 密集章节还受字符体积限制，完整 DTO 不受清单章节裁切影响', () async {
    final body = List.generate(40, (i) => '# ${'长标题' * 26}$i\n正文$i\n').join();
    for (var i = 0; i < 100; i++) {
      await service.importText(
          name: '${'长文件名' * 30}$i.md', content: body, sourceKey: 'source-$i');
    }
    final encoded = await service.manifest();
    final manifest = jsonDecode(encoded) as Map;
    final files = manifest['files'] as List;
    expect(encoded.length,
        lessThanOrEqualTo(AgentWorkspaceService.maxManifestChars));
    expect(files, isNotEmpty);
    expect(files.length, lessThan(50));
    expect(manifest['totalFiles'], 100);
    expect(manifest['nextOffset'], files.length);
    expect(manifest['paginationHint'], contains('offset: ${files.length}'));
    expect(files.every((f) => (f['sections'] as List).length <= 10), true);
    expect(files.every((f) => f['sectionsTruncated'] == true), true);
    expect(
        (await service.listFiles()).first.toJson()['sections'], hasLength(40));
  });
}
