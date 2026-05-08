import 'package:chatgpt_app_core/chatgpt_app_core.dart';
import 'package:flutter_splash_screen/flutter_splash_screen.dart';

Future<void> main() async {
  await runChatGptApp();
  Future.delayed(const Duration(milliseconds: 1800), () {
    FlutterSplashScreen.hide();
  });
}
