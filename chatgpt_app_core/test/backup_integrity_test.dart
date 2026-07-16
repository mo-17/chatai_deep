import 'dart:convert';

import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backup integrity', () {
    test('digestEntries 基于原始 bytes 生成稳定 hash 与长度', () {
      final digests = digestEntries({
        'data.json': utf8.encode('abc'),
        'manifest.json': utf8.encode('不应自校验'),
      });

      expect(digests.keys, ['data.json']);
      expect(
        digests['data.json']!.sha256,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(digests['data.json']!.bytes, 3);
      expect(digests['data.json']!.schemaVersion, 1);
      expect(
        () => digestEntries(
          {'data.json': utf8.encode('abc')},
          schemaVersion: 2,
        ),
        throwsArgumentError,
      );
    });

    test('完整声明通过，manifest.json 不要求 digest', () {
      final entries = {
        'manifest.json': utf8.encode('{}'),
        'data.json': utf8.encode('abc'),
      };
      final manifestEntries = {
        for (final entry in digestEntries(entries).entries)
          entry.key: entry.value.toJson(),
      };

      expect(
        () => verifyEntryDigests(entries, manifestEntries),
        returnsNormally,
      );
    });

    test('拒绝缺少声明文件与额外未声明文件', () {
      final digest = digestEntries({
        'data.json': utf8.encode('abc'),
      })['data.json']!;

      expect(
        () => verifyEntryDigests(
          {'manifest.json': utf8.encode('{}')},
          {'data.json': digest.toJson()},
        ),
        throwsFormatException,
      );
      expect(
        () => verifyEntryDigests(
          {
            'manifest.json': utf8.encode('{}'),
            'data.json': utf8.encode('abc'),
            'extra.json': utf8.encode('extra'),
          },
          {'data.json': digest.toJson()},
        ),
        throwsFormatException,
      );
    });

    test('拒绝格式错误的 digest、bytes 与 schemaVersion', () {
      final valid = digestEntries({
        'data.json': utf8.encode('abc'),
      })['data.json']!;
      final fixtures = [
        {...valid.toJson(), 'sha256': valid.sha256.toUpperCase()},
        {...valid.toJson(), 'sha256': List.filled(63, '0').join()},
        {...valid.toJson(), 'bytes': -1},
        {...valid.toJson(), 'bytes': 3.0},
        {...valid.toJson(), 'schemaVersion': 0},
        {...valid.toJson(), 'schemaVersion': 2},
        {...valid.toJson(), 'schemaVersion': '1'},
      ];

      for (final fixture in fixtures) {
        expect(
          () => verifyEntryDigests(
            {'data.json': utf8.encode('abc')},
            {'data.json': fixture},
          ),
          throwsFormatException,
        );
      }
    });

    test('任意一个 byte 被篡改都会拒绝', () {
      final original = utf8.encode('abc');
      final manifestEntries = {
        'data.json':
            digestEntries({'data.json': original})['data.json']!.toJson(),
      };

      expect(
        () => verifyEntryDigests(
          {'data.json': utf8.encode('abd')},
          manifestEntries,
        ),
        throwsFormatException,
      );
    });

    test('entry 名必须是规范相对路径', () {
      for (final invalid in [
        '',
        '/data.json',
        r'assets\data.json',
        '../data.json',
        'assets/../data.json',
        './data.json',
        'assets//data.json',
        'C:/data.json',
      ]) {
        expect(
          () => validateBackupEntryNames([invalid]),
          throwsFormatException,
        );
      }
    });

    test('拒绝完全相同的重复 entry 路径', () {
      expect(
        () => validateBackupEntryNames(['data.json', 'data.json']),
        throwsFormatException,
      );
    });

    test('拒绝 ASCII 与 Unicode 大小写折叠后的重复 entry 路径', () {
      for (final duplicateNames in [
        ['Assets/Data.JSON', 'assets/data.json'],
        ['assets/CAFÉ.json', 'assets/café.json'],
      ]) {
        expect(
          () => validateBackupEntryNames(duplicateNames),
          throwsFormatException,
        );
      }
    });

    test('允许大小写折叠后仍不相同的合法 entry 路径', () {
      expect(
        () => validateBackupEntryNames([
          'manifest.json',
          'assets/files/001.bin',
          'assets/data.json',
          'documents/data.json',
          'assets/data-v2.json',
          'assets/小说.json',
        ]),
        returnsNormally,
      );
    });

    test('manifest 不能声明自己的 digest', () {
      final self = digestEntries({'x': utf8.encode('{}')})['x']!;
      expect(
        () => verifyEntryDigests(
          {'manifest.json': utf8.encode('{}')},
          {'manifest.json': self.toJson()},
        ),
        throwsFormatException,
      );
    });
  });
}
