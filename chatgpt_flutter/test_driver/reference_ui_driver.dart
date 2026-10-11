import 'package:integration_test/integration_test_driver.dart';

// 重启后使用 --use-existing-app 连接新 VM；keep-app-running 仅保留本次结束的进程。
Future<void> main() => integrationDriver(responseDataCallback: null);
