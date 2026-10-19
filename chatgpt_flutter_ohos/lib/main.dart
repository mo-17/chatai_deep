import 'package:chatgpt_app_core/chatgpt_app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:chatai_ohos_image_picker/ohos_image_picker.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:file_picker/file_picker.dart';

import 'ohos_huks_secure_key_value_store.dart';
import 'ohos_huawei_login_service.dart';
import 'ohos_runtime_security.dart';

Future<void> main() async {
  OhosImagePicker.registerWith();
  FilePicker.beforeSelection = OhosStorageService.shared.prepareSelection;
  OhosImagePicker.beforeSelection = OhosStorageService.shared.prepareSelection;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['QuickJS'],
        await rootBundle.loadString('assets/licenses/quickjs.txt'));
    for (final name in [
      'sherpa-onnx',
      'onnxruntime',
      'onnxruntime-notices',
      'espeak-ng',
      'piper-phonemize',
      'sherpa-dependencies'
    ]) {
      yield LicenseEntryWithLineBreaks(
          [name], await rootBundle.loadString('assets/licenses/$name.txt'));
    }
  });
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
      // LoginConfig.init 会在此配置上替换 HUKS 存储，保留宿主认证依赖。
      LoginSdkConfig.install(LoginSdkConfig.instance.copyWith(
        authDependencies: LoginAuthDependencies(
          huaweiLoginService: OhosHuaweiLoginService(),
        ),
      ));
    },
    secureStore: secureStore,
  );
}
