import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/platform/persistent_memory_file_system.dart';

class _Store implements BrowserFilePersistence {
  final rows = <String, Uint8List?>{};
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<Map<String, Uint8List?>> load() async => Map.of(rows);
  @override
  Future<void> commit(
      Map<String, Uint8List?> writes, Set<String> deletes) async {
    await gate?.future;
    if (fail) throw StateError('模拟配额不足');
    for (final key in deletes) {
      rows.remove(key);
    }
    for (final entry in writes.entries) {
      rows[entry.key] =
          entry.value == null ? null : Uint8List.fromList(entry.value!);
    }
  }
}

void main() {
  test('附件、目录移动与删除在新实例恢复，账号路径互相独立', () async {
    final backend = _Store();
    final first = PersistentMemoryFileSystem(backend);
    await first.initialize();
    await first.directory('/app/a/assets').create(recursive: true);
    await first.file('/app/a/assets/text.txt').writeAsString('中文附件');
    await first.directory('/app/b').create(recursive: true);
    await first.file('/app/b/text.txt').writeAsString('账号 B');
    await first.directory('/app/a/assets').rename('/app/a/moved');
    final restored = PersistentMemoryFileSystem(backend);
    await restored.initialize();
    expect(await restored.file('/app/a/moved/text.txt').readAsString(), '中文附件');
    expect(await restored.directory('/app/a/assets').exists(), isFalse);
    await restored.directory('/app/a').delete(recursive: true);
    final third = PersistentMemoryFileSystem(backend);
    await third.initialize();
    expect(await third.directory('/app/a').exists(), isFalse);
    expect(await third.file('/app/b/text.txt').readAsString(), '账号 B');
  });
  test('失败写入回滚内存，不能报告保存成功', () async {
    final backend = _Store();
    final fs = PersistentMemoryFileSystem(backend);
    await fs.initialize();
    await fs.file('/tmp/draft.txt').writeAsString('旧草稿');
    backend.fail = true;
    await expectLater(
        fs.file('/tmp/draft.txt').writeAsString('新草稿'), throwsStateError);
    expect(await fs.file('/tmp/draft.txt').readAsString(), '旧草稿');
    backend.fail = false;
    await fs.file('/tmp/draft.txt').writeAsString('重试成功');
    expect(await fs.file('/tmp/draft.txt').readAsString(), '重试成功');
  });
  test('容量超限保留上次文件且不写持久化层', () async {
    final backend = _Store();
    final fs = PersistentMemoryFileSystem(backend, maxBytes: 16);
    await fs.initialize();
    await fs.file('/tmp/data').writeAsBytes([1, 2, 3]);
    await expectLater(fs.file('/tmp/data').writeAsBytes(List.filled(17, 0)),
        throwsA(anything));
    expect(await fs.file('/tmp/data').readAsBytes(), [1, 2, 3]);
    expect(backend.rows['/tmp/data'], [1, 2, 3]);
  });
  test('异步保存等待事务完成，连续保存按提交顺序执行', () async {
    final backend = _Store();
    final fs = PersistentMemoryFileSystem(backend);
    await fs.initialize();
    backend.gate = Completer<void>();
    var acknowledged = false;
    final one = fs
        .file('/tmp/data')
        .writeAsString('first')
        .then((_) => acknowledged = true);
    final two = fs.file('/tmp/data').writeAsString('second');
    await Future<void>.delayed(Duration.zero);
    expect(acknowledged, isFalse);
    expect(backend.rows.containsKey('/tmp/data'), isFalse);
    backend.gate!.complete();
    await Future.wait([one, two]);
    expect(await fs.file('/tmp/data').readAsString(), 'second');
  });
}
