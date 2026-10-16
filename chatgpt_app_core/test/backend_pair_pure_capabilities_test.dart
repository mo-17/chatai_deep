import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';

// 故意没有平台 binding/偏好预热；纯能力 API 不得安装默认SDK或启动插件。
void main() {
  setUp(() {
    LoginSdkConfig.reset();
    ModelCatalog.resetExecutionForTest();
  });
  tearDown(LoginSdkConfig.reset);
  AISettings settings() => AISettings.defaults()
    ..mode = AIMode.backend
    ..backendModel = 'gpt-4o';
  test('static capabilities has no SDK initialization side effect', () {
    expect(ChatService.capabilitiesFor(settings()).image, isTrue);
    expect(LoginSdkConfig.isInstalled, isFalse);
  });
  test('factory transport capabilities remains pure before app initialization',
      () {
    expect(ChatService.from(settings()).capabilities.image, isTrue);
    expect(LoginSdkConfig.isInstalled, isFalse);
  });
  test('dedicated backend constructor also leaves SDK/storage uninitialized',
      () {
    expect(BackendChatService(settings()).capabilities.image, isTrue);
    expect(LoginSdkConfig.isInstalled, isFalse);
  });
  test(
      'modern model reference is raw exact; no legacy override or local field change',
      () {
    final value = settings()
      ..backendModel = 'legacy-model'
      ..backendSelection = BackendSelection.pair(
          providerCode: ' A ',
          modelId: ' exact/model ',
          accountHash: 'foreign',
          origin: 'https://foreign.example');
    final localBefore = value.activeProvider.toJson();
    expect(value.effectiveModel, ' exact/model ');
    expect(value.clone().effectiveModel, ' exact/model ');
    expect(value.activeProvider.toJson(), localBefore);
    expect(LoginSdkConfig.isInstalled, isFalse);
  });
}
