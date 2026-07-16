import 'package:chatgpt_app_core/chatgpt_app_core.dart';
import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:flutter_splash_screen/flutter_splash_screen.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'story_template_background_workmanager.dart';
import 'flutter_secure_key_value_store.dart';

Future<void> main() async {
  await runChatGptApp(
    platformInitializer: _initializePlatform,
    secureStore: FlutterSecureKeyValueStore(),
    afterRunApp: () {
      Future.delayed(const Duration(milliseconds: 1800), () {
        FlutterSplashScreen.hide();
      });
    },
  );
}

Future<void> _initializePlatform() async {
  if (DistributionConfig.current == AppDistribution.store) {
    final packageInfo = await PackageInfo.fromPlatform();
    DistributionConfig.validateStore(
      backendHost: BackendConfig.host,
      useHttps: BackendConfig.useHttps,
      applicationId: packageInfo.packageName,
    );
  }
  await installStoryTemplateBackgroundWorkmanager();
}
