import 'dart:io' as io;
import 'package:file/file.dart';
import 'package:web/web.dart' as web;
import 'indexed_db_file_persistence.dart';
import 'persistent_memory_file_system.dart';

export 'dart:io' hide File, Directory, FileSystemEntity, Link, Platform;
export 'package:file/file.dart' show File, Directory, FileSystemEntity, Link;

PersistentMemoryFileSystem? _fileSystem;
PersistentMemoryFileSystem get _fs =>
    _fileSystem ?? (throw StateError('浏览器文件存储尚未初始化'));

Future<void> initializeBrowserFileSystem() async {
  if (_fileSystem != null) return;
  final system =
      PersistentMemoryFileSystem(await IndexedDbFilePersistence.open());
  await system.initialize();
  _fileSystem = system;
}

File appFile(String path) => _fs.file(path);
File appFileFromUri(Uri uri) => _fs.file(uri.toFilePath(windows: false));
Directory appDirectory(String path) => _fs.directory(path);
Directory get appTemporaryDirectory => _fs.systemTempDirectory;
Future<io.FileSystemEntityType> appFileType(String path,
        {bool followLinks = true}) =>
    _fs.type(path, followLinks: followLinks);

class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isLinux => false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => web.window.navigator.userAgent;
  static String get pathSeparator => '/';
  static String get localeName => web.window.navigator.language;
  static Map<String, String> get environment => const {};
}
