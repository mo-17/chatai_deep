import 'package:login_sdk/platform/app_io.dart';

/// 新库放用户数据目录；发现旧版工作目录中的同名库时继续使用，不搬动旧库。
Future<String> resolveDesktopDatabasePath(
  String name, {
  required Directory supportDirectory,
  required Directory legacyDirectory,
}) async {
  if (name.isEmpty || name == '..' || name.contains(RegExp(r'[/\\:]'))) {
    throw ArgumentError.value(name, 'name', '数据库名称不能包含路径');
  }
  final directory = appDirectory('${supportDirectory.path}/databases');
  final target = appFile('${directory.path}/$name');
  if (await target.exists()) return target.absolute.path;
  final legacy = appFile('${legacyDirectory.path}/$name');
  if (await legacy.exists()) return legacy.absolute.path;
  await directory.create(recursive: true);
  return target.absolute.path;
}
