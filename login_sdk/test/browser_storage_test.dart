@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/platform/indexed_db_file_persistence.dart';
import 'package:login_sdk/platform/persistent_memory_file_system.dart';

void main() {
  test('真实 IndexedDB 保留文件、目录、复制和移动，删除也在重新加载后生效', () async {
    final persistence = await IndexedDbFilePersistence.open();
    final first = PersistentMemoryFileSystem(persistence);
    await first.initialize();
    final root = '/tmp/web-test-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final directory = await first.directory(root).create();
      final temporary = await directory.createTemp('draft-');
      final file = first.file('${temporary.path}/中文.txt');
      await file.writeAsBytes(Uint8List.fromList([0, 1, 127, 255]));
      await file.copy('$root/copy.txt');
      await temporary.rename('$root/saved');

      final second = PersistentMemoryFileSystem(persistence);
      await second.initialize();
      expect(await second.file('$root/saved/中文.txt').readAsBytes(),
          [0, 1, 127, 255]);
      expect(
          await second.file('$root/copy.txt').readAsBytes(), [0, 1, 127, 255]);
      expect(await second.directory(temporary.path).exists(), isFalse);
      await second.directory(root).delete(recursive: true);

      final third = PersistentMemoryFileSystem(persistence);
      await third.initialize();
      expect(await third.directory(root).exists(), isFalse);
    } finally {
      final cleanup = PersistentMemoryFileSystem(persistence);
      await cleanup.initialize();
      if (await cleanup.directory(root).exists()) {
        await cleanup.directory(root).delete(recursive: true);
      }
      persistence.database.close();
    }
  });
}
