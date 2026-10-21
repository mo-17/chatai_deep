/// 原生端仍使用 dart:io；浏览器使用持久化虚拟文件系统和安全的平台判断。
export 'app_io_native.dart' if (dart.library.js_interop) 'app_io_web.dart';
