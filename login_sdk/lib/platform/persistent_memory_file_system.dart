import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';

/// null 表示目录；文件保存实际字节。持久化端须在同一事务提交整批变更。
abstract interface class BrowserFilePersistence {
  Future<Map<String, Uint8List?>> load();
  Future<void> commit(Map<String, Uint8List?> writes, Set<String> deletes);
}

/// 复用 Dart 官方 file 接口，让现有附件、知识库、备份和草稿读写保留原契约。
/// 每次异步写入等待持久化成功；失败恢复内存副本，禁止悄悄退回临时存储。
class PersistentMemoryFileSystem extends fs.ForwardingFileSystem {
  PersistentMemoryFileSystem(this.persistence,
      {this.maxBytes = 128 * 1024 * 1024})
      : super(MemoryFileSystem());
  final BrowserFilePersistence persistence;
  final int maxBytes;
  Future<void> _tail = Future.value();

  Future<void> initialize() async {
    final records = await persistence.load();
    if (records.length > 20000 ||
        records.values.fold<int>(0, (n, b) => n + (b?.length ?? 0)) >
            maxBytes) {
      throw const io.FileSystemException('浏览器文件数据超过读取预算');
    }
    _restore(records.keys.toList(), records);
    delegate.directory('/tmp').createSync(recursive: true);
    delegate.directory('/app').createSync(recursive: true);
    delegate.currentDirectory = '/';
  }

  @override
  fs.File file(dynamic path) => _PersistentFile(this, delegate.file(path));
  @override
  fs.Directory directory(dynamic path) =>
      _PersistentDirectory(this, delegate.directory(path));
  @override
  fs.Directory get systemTempDirectory => directory('/tmp');
  @override
  fs.Directory get currentDirectory =>
      directory(delegate.currentDirectory.path);

  Map<String, Uint8List?> _capture(List<String> roots) {
    final result = <String, Uint8List?>{};
    void capture(fs.FileSystemEntity entity) {
      if (entity is fs.File) {
        result[entity.absolute.path] = entity.readAsBytesSync();
      } else if (entity is fs.Directory) {
        result[entity.absolute.path] = null;
      } else {
        throw const io.FileSystemException('浏览器文件存储不接受链接');
      }
    }

    for (final root in roots) {
      final type = delegate.typeSync(root, followLinks: false);
      if (type == io.FileSystemEntityType.file) capture(delegate.file(root));
      if (type == io.FileSystemEntityType.directory) {
        capture(delegate.directory(root));
        delegate
            .directory(root)
            .listSync(recursive: true, followLinks: false)
            .forEach(capture);
      }
    }
    return result;
  }

  void _restore(List<String> roots, Map<String, Uint8List?> records) {
    for (final root in roots.toList()
      ..sort((a, b) => b.length.compareTo(a.length))) {
      final type = delegate.typeSync(root, followLinks: false);
      if (type == io.FileSystemEntityType.file) {
        delegate.file(root).deleteSync();
      }
      if (type == io.FileSystemEntityType.directory && root != '/') {
        delegate.directory(root).deleteSync(recursive: true);
      }
    }
    for (final entry in records.entries.toList()
      ..sort((a, b) => a.key.length.compareTo(b.key.length))) {
      if (!entry.key.startsWith('/') ||
          path.normalize(entry.key) != entry.key) {
        throw const io.FileSystemException('浏览器文件路径损坏');
      }
      if (entry.value == null) {
        delegate.directory(entry.key).createSync(recursive: true);
      } else {
        delegate.file(entry.key).parent.createSync(recursive: true);
        delegate.file(entry.key).writeAsBytesSync(entry.value!);
      }
    }
  }

  Future<T> change<T>(List<String> roots, T Function() action) {
    final complete = Completer<T>();
    final normalized =
        roots.map((p) => path.normalize(path.absolute(p))).toList();
    _tail = _tail.then((_) async {
      final before = _capture(normalized);
      try {
        final result = action();
        final after = _capture(normalized);
        var total = 0;
        for (final entity in delegate
            .directory('/')
            .listSync(recursive: true, followLinks: false)) {
          if (entity is fs.File) total += entity.lengthSync();
        }
        if (total > maxBytes) {
          throw const io.FileSystemException('浏览器文件存储超过 128 MiB 预算');
        }
        // 同时记录父目录，让刷新后空目录和完整路径仍存在。
        for (final key in after.keys.toList()) {
          var parent = path.dirname(key);
          while (parent != '/' && parent != '.') {
            after.putIfAbsent(parent, () => null);
            parent = path.dirname(parent);
          }
        }
        await persistence.commit(
            after, before.keys.toSet().difference(after.keys.toSet()));
        complete.complete(result);
      } catch (error, stack) {
        _restore(normalized, before);
        complete.completeError(error, stack);
      }
    }).catchError((Object error, StackTrace stack) {
      if (!complete.isCompleted) complete.completeError(error, stack);
    });
    return complete.future;
  }

