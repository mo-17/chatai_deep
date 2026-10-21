@TestOn('browser')
library;

import 'dart:convert';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_web/flutter_secure_storage_web.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:shared_preferences_web/shared_preferences_web.dart';

import 'package:chatgpt_flutter/flutter_secure_key_value_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorageWeb.registerWith(Registrar());
  SharedPreferencesPlugin.registerWith(null);
  test('Web 创作身份可生成且保留随机性', () {
    expect(List.generate(20, (_) => StoryPersonaModel.newPersonaKey()).toSet(),
        hasLength(20));
    expect(
        List.generate(20, (_) => StoryParticipantModel.newParticipantKey())
            .toSet(),
        hasLength(20));
    expect(List.generate(20, (_) => StoryMessageModel.newNodeKey()).toSet(),
        hasLength(20));
  });
  test('真实 WebCrypto 安全存储与完整服务商设置可以写入、验证和恢复', () async {
    final store = FlutterSecureKeyValueStore();
    final hash = 'web-test-${DateTime.now().microsecondsSinceEpoch}';
    final key = 'web-smoke-$hash';
    try {
      await store
          .write(key, 'browser-test')
          .timeout(const Duration(seconds: 5));
      expect(await store.read(key).timeout(const Duration(seconds: 5)),
          'browser-test');
      await HiCache.preInit();
      AISettingsDao.configureSecretStore(store);
      await AISettingsDao.prepareAccount(hash);
      final settings = AISettings.defaults();
      settings.providers.add(AiProvider(
          id: 'web-smoke',
          type: 'openai',
          name: 'Web smoke',
          apiHost: 'http://127.0.0.1:48352/v1',
          apiKey: 'browser-test',
          enabled: true,
          models: [AiModel(id: 'web-ui')],
          selectedModelId: 'web-ui'));
      settings.activeProviderId = 'web-smoke';
      await AISettingsDao.saveFor(hash, settings)
          .timeout(const Duration(seconds: 5));
      final raw = await store.read(AISettingsDao.secretKeyFor(hash));
      final payload = jsonDecode(raw!) as Map<String, dynamic>;
      expect(payload['generation'], 1, reason: 'Web 版本号不能受 32 位位移影响变成 0');
      await AISettingsDao.saveFor(hash, settings)
          .timeout(const Duration(seconds: 5));
      final next = jsonDecode(
              (await store.read(AISettingsDao.secondarySecretKeyFor(hash)))!)
          as Map<String, dynamic>;
      expect(next['generation'], 2);
      // 清掉 DAO 的进程缓存，再从真实安全/普通存储恢复。
      AISettingsDao.configureSecretStore(null);
      AISettingsDao.configureSecretStore(store);
      final restored = await AISettingsDao.loadForAsync(hash);
      expect(restored.activeProviderId, 'web-smoke');
      expect(restored.providers.singleWhere((p) => p.id == 'web-smoke').apiKey,
          'browser-test');
    } finally {
      await store.delete(key).timeout(const Duration(seconds: 5));
      await store
          .delete(AISettingsDao.secretKeyFor(hash))
          .timeout(const Duration(seconds: 5));
      await store
          .delete(AISettingsDao.secondarySecretKeyFor(hash))
          .timeout(const Duration(seconds: 5));
      AISettingsDao.configureSecretStore(null);
    }
  });
}
