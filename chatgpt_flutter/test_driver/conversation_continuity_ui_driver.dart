import 'package:integration_test/integration_test_driver.dart';

// 重启后用新 app VM URI + --use-existing-app；keep-app-running 本身不能避免重装。
Future<void> main() => integrationDriver(responseDataCallback: null);