  Future<fs.Directory> _createTemp(String parent, String? prefix) {
    final random = Random.secure();
    final suffix = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final temporaryPath = path.join(parent, '${prefix ?? ''}$suffix');
    return change([temporaryPath], () {
      delegate.directory(temporaryPath).createSync();
      return directory(temporaryPath);
    });
  }
}

abstract class _PersistentEntity<T extends fs.FileSystemEntity,
    D extends io.FileSystemEntity> extends fs.ForwardingFileSystemEntity<T, D> {
  _PersistentEntity(this.store, this.delegate);
  final PersistentMemoryFileSystem store;
  @override
  final D delegate;
  @override
  fs.FileSystem get fileSystem => store;
  @override
  fs.Directory wrapDirectory(io.Directory value) => store.directory(value.path);
  @override
  fs.File wrapFile(io.File value) => store.file(value.path);
  @override
  fs.Link wrapLink(io.Link value) => throw UnsupportedError('浏览器不支持文件链接');
  @override
  Future<T> delete({bool recursive = false}) => store.change([path], () {
        delegate.deleteSync(recursive: recursive);
        return wrap(delegate);
      });
  @override
  Future<T> rename(String newPath) => store
      .change([path, newPath], () => wrap(delegate.renameSync(newPath) as D));
  @override
  void deleteSync({bool recursive = false}) =>
      throw UnsupportedError('浏览器持久化必须等待异步删除');
  @override
  T renameSync(String newPath) => throw UnsupportedError('浏览器持久化必须等待异步移动');
}

class _PersistentFile extends _PersistentEntity<fs.File, io.File>
    with fs.ForwardingFile {
  _PersistentFile(super.store, super.delegate);
  @override
  Future<fs.File> create({bool recursive = false, bool exclusive = false}) =>
      store.change([path], () {
        delegate.createSync(recursive: recursive, exclusive: exclusive);
        return this;
      });
  @override
  Future<fs.File> copy(String newPath) =>
      store.change([newPath], () => wrapFile(delegate.copySync(newPath)));
  @override
  Future<fs.File> writeAsBytes(List<int> bytes,
      {io.FileMode mode = io.FileMode.write, bool flush = false}) {
    final owned = Uint8List.fromList(bytes);
    return store.change([path], () {
      delegate.writeAsBytesSync(owned, mode: mode, flush: flush);
      return this;
    });
  }

  @override
  Future<fs.File> writeAsString(String contents,
          {io.FileMode mode = io.FileMode.write,
          Encoding encoding = utf8,
          bool flush = false}) =>
      writeAsBytes(encoding.encode(contents), mode: mode, flush: flush);
  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      throw UnsupportedError('浏览器持久化必须等待异步创建');
  @override
  fs.File copySync(String newPath) => throw UnsupportedError('浏览器持久化必须等待异步复制');
  @override
  void writeAsBytesSync(List<int> bytes,
          {io.FileMode mode = io.FileMode.write, bool flush = false}) =>
      throw UnsupportedError('浏览器持久化必须等待异步写入');
  @override
  void writeAsStringSync(String contents,
          {io.FileMode mode = io.FileMode.write,
          Encoding encoding = utf8,
          bool flush = false}) =>
      throw UnsupportedError('浏览器持久化必须等待异步写入');
  @override
  io.IOSink openWrite(
          {io.FileMode mode = io.FileMode.write, Encoding encoding = utf8}) =>
      throw UnsupportedError('浏览器请使用有界异步文件写入');
  @override
  Future<io.RandomAccessFile> open(
      {io.FileMode mode = io.FileMode.read}) async {
    if (mode != io.FileMode.read) throw UnsupportedError('浏览器请使用有界异步文件写入');
    return delegate.open(mode: mode);
  }

  @override
  io.RandomAccessFile openSync({io.FileMode mode = io.FileMode.read}) {
    if (mode != io.FileMode.read) throw UnsupportedError('浏览器请使用有界异步文件写入');
    return delegate.openSync(mode: mode);
  }
}

class _PersistentDirectory extends _PersistentEntity<fs.Directory, io.Directory>
    with fs.ForwardingDirectory<fs.Directory> {
  _PersistentDirectory(super.store, super.delegate);
  @override
  Future<fs.Directory> create({bool recursive = false}) =>
      store.change([path], () {
        delegate.createSync(recursive: recursive);
        return this;
      });
  @override
  Future<fs.Directory> createTemp([String? prefix]) =>
      store._createTemp(path, prefix);

  @override
  void createSync({bool recursive = false}) =>
      throw UnsupportedError('浏览器持久化必须等待异步创建');
  @override
  fs.Directory createTempSync([String? prefix]) =>
      throw UnsupportedError('浏览器持久化必须等待异步创建');
  @override
  fs.Directory childDirectory(String basename) =>
      store.directory(store.path.join(path, basename));
  @override
  fs.File childFile(String basename) =>
      store.file(store.path.join(path, basename));
  @override
  fs.Link childLink(String basename) => throw UnsupportedError('浏览器不支持文件链接');
}
