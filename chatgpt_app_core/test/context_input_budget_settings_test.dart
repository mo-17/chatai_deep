import 'dart:convert';

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

  test('旧版与现有 JSON 缺少输入预算时沿用 262144', () {
    final current = AISettings.defaults().toJson()
      ..remove('contextInputBudgetTokens');
    final legacy = <String, dynamic>{
      'localProvider': 'deepseek',
      'deepseek': {'model': 'deepseek-chat'},
      'maxOutputTokens': 8192,
    };

    for (final json in [current, legacy]) {
      final settings = AISettings.fromJson(json);
      expect(settings.contextInputBudgetTokens, 262144);
      expect(settings.effectiveContextInputBudgetTokens, 262144);
    }
  });

  test('上一版默认预算自动升级，其他自定义值保留', () {
    for (final budget in [27648, 65536, 131072, 524288]) {
      final old = AISettings.defaults().toJson()
        ..remove('contextInputBudgetVersion')
        ..['contextInputBudgetTokens'] = budget
        ..['streamEnabled'] = false;
      final settings = AISettings.fromJson(old);
      expect(
          settings.contextInputBudgetTokens, budget == 27648 ? 262144 : budget);
      expect(settings.streamEnabled, isFalse);
    }
  });

  test('新版主动设置旧预算值后，保存和 clone 不会再次升级', () {
    final settings = AISettings.defaults()..contextInputBudgetTokens = 27648;
    final json = settings.toJson();
    expect(json['contextInputBudgetVersion'], 1);
    expect(AISettings.fromJson(json).contextInputBudgetTokens, 27648);
    expect(settings.clone().contextInputBudgetTokens, 27648);
  });

  test('输入预算的 JSON 往返与 clone 保留值，克隆修改不影响原值', () {
    final original = AISettings.defaults()..contextInputBudgetTokens = 65536;
    final restored = AISettings.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    final clone = original.clone();

    expect(restored.contextInputBudgetTokens, 65536);
    expect(clone.contextInputBudgetTokens, 65536);
    clone.contextInputBudgetTokens = 131072;
    expect(original.contextInputBudgetTokens, 65536);
  });

  test('输入预算的上下界均有效，不随最大输出长度变化', () {
    for (final budget in [1024, 27648, 65536, 262144, 1048576]) {
      final json = AISettings.defaults().toJson()
        ..['contextInputBudgetTokens'] = budget;
      final settings = AISettings.fromJson(json);
      expect(settings.contextInputBudgetTokens, budget);
      for (final outputTokens in [0, 4096, 16384]) {
        settings.maxOutputTokens = outputTokens;
        expect(settings.effectiveContextInputBudgetTokens, budget);
      }
    }
  });

  test('JSON 输入预算非法类型或越界回退默认，保留其他配置', () {
    for (final invalid in <Object?>[
      null,
      '65536',
      65536.0,
      1024.5,
      true,
      <Object>[],
      <String, Object>{},
      -1,
      0,
      1023,
      1048577,
    ]) {
      final json = AISettings.defaults().toJson()
        ..['contextInputBudgetTokens'] = invalid
        ..['streamEnabled'] = false
        ..['maxOutputTokens'] = 8192;
      final settings = AISettings.fromJson(json);
      expect(settings.contextInputBudgetTokens, 262144, reason: '$invalid');
      expect(settings.streamEnabled, isFalse);
      expect(settings.maxOutputTokens, 8192);
    }
  });

  test('运行期非法输入预算也兜底并按有效值序列化', () {
    final settings = AISettings.defaults();
    for (final invalid in [-1, 0, 1023, 1048577]) {
      settings.contextInputBudgetTokens = invalid;
      expect(settings.effectiveContextInputBudgetTokens, 262144);
      expect(settings.toJson()['contextInputBudgetTokens'], 262144);
      expect(settings.clone().contextInputBudgetTokens, 262144);
    }
  });

  for (final secure in [false, true]) {
    test('输入预算按账号保存，重新加载后保持值（secure=$secure）', () async {
      final store = secure ? _MemorySecureStore() : null;
      AISettingsDao.configureSecretStore(store);
      final accountA = AISettings.defaults()..contextInputBudgetTokens = 65536;
      final accountB = AISettings.defaults()..contextInputBudgetTokens = 131072;
      await AISettingsDao.saveFor('budget-account-a', accountA);
      await AISettingsDao.saveFor('budget-account-b', accountB);

      AISettingsDao.resetSecureStateForTest();
      AISettingsDao.configureSecretStore(store);
      final reloadedA = await AISettingsDao.loadForAsync('budget-account-a');
      final reloadedB = await AISettingsDao.loadForAsync('budget-account-b');

      expect(reloadedA.contextInputBudgetTokens, 65536);
      expect(reloadedB.contextInputBudgetTokens, 131072);
      expect(AISettingsDao.loadFor('budget-missing').contextInputBudgetTokens,
          262144);
    });
  }

  test('存储中的旧 JSON 或非法预算读取时保留原有服务配置', () async {
    AISettingsDao.configureSecretStore(null);
    final old = AISettings.defaults().toJson()
      ..remove('contextInputBudgetTokens')
      ..['streamEnabled'] = false;
    final malformed = Map<String, dynamic>.from(old)
      ..['contextInputBudgetTokens'] = 'corrupted';
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('budget-old'),
      jsonEncode(old),
    );
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('budget-malformed'),
      jsonEncode(malformed),
    );

    for (final account in ['budget-old', 'budget-malformed']) {
      final loaded = await AISettingsDao.loadForAsync(account);
      expect(loaded.contextInputBudgetTokens, 262144);
      expect(loaded.streamEnabled, isFalse);
      expect(loaded.activeProviderId, old['activeProviderId']);
    }
  });
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
