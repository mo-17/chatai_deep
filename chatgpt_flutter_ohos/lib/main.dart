import 'package:chatgpt_app_core/chatgpt_app_core.dart';
import 'package:login_sdk/dao/backend_host.dart';

Future<void> main() async {
  BackendConfig.host = '192.168.31.167:3000';
  await runChatGptApp();
}
