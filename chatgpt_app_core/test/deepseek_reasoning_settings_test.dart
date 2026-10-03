import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });
  tearDown(AISettingsDao.resetSecureStateForTest);

  for (final secure in [false, true]) {
    test('推理等级按账号保存，重载与恢复默认均生效 secure=$secure', () async {
      final store = secure ? _MemorySecureStore() : null;
      AISettingsDao.configureSecretStore(store);
      await AISettingsDao.saveFor(
          'reasoning-a',
          AISettings.defaults()
            ..deepSeekReasoningEffort = DeepSeekReasoningEffort.max);
      await AISettingsDao.saveFor(
          'reasoning-b',
          AISettings.defaults()
            ..deepSeekReasoningEffort = DeepSeekReasoningEffort.off);
      AISettingsDao.resetSecureStateForTest();
      AISettingsDao.configureSecretStore(store);
      expect(
          (await AISettingsDao.loadForAsync('reasoning-a'))
              .deepSeekReasoningEffort,
          DeepSeekReasoningEffort.max);
      expect(
          (await AISettingsDao.loadForAsync('reasoning-b'))
              .deepSeekReasoningEffort,
          DeepSeekReasoningEffort.off);
      expect(
          (await AISettingsDao.loadForAsync('reasoning-new'))
              .deepSeekReasoningEffort,
          isNull);
      await AISettingsDao.saveFor('reasoning-a', AISettings.defaults());
      expect(
          (await AISettingsDao.loadForAsync('reasoning-a'))
              .deepSeekReasoningEffort,
          isNull);
      expect(
          (await AISettingsDao.loadForAsync('reasoning-b'))
              .deepSeekReasoningEffort,
          DeepSeekReasoningEffort.off);
    });
  }
}

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
