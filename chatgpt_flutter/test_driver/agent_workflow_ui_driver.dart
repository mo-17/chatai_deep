import 'package:integration_test/integration_test_driver.dart';

// restore 必须使用重启进程的新 VM URI 与 --use-existing-app，避免重装容器。
Future<void> main() => integrationDriver(responseDataCallback: null);
