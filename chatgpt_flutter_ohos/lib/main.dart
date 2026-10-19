import 'package:chatgpt_app_core/chatgpt_app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:chatai_ohos_image_picker/ohos_image_picker.dart';

import 'ohos_huks_secure_key_value_store.dart';
import 'ohos_runtime_security.dart';

Future<void> main() async {
  OhosImagePicker.registerWith();
  const host = String.fromEnvironment('BACKEND_HOST', defaultValue: '');
  const useHttps = bool.fromEnvironment('BACKEND_HTTPS', defaultValue: false);
  final secureStore = OhosHuksSecureKeyValueStore();
  await runChatGptApp(
    platformInitializer: () async {
      await OhosRuntimeSecurity.configureBackend(
        host: host,
        useHttps: useHttps,
        releaseMode: kReleaseMode,
      );
      await secureStore.ensureAvailable();
    },
    secureStore: secureStore,
  );
}
