import 'package:integration_test/integration_test_driver.dart';

// 恢复需使用重启进程的新 VM URI 和 --use-existing-app；keep-app-running 只保活。
Future<void> main() => integrationDriver(responseDataCallback: null);
