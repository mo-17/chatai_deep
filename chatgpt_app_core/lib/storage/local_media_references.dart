import 'dart:convert';
import 'dart:io';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'ohos_storage_service.dart' show StorageCandidate;
import '../util/bounded_file_reader.dart';

/// 检查全部本地账号数据库、偏好和文档清单；只返回引用名称，不输出账号或正文。
class LocalMediaReferences {
  final Future<Directory> Function() databases;
  final Future<List<Directory>> Function() documents;
  final Map<String, Object?> Function() preferences;
  final DatabaseFactory? factory;
  final int maxBytes, maxEntries;
  LocalMediaReferences(
      {Future<Directory> Function()? databases,
      Future<List<Directory>> Function()? documents,
      Map<String, Object?> Function()? preferences,
      this.factory,
      this.maxBytes = 64 * 1024 * 1024,
      this.maxEntries = 20000})
      : databases =
            databases ?? (() async => Directory(await getDatabasesPath())),
        documents = documents ??
            (() async => [
                  await getApplicationDocumentsDirectory(),
                  await getApplicationSupportDirectory()
                ]),
        preferences = preferences ??
            (() {
              final prefs = HiCache.getInstance().prefs;
              if (prefs == null) throw StateError('偏好尚未初始化');
              return {for (final key in prefs.getKeys()) key: prefs.get(key)};
            });

  Future<Set<String>> collect(List<StorageCandidate> candidates) async {
    final scan = _ReferenceScan(
        candidates.map((e) => e.name).toSet(), maxBytes, maxEntries);
    for (final entry in preferences().entries) {
      scan.text(entry.key);
      scan.text('${entry.value ?? ''}');
    }
    final root = await databases();
    await _checkDirectory(root);
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        scan.tick();
        final name = entity.path.split('/').last;
        if (!name.endsWith('.db')) continue;
        if (entity is! File) throw StateError('数据库条目无法完整检查');
        final db = await (factory ?? databaseFactory).openDatabase(entity.path,
            options:
                OpenDatabaseOptions(readOnly: true, singleInstance: false));
        try {
          final tables = await db.rawQuery(
              "select name from sqlite_master where type='table' and name not like 'sqlite_%'");
          for (final table in tables) {
            scan.tick();
            final quoted = _identifier(table['name'] as String);
            final columns = await db.rawQuery('pragma table_info($quoted)');
            for (final column in columns) {
              final name = _identifier(column['name'] as String);
              final jsonColumn = ['images', 'blocks'].contains(column['name']);
              final filter = jsonColumn
                  ? '1'
                  : "(cast($name as text) glob '*[0-9]_[0-9]*' or "
                      "substr(ltrim(cast($name as text)),1,1) in ('{','[','\"'))";
              var offset = 0;
              while (true) {
                scan.tick();
                // 只取可能含托管路径的文本；先在 SQLite 内检查长度，避免大字段整份读入。
                final rows = await db.rawQuery(
                    'select length(cast($name as blob)) as bytes, '
                    'case when length(cast($name as blob)) <= 2097152 then cast($name as text) end as value '
                    'from $quoted where typeof($name) in (\'text\',\'blob\') and '
                    '$filter limit 20 offset ?',
                    [offset]);
                for (final row in rows) {
                  if ((row['bytes'] as int) > 2097152) {
                    throw StateError('引用字段超过检查预算');
                  }
                  final value = row['value'] as String;
                  if (jsonColumn &&
                      value.isNotEmpty &&
                      jsonDecode(value) is! List) {
                    throw StateError('附件引用记录损坏');
                  }
                  scan.text(value);
                }
                if (rows.length < 20) break;
                offset += rows.length;
              }
            }
          }
        } finally {
          await db.close();
        }
      }
    }
    final visited = <String>{};
    for (final directory in await documents()) {
      if (visited.add(directory.absolute.path)) await _walk(directory, scan, 0);
    }
    return scan.found;
  }

  static String _identifier(String value) => '"${value.replaceAll('"', '""')}"';
  static Future<void> _checkDirectory(Directory root) async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw StateError('引用目录不可用');
    }
  }

  Future<void> _walk(
      Directory directory, _ReferenceScan scan, int depth) async {
    scan.tick();
    if (depth > 16) throw StateError('引用目录超过检查深度');
    await _checkDirectory(directory);
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      scan.tick();
      if (entity is Link) throw StateError('引用目录包含链接');
      if (entity is Directory) {
        await _walk(entity, scan, depth + 1);
        continue;
      }
      final name = entity.path.split('/').last;
      if (entity is! File || !name.endsWith('.json')) continue;
      final bytes =
          await readFileBytesBounded(entity, maxBytes: 2097152, label: '引用清单');
      scan.reserve(bytes.length);
      final text = utf8.decode(bytes);
      final data = jsonDecode(text);
      if (name == 'draft.json' &&
          entity.path.contains('/conversation_drafts/')) {
        if (data is! Map ||
            ![1, 2].contains(data['version']) ||
            data['text'] is! String ||
            data['images'] is! List ||
            data['files'] is! List) {
          throw StateError('草稿清单损坏');
        }
      }
      scan.match(jsonEncode(data));
    }
  }
}

class _ReferenceScan {
  final Set<String> candidates, found = {};
  final int maxBytes, maxEntries;
  final clock = Stopwatch()..start();
  int bytes = 0, entries = 0;
  _ReferenceScan(this.candidates, this.maxBytes, this.maxEntries);
  void tick() {
    if (++entries > maxEntries || clock.elapsed > const Duration(seconds: 30)) {
      throw StateError('引用检查超过预算');
    }
  }

  void reserve(int size) {
    bytes += size;
    if (bytes > maxBytes) throw StateError('引用检查超过预算');
  }

  void text(String text) {
    tick();
    reserve(utf8.encode(text).length);
    match(text);
    // JSON 的 Unicode 转义同样能表示真实本机路径，不能误判为无引用。
    try {
      match(jsonEncode(jsonDecode(text)));
    } on FormatException {
      // 普通文本不是 JSON；已按原文完成保守匹配。
    }
  }

  void match(String text) {
    for (final match
        in RegExp(r'(?:image_|tree_)?[0-9]+_[0-9]+(?:\.(?:png|jpg))?')
            .allMatches(text)) {
      final name = match.group(0)!;
      if (candidates.contains(name)) found.add(name);
    }
  }
}
