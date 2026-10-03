import 'dart:convert';

import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mib = 1024 * 1024;

  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });
  tearDown(AISettingsDao.resetSecureStateForTest);

  test('旧版和现有 JSON 缺少附件限制时使用提高后的默认值', () {
    final current = AISettings.defaults().toJson()
      ..remove('attachmentTextMaxChars')
      ..remove('attachmentTextMaxFileBytes');
    final legacy = <String, dynamic>{
      'localProvider': 'deepseek',
      'deepseek': {'model': 'deepseek-chat'},
      'streamEnabled': false,
    };
    for (final json in [current, legacy]) {
      final settings = AISettings.fromJson(json);
      expect(settings.attachmentProcessingLimits.maxTextChars, 200000);
      expect(settings.attachmentProcessingLimits.maxTextFileBytes, 10 * mib);
      expect(settings.effectiveContextInputBudgetTokens, 262144);
    }
    expect(AISettings.fromJson(legacy).streamEnabled, isFalse);
  });

  test('自定义附件限制 JSON 往返、clone 保留且互不影响', () {
    final original = AISettings.defaults()
      ..attachmentTextMaxChars = 500000
      ..attachmentTextMaxFileBytes = 12 * mib
      ..contextInputBudgetTokens = 131072;
    final restored = AISettings.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    final clone = original.clone();
    for (final settings in [restored, clone]) {
      expect(settings.attachmentTextMaxChars, 500000);
      expect(settings.attachmentTextMaxFileBytes, 12 * mib);
      expect(settings.contextInputBudgetTokens, 131072);
    }
    clone.attachmentTextMaxChars = 1024;
    clone.attachmentTextMaxFileBytes = mib;
    expect(original.attachmentTextMaxChars, 500000);
    expect(original.attachmentTextMaxFileBytes, 12 * mib);
  });

  test('附件限制上下界有效，文件字节值无需是完整 MiB', () {
    for (final chars in [1024, 30000, 200000, 1048576]) {
      for (final bytes in [mib, 2 * mib, 10 * mib + 1, 32 * mib]) {
        final settings = AISettings.fromJson(AISettings.defaults().toJson()
          ..['attachmentTextMaxChars'] = chars
          ..['attachmentTextMaxFileBytes'] = bytes);
        expect(settings.attachmentProcessingLimits.maxTextChars, chars);
        expect(settings.attachmentProcessingLimits.maxTextFileBytes, bytes);
      }
    }
  });

  test('非法字符上限独立回退，不丢文件限制和其他设置', () {
    for (final invalid in <Object?>[
      null,
      '200000',
      200000.0,
      true,
      [],
      {},
      -1,
      0,
      1023,
      1048577,
    ]) {
      final settings = AISettings.fromJson(AISettings.defaults().toJson()
        ..['attachmentTextMaxChars'] = invalid
        ..['attachmentTextMaxFileBytes'] = 16 * mib
        ..['streamEnabled'] = false);
      expect(settings.attachmentTextMaxChars, 200000, reason: '$invalid');
      expect(settings.attachmentTextMaxFileBytes, 16 * mib);
      expect(settings.streamEnabled, isFalse);
    }
  });

  test('非法文件上限独立回退，不丢字符限制', () {
    for (final invalid in <Object?>[
      null,
      '10485760',
      10485760.0,
      true,
      [],
      {},
      -1,
      0,
      mib - 1,
      32 * mib + 1,
    ]) {
      final settings = AISettings.fromJson(AISettings.defaults().toJson()
        ..['attachmentTextMaxChars'] = 500000
        ..['attachmentTextMaxFileBytes'] = invalid);
      expect(settings.attachmentTextMaxChars, 500000);
      expect(settings.attachmentTextMaxFileBytes, 10 * mib, reason: '$invalid');
    }
  });

  test('运行期非法限制 getter、JSON 和 clone 均使用有效默认', () {
    final settings = AISettings.defaults()
      ..attachmentTextMaxChars = -1
      ..attachmentTextMaxFileBytes = 0;
    expect(settings.attachmentProcessingLimits.maxTextChars,
        AttachmentProcessingLimits.defaultMaxTextChars);
    expect(settings.attachmentProcessingLimits.maxTextFileBytes,
        AttachmentProcessingLimits.defaultMaxTextFileBytes);
    expect(settings.toJson()['attachmentTextMaxChars'], 200000);
    expect(settings.toJson()['attachmentTextMaxFileBytes'], 10 * mib);
    expect(settings.clone().attachmentTextMaxChars, 200000);
    expect(settings.clone().attachmentTextMaxFileBytes, 10 * mib);
  });

  for (final secure in [false, true]) {
    test('附件限制按账号保存并在重新加载后保留（secure=$secure）', () async {
      final store = secure ? _MemorySecureStore() : null;
      AISettingsDao.configureSecretStore(store);
      final accountA = AISettings.defaults()
        ..attachmentTextMaxChars = 500000
        ..attachmentTextMaxFileBytes = 20 * mib;
      final accountB = AISettings.defaults()
        ..attachmentTextMaxChars = 120000
        ..attachmentTextMaxFileBytes = 3 * mib;
      await AISettingsDao.saveFor('attachment-a', accountA);
      await AISettingsDao.saveFor('attachment-b', accountB);
      AISettingsDao.resetSecureStateForTest();
      AISettingsDao.configureSecretStore(store);
      final reloadedA = await AISettingsDao.loadForAsync('attachment-a');
      final reloadedB = await AISettingsDao.loadForAsync('attachment-b');
      expect(reloadedA.attachmentTextMaxChars, 500000);
      expect(reloadedA.attachmentTextMaxFileBytes, 20 * mib);
      expect(reloadedB.attachmentTextMaxChars, 120000);
      expect(reloadedB.attachmentTextMaxFileBytes, 3 * mib);
      final fresh = AISettingsDao.loadFor('attachment-missing');
      expect(fresh.attachmentTextMaxChars, 200000);
      expect(fresh.attachmentTextMaxFileBytes, 10 * mib);
    });
  }

  test('存储的旧设置读取保留服务商和输入预算', () async {
    AISettingsDao.configureSecretStore(null);
    final old = AISettings.defaults().toJson()
      ..remove('attachmentTextMaxChars')
      ..remove('attachmentTextMaxFileBytes')
      ..['contextInputBudgetTokens'] = 524288
      ..['streamEnabled'] = false;
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('attachment-old'),
      jsonEncode(old),
    );
    final loaded = await AISettingsDao.loadForAsync('attachment-old');
    expect(loaded.attachmentTextMaxChars, 200000);
    expect(loaded.attachmentTextMaxFileBytes, 10 * mib);
    expect(loaded.contextInputBudgetTokens, 524288);
    expect(loaded.streamEnabled, isFalse);
    expect(loaded.activeProviderId, old['activeProviderId']);
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
