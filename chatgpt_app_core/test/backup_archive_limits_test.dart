import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:flutter_test/flutter_test.dart';

const _limits = BackupArchiveLimits(
  maxCompressedBytes: 20,
  maxEntries: 3,
  maxEntryUncompressedBytes: 10,
  maxTotalUncompressedBytes: 15,
);

BackupArchiveEntryInfo _entry(
  String name, {
  int uncompressedBytes = 1,
  int compressedBytes = 1,
  bool isDirectory = false,
  bool isSymbolicLink = false,
  bool isEncrypted = false,
  bool hasRawContent = true,
}) =>
    BackupArchiveEntryInfo(
      name: name,
      isDirectory: isDirectory,
      isSymbolicLink: isSymbolicLink,
      isEncrypted: isEncrypted,
      hasRawContent: hasRawContent,
      uncompressedBytes: uncompressedBytes,
      compressedBytes: compressedBytes,
    );

void _validate(
  Iterable<BackupArchiveEntryInfo> entries, {
  int compressedInputBytes = 20,
}) {
  final decodedEntries = List<BackupArchiveEntryInfo>.of(entries);
  validateBackupArchiveEntries(
    decodedEntries,
    rawEntryNames: decodedEntries.map(
      (entry) => BackupArchiveEntryName(
        name: entry.name,
        isDirectory: entry.isDirectory,
      ),
    ),
    compressedInputBytes: compressedInputBytes,
    limits: _limits,
  );
}

final class _NoBulkMaterializeInputStream extends InputMemoryStream {
  _NoBulkMaterializeInputStream(super.bytes);

  @override
  Uint8List toUint8List() {
    throw StateError('writeStream 不得一次性物化整个输入');
  }
}

void main() {
  group('Backup archive limits', () {
    test('压缩输入边界值通过，超出一个 byte 拒绝', () {
      expect(
        () => validateBackupCompressedSize(20, limits: _limits),
        returnsNormally,
      );
      expect(
        () => validateBackupCompressedSize(21, limits: _limits),
        throwsFormatException,
      );
    });

    test('entry 数量边界值通过，目录也计入数量', () {
      expect(
        () => _validate([
          _entry('manifest.json'),
          _entry(
            'assets/',
            isDirectory: true,
            hasRawContent: false,
            uncompressedBytes: 0,
            compressedBytes: 0,
          ),
          _entry('assets/data.json'),
        ]),
        returnsNormally,
      );
      expect(
        () => _validate([
          _entry('one'),
          _entry('two'),
          _entry('three'),
          _entry('four'),
        ]),
        throwsFormatException,
      );
    });

    test('callback 收集 entry 数量时可在超限 header 立即拒绝', () {
      expect(
        () => validateBackupEntryCount(3, limits: _limits),
        returnsNormally,
      );
      expect(
        () => validateBackupEntryCount(4, limits: _limits),
        throwsFormatException,
      );
    });

    test('单 entry 解压大小边界值通过，超出一个 byte 拒绝', () {
      expect(
        () => _validate([_entry('data', uncompressedBytes: 10)]),
        returnsNormally,
      );
      expect(
        () => _validate([_entry('data', uncompressedBytes: 11)]),
        throwsFormatException,
      );
    });

    test('总解压大小边界值通过，超出一个 byte 拒绝', () {
      expect(
        () => _validate([
          _entry('one', uncompressedBytes: 10),
          _entry('two', uncompressedBytes: 5),
        ]),
        returnsNormally,
      );
      expect(
        () => _validate([
          _entry('one', uncompressedBytes: 10),
          _entry('two', uncompressedBytes: 6),
        ]),
        throwsFormatException,
      );
    });

    test('拒绝 exact、大小写冲突重复名和路径穿越', () {
      for (final entries in [
        [_entry('data.json'), _entry('data.json')],
        [_entry('Assets/Data.json'), _entry('assets/data.json')],
        [_entry('../data.json')],
        [_entry('assets/../data.json')],
      ]) {
        expect(() => _validate(entries), throwsFormatException);
      }
    });

    test('目录尾斜杠仅为校验归一化，仍检测与同名文件碰撞', () {
      expect(
        () => _validate([
          _entry(
            'assets/',
            isDirectory: true,
            hasRawContent: false,
            uncompressedBytes: 0,
            compressedBytes: 0,
          ),
        ]),
        returnsNormally,
      );
      expect(
        () => _validate([
          _entry(
            'assets/',
            isDirectory: true,
            hasRawContent: false,
            uncompressedBytes: 0,
            compressedBytes: 0,
          ),
          _entry('assets'),
        ]),
        throwsFormatException,
      );
    });

    test('拒绝链接、加密 entry、负大小和不合理的压缩元数据', () {
      final invalidEntries = [
        _entry('link', isSymbolicLink: true),
        _entry('encrypted', isEncrypted: true),
        _entry('negative-raw', compressedBytes: -1),
        _entry('negative-size', uncompressedBytes: -1),
        _entry('oversized-raw', compressedBytes: 21),
        _entry(
          'missing-raw',
          hasRawContent: false,
          uncompressedBytes: 1,
          compressedBytes: 0,
        ),
      ];

      for (final entry in invalidEntries) {
        expect(() => _validate([entry]), throwsFormatException);
      }
    });

    test('拒绝 entry 压缩大小总和超过输入', () {
      expect(
        () => _validate(
          [
            _entry('one', compressedBytes: 6),
            _entry('two', compressedBytes: 5),
          ],
          compressedInputBytes: 10,
        ),
        throwsFormatException,
      );
    });

    test('实际输出 sink 在写入时执行单 entry 上限', () {
      final budget = BackupArchiveOutputBudget(limits: _limits);
      final sink = budget.newEntry('payload.json');

      sink.writeBytes(List<int>.filled(10, 1));
      expect(sink.length, 10);
      expect(budget.totalBytes, 10);
      expect(() => sink.writeByte(2), throwsFormatException);
      expect(sink.getBytes(), List<int>.filled(10, 1));
      expect(budget.totalBytes, 10);
    });

    test('多个实际输出 sink 共享累计上限', () {
      final budget = BackupArchiveOutputBudget(limits: _limits);
      budget.newEntry('one.json').writeBytes(List<int>.filled(10, 1));
      final second = budget.newEntry('two.json');

      second.writeBytes(List<int>.filled(5, 2));
      expect(budget.totalBytes, 15);
      expect(() => second.writeByte(3), throwsFormatException);
      expect(budget.totalBytes, 15);
    });

    test('stored entry writeStream 分块计入预算且不整体物化输入', () {
      const streamingLimits = BackupArchiveLimits(
        maxCompressedBytes: 64,
        maxEntries: 2,
        maxEntryUncompressedBytes: 32,
        maxTotalUncompressedBytes: 32,
      );
      final budget = BackupArchiveOutputBudget(limits: streamingLimits);
      final sink = budget.newEntry('stored.bin');
      final input =
          _NoBulkMaterializeInputStream(List<int>.generate(24, (i) => i));

      sink.writeStream(input);

      expect(sink.getBytes(), List<int>.generate(24, (i) => i));
      expect(budget.totalBytes, 24);
    });
  });
}
