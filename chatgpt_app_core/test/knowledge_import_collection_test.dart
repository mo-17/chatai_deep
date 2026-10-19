import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_import_collection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root, temp;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('knowledge-collection-test-');
    temp = await Directory('${root.path}/temp').create();
  });
  tearDown(() => root.delete(recursive: true));
  Future<File> zip(Map<String, String> entries) async {
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    // 新版编码器会把反斜杠规范化；测试需在两个 header 中保留原始非法名称，
    // 否则生成的是合法路径，无法验证导入器的拒绝边界。
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i + 46 <= bytes.length; i++) {
      final signature = view.getUint32(i, Endian.little);
      final header = signature == 0x04034b50
          ? 30
          : signature == 0x02014b50
              ? 46
              : 0;
      if (header == 0) continue;
      final length =
          view.getUint16(i + (header == 30 ? 26 : 28), Endian.little);
      if (i + header + length > bytes.length) continue;
      final name = utf8.decode(bytes.sublist(i + header, i + header + length));
      for (final original
          in entries.keys.where((name) => name.contains(r'\'))) {
        if (name == original.replaceAll(r'\', '/')) {
          bytes.setRange(
              i + header, i + header + length, utf8.encode(original));
        }
      }
    }
    return File('${root.path}/bundle.zip').writeAsBytes(bytes);
  }

  Future<KnowledgeImportCollection> unpack(File file) =>
      KnowledgeImportCollection.fromZip(file.path,
          temporaryDirectory: () async => temp);
  test('目录保留子路径与中文名，不删除用户源目录', () async {
    final selected =
        await Directory('${root.path}/selected/子目录').create(recursive: true);
    final source = await File('${selected.path}/文档.txt').writeAsString('中文😀');
    final collection =
        await KnowledgeImportCollection.fromDirectory(selected.parent.path);
    expect(collection.paths, [source.path]);
    await collection.dispose();
    expect(await source.readAsString(), '中文😀');
  });
  test('ZIP 解压检查 CRC、保留层级；释放仅删除本次目录且可重复调用', () async {
    final input = await zip({'资料/中文.txt': '中文😀', 'README.md': 'hello'});
    final collection = await unpack(input);
    expect(collection.paths, hasLength(2));
    final chinese = collection.paths.singleWhere((p) => p.endsWith('中文.txt'));
    expect(await File(chinese).readAsString(), '中文😀');
    await collection.dispose();
    await collection.dispose();
    expect(await temp.list().isEmpty, true);
    expect(await input.exists(), true);
  });
  test('路径穿越、大小写重名与文件/目录冲突拒绝，失败不残留临时文件', () async {
    for (final entries in [
      {'../escape.txt': 'bad'},
      {'/absolute.txt': 'bad'},
      {'A.txt': 'a', 'a.txt': 'b'},
      {'a': 'file', 'a/b.txt': 'conflict'},
      {'a\\b.txt': 'bad'},
    ]) {
      await expectLater(unpack(await zip(entries)), throwsA(isA<Exception>()));
      expect(await temp.list().isEmpty, true);
      expect(await File('${root.path}/escape.txt').exists(), false);
    }
  });
  test('损坏或 CRC 不匹配的 ZIP 不返回半份文件集合', () async {
    final input = await zip({'test.txt': '0123456789abcdef'});
    final bytes = await input.readAsBytes();
    // 同时修改两个 header 的 CRC，让中央目录自身一致但不匹配实际正文。
    for (var i = 0; i + 20 < bytes.length; i++) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 3 &&
          bytes[i + 3] == 4) {
        bytes[i + 14] ^= 1;
      }
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 1 &&
          bytes[i + 3] == 2) {
        bytes[i + 16] ^= 1;
      }
    }
    await input.writeAsBytes(bytes);
    await expectLater(unpack(input), throwsFormatException);
    expect(await temp.list().isEmpty, true);
  });
  test('文件数量和层级在批量导入前拒绝', () async {
    final entries = {for (var i = 0; i < 257; i++) '$i.txt': 'x'};
    await expectLater(unpack(await zip(entries)), throwsFormatException);
    final deep = '${List.filled(14, 'dir').join('/')}/x.txt';
    await expectLater(unpack(await zip({deep: 'x'})), throwsFormatException);
    expect(await temp.list().isEmpty, true);
  });
  test('目录不跟随符号链接，超大文件在读取前拒绝', () async {
    final selected = await Directory('${root.path}/selected').create();
    final outside =
        await File('${root.path}/outside.txt').writeAsString('private');
    await Link('${selected.path}/link.txt').create(outside.path);
    await expectLater(KnowledgeImportCollection.fromDirectory(selected.path),
        throwsFormatException);
    await Link('${selected.path}/link.txt').delete();
    final large =
        await File('${selected.path}/large.bin').open(mode: FileMode.write);
    await large.truncate(KnowledgeImportCollection.maxFileBytes + 1);
    await large.close();
    await expectLater(KnowledgeImportCollection.fromDirectory(selected.path),
        throwsFormatException);
    expect(await outside.readAsString(), 'private');
  });
}
