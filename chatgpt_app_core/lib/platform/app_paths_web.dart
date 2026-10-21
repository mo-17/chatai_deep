import 'package:login_sdk/platform/app_io.dart';

Future<Directory> _directory(String path) =>
    appDirectory(path).create(recursive: true);
Future<Directory> getApplicationDocumentsDirectory() =>
    _directory('/app/documents');
Future<Directory> getApplicationSupportDirectory() =>
    _directory('/app/support');
Future<Directory> getTemporaryDirectory() => _directory('/tmp');
