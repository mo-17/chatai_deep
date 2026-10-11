import 'package:integration_test/integration_test_driver.dart';

// 重启恢复使用新 VM URI 与 --use-existing-app，keep-app-running 只保持当前进程。
Future<void> main() => integrationDriver(responseDataCallback: null);
