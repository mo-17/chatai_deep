import 'dart:io';
import 'dart:isolate';

/// CMake 配置时从已锁定的依赖定位 DLL，发布包无需另行下载 SQLite。
Future<void> main() async {
  final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:sqflite_common_ffi/src/windows/sqlite3.dll'));
  if (uri == null || !await File.fromUri(uri).exists()) {
    stderr.writeln('缺少 sqflite_common_ffi 的 sqlite3.dll，请先 flutter pub get');
    exitCode = 1;
    return;
  }
  stdout.write(File.fromUri(uri).path);
}
