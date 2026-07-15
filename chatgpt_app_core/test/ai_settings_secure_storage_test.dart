import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  tearDown(AISettingsDao.resetSecureStateForTest);

  test('旧版明文 secrets 写入并回读安全存储后才从 HiCache 脱敏', () async {
    final settings = _settingsWithSecrets('legacy');
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(settings.toJson()),
    );
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);

    await AISettingsDao.prepareAccount('account-a');

    final loaded = AISettingsDao.loadFor('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-legacy');
    expect(loaded.tavilyApiKey, 'tavily-legacy');
    expect(loaded.exaApiKey, 'exa-legacy');
    expect(loaded.mcpServers.single.headers, {
      'Authorization': 'Bearer mcp-legacy',
    });

    final plain = _plainSettingsJson('account-a');
    expect(plain['_secretStorage'], 'secure-v1');
    expect(_providerKey(plain, loaded.activeProviderId), isEmpty);
    expect(plain['tavilyApiKey'], isEmpty);
    expect(plain['exaApiKey'], isEmpty);
    expect(
      ((plain['mcpServers'] as List).single as Map)['headers'],
      isEmpty,
    );
    expect(
      secureStore.values[AISettingsDao.secretKeyFor('account-a')],
      contains('provider-legacy'),
    );
  });

  test('迁移既有明文时安全存储写入失败会保留 full pending', () async {
    final settings = _settingsWithSecrets('fallback');
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(settings.toJson()),
    );
    final secureStore = _MemorySecureStore()..failWrites = true;
    AISettingsDao.configureSecretStore(secureStore);

    await AISettingsDao.prepareAccount('account-a');

    final pendingPlain = _plainSettingsJson('account-a');
    expect(pendingPlain['_secretWritePending'], isTrue);
    expect(_providerKey(pendingPlain, 'deepseek'), 'provider-fallback');
    expect(pendingPlain['tavilyApiKey'], 'tavily-fallback');

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');

    expect(loaded.activeProvider.apiKey, 'provider-fallback');
    expect(loaded.tavilyApiKey, 'tavily-fallback');
    expect(loaded.mcpServers.single.headers['Authorization'],
        'Bearer mcp-fallback');
    final restartedPlain = _plainSettingsJson('account-a');
    expect(restartedPlain['_secretWritePending'], isTrue);
  });

  test('secure 半写损坏后 full pending 可在重启时修复而不丢 Key', () async {
    final settings = _settingsWithSecrets('partial');
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(settings.toJson()),
    );
    final secureStore = _MemorySecureStore()..truncateNextWrite = true;
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('account-a');
    expect(_plainSettingsJson('account-a')['_secretWritePending'], isTrue);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');

    expect(loaded.activeProvider.apiKey, 'provider-partial');
    expect(loaded.tavilyApiKey, 'tavily-partial');
    expect(loaded.mcpServers.single.headers['Authorization'],
        'Bearer mcp-partial');
    expect(_plainSettingsJson('account-a')['_secretStorage'], 'secure-v1');
  });

  test('已加密账号保存失败时不降级明文，重试成功后 Key 保持清空', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final settings = _settingsWithSecrets('old');
    await AISettingsDao.saveFor('account-a', settings);

    settings.activeProvider.apiKey = '';
    settings
      ..tavilyApiKey = ''
      ..exaApiKey = ''
      ..bochaApiKey = ''
      ..zhipuApiKey = ''
      ..mcpServers = [
        settings.mcpServers.single.copyWith(headers: const {}),
      ];
    secureStore.failWrites = true;
    await expectLater(
      AISettingsDao.saveFor('account-a', settings),
      throwsA(isA<AISecretsUnavailableException>()),
    );
    final plain = _plainSettingsJson('account-a');
    expect(plain['_secretStorage'], 'secure-v1');
    expect(plain.containsKey('_secretWritePending'), isFalse);
    expect(_providerKey(plain, 'deepseek'), isEmpty);

    secureStore.failWrites = false;
    await AISettingsDao.saveFor('account-a', settings);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, isEmpty);
    expect(loaded.tavilyApiKey, isEmpty);
    expect(loaded.mcpServers.single.headers, isEmpty);
  });

  test('不同账号使用不同 secure key，不会互相串用凭据', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);

    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('a'));
    await AISettingsDao.saveFor('account-b', _settingsWithSecrets('b'));

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final accountA = await AISettingsDao.loadForAsync('account-a');
    final accountB = await AISettingsDao.loadForAsync('account-b');

    expect(accountA.activeProvider.apiKey, 'provider-a');
    expect(accountB.activeProvider.apiKey, 'provider-b');
    expect(accountA.mcpServers.single.headers['Authorization'], 'Bearer mcp-a');
    expect(accountB.mcpServers.single.headers['Authorization'], 'Bearer mcp-b');
    expect(
      secureStore.values.keys,
      containsAll([
        AISettingsDao.secretKeyFor('account-a'),
        AISettingsDao.secretKeyFor('account-b'),
      ]),
    );
  });

  test('未注入安全存储的 OHOS 等壳层继续使用原有完整 HiCache 格式', () async {
    AISettingsDao.configureSecretStore(null);

    await AISettingsDao.saveFor('guest', _settingsWithSecrets('guest'));

    final plain = _plainSettingsJson('guest');
    expect(plain.containsKey('_secretStorage'), isFalse);
    expect(plain.containsKey('_secretWritePending'), isFalse);
    expect(_providerKey(plain, 'deepseek'), 'provider-guest');
    expect(plain['tavilyApiKey'], 'tavily-guest');
    expect(
        AISettingsDao.loadFor('guest').activeProvider.apiKey, 'provider-guest');
  });

  test('旧缓存 JSON 字段类型异常时保留原数据并回退默认设置', () async {
    const malformed = '{"providers":[42],"activeProviderId":"deepseek"}';
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      malformed,
    );
    AISettingsDao.configureSecretStore(_MemorySecureStore());

    await expectLater(AISettingsDao.prepareAccount('account-a'), completes);
    final loaded = AISettingsDao.loadFor('account-a');

    expect(loaded.activeProviderId, 'deepseek');
    expect(
      HiCache.getInstance().get(AISettingsDao.keyFor('account-a')),
      malformed,
    );
  });

  test('secure read 短暂失败后保存普通设置不会覆盖原 secrets', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('original'));
    final originalSecureValue = _latestSecureJson(secureStore, 'account-a');

    AISettingsDao.resetSecureStateForTest();
    secureStore.failReads = true;
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('account-a');
    final temporarilyUnavailable = AISettingsDao.loadFor('account-a')
      ..streamEnabled = false;

    secureStore.failReads = false;
    await AISettingsDao.saveFor('account-a', temporarilyUnavailable);

    expect(_latestSecureJson(secureStore, 'account-a'),
        isNot(originalSecureValue));
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.streamEnabled, isFalse);
    expect(reloaded.activeProvider.apiKey, 'provider-original');
    expect(reloaded.tavilyApiKey, 'tavily-original');
    expect(reloaded.mcpServers.single.headers['Authorization'],
        'Bearer mcp-original');
  });

  test('secure marker 存在但 secrets 读不到时异步强一致读取会失败', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('guest', _settingsWithSecrets('guest'));

    AISettingsDao.resetSecureStateForTest();
    secureStore.failReads = true;
    AISettingsDao.configureSecretStore(secureStore);

    await expectLater(
      AISettingsDao.loadForAsync('guest'),
      throwsA(isA<AISecretsUnavailableException>()),
    );
  });

  test('首次升级仍有完整旧配置时 secure read 短暂失败继续兼容使用', () async {
    final settings = _settingsWithSecrets('legacy-read-fallback');
    final original = jsonEncode(settings.toJson());
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      original,
    );
    final secureStore = _MemorySecureStore()..failReads = true;
    AISettingsDao.configureSecretStore(secureStore);

    final loaded = await AISettingsDao.loadForAsync('account-a');

    expect(loaded.activeProvider.apiKey, 'provider-legacy-read-fallback');
    expect(loaded.tavilyApiKey, 'tavily-legacy-read-fallback');
    expect(
      HiCache.getInstance().get(AISettingsDao.keyFor('account-a')),
      original,
    );
    expect(secureStore.writeCount, 0);
  });

  test('后台只读加载旧明文设置时不迁移、不脱敏、不写 secure', () async {
    final settings = _settingsWithSecrets('background');
    final original = jsonEncode(settings.toJson());
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      original,
    );
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);

    final loaded = await AISettingsDao.loadForBackground('account-a');

    expect(loaded.activeProvider.apiKey, 'provider-background');
    expect(loaded.tavilyApiKey, 'tavily-background');
    expect(secureStore.writeCount, 0);
    expect(
      HiCache.getInstance().get(AISettingsDao.keyFor('account-a')),
      original,
    );
  });

  test('后台只读加载 secure 设置失败时抛出可重试异常', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('worker'));
    final writesBefore = secureStore.writeCount;

    AISettingsDao.resetSecureStateForTest();
    secureStore.failReads = true;
    AISettingsDao.configureSecretStore(secureStore);

    await expectLater(
      AISettingsDao.loadForBackground('account-a'),
      throwsA(isA<AISecretsUnavailableException>()),
    );
    expect(secureStore.writeCount, writesBefore);
  });

  test('系统恢复只有 secure marker 时保留普通设置并允许重新配置 Key', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final settings = _settingsWithSecrets('old')
      ..streamEnabled = false
      ..maxOutputTokens = 2048;
    await AISettingsDao.saveFor('account-a', settings);
    secureStore.values.remove(AISettingsDao.secretKeyFor('account-a'));

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final restored = await AISettingsDao.loadForAsync('account-a');

    expect(restored.streamEnabled, isFalse);
    expect(restored.maxOutputTokens, 2048);
    expect(restored.activeProvider.apiKey, isEmpty);
    expect(restored.tavilyApiKey, isEmpty);
    restored.activeProvider.apiKey = 'new-device-key';
    await AISettingsDao.saveFor('account-a', restored);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'new-device-key');
    expect(reloaded.streamEnabled, isFalse);
  });

  test('secure marker 的普通设置损坏时从 v2 完整快照恢复', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('protected'));
    final secureKey = AISettingsDao.secretKeyFor('account-a');
    final originalSecure = secureStore.values[secureKey];
    final plain = _plainSettingsJson('account-a')..['providers'] = [42];
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(plain),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final recovered = await AISettingsDao.loadForAsync('account-a');

    expect(secureStore.values[secureKey], originalSecure);
    expect(recovered.activeProvider.apiKey, 'provider-protected');
    expect(recovered.tavilyApiKey, 'tavily-protected');
    expect(_providerKey(_plainSettingsJson('account-a'), 'deepseek'), isEmpty);
  });

  test('plain JSON 截断但 v2 secure 存在时恢复完整设置', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('truncated'));
    final secureKey = AISettingsDao.secretKeyFor('account-a');
    final originalSecure = secureStore.values[secureKey];
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      '{"providers": [',
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final recovered = await AISettingsDao.loadForAsync('account-a');

    expect(secureStore.values[secureKey], originalSecure);
    expect(recovered.activeProvider.apiKey, 'provider-truncated');
    expect(recovered.activeProvider.apiHost, isNotEmpty);
    expect(_plainSettingsJson('account-a')['_secretStorage'], 'secure-v1');
  });

  test('saveFor 在 I/O 等待期间使用入队瞬间的不可变快照', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('account-a');
    final settings = _settingsWithSecrets('snapshot');
    settings.activeProvider.apiHost = 'https://host-a.example';
    final blocked = secureStore.blockNextWrite();

    final saving = AISettingsDao.saveFor('account-a', settings);
    await blocked.started;
    settings.activeProvider
      ..apiKey = 'mutated-key'
      ..apiHost = 'https://host-b.example';
    blocked.release();
    await saving;

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-snapshot');
    expect(reloaded.activeProvider.apiHost, 'https://host-a.example');
  });

  test('同账号并发 saveFor 串行执行且最后调用完整获胜', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('account-a');
    final first = _settingsWithSecrets('first');
    first.activeProvider.apiHost = 'https://first.example';
    final second = _settingsWithSecrets('second');
    second.activeProvider.apiHost = 'https://second.example';
    final blocked = secureStore.blockNextWrite();

    final firstSave = AISettingsDao.saveFor('account-a', first);
    await blocked.started;
    final secondSave = AISettingsDao.saveFor('account-a', second);
    await Future<void>.delayed(Duration.zero);
    expect(secureStore.writeCount, 1);
    blocked.release();
    await Future.wait([firstSave, secondSave]);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-second');
    expect(reloaded.activeProvider.apiHost, 'https://second.example');
  });

  test('条件保存排在普通保存之后时不覆盖已落盘的目标设置', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('account-a');
    final blocked = secureStore.blockNextWrite();

    final userSave =
        AISettingsDao.saveFor('account-a', _settingsWithSecrets('user-first'));
    await blocked.started;
    final guestSave = AISettingsDao.saveForIfAbsent(
      'account-a',
      _settingsWithSecrets('guest-after'),
    );
    blocked.release();

    await userSave;
    expect(await guestSave, isFalse);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-user-first');
    expect(reloaded.tavilyApiKey, 'tavily-user-first');
  });

  test('条件保存排在普通保存之前时由后续用户设置最终获胜', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('account-a');
    final blocked = secureStore.blockNextWrite();

    final guestSave = AISettingsDao.saveForIfAbsent(
      'account-a',
      _settingsWithSecrets('guest-first'),
    );
    await blocked.started;
    final userSave =
        AISettingsDao.saveFor('account-a', _settingsWithSecrets('user-after'));
    blocked.release();

    expect(await guestSave, isTrue);
    await userSave;
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-user-after');
    expect(reloaded.tavilyApiKey, 'tavily-user-after');
  });

  test('条件保存未显式 prepare 时可直接完成且不会自锁', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);

    final imported = await AISettingsDao.saveForIfAbsent(
      'account-a',
      _settingsWithSecrets('unprepared'),
    ).timeout(const Duration(seconds: 5));

    expect(imported, isTrue);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-unprepared');
    expect(reloaded.tavilyApiKey, 'tavily-unprepared');
  });

  test('条件保存写失败后不毒化同账号队列，普通保存可恢复', () async {
    final secureStore = _MemorySecureStore()..failWrites = true;
    AISettingsDao.configureSecretStore(secureStore);

    await expectLater(
      AISettingsDao.saveForIfAbsent(
        'account-a',
        _settingsWithSecrets('conditional-failure'),
      ),
      throwsA(isA<AISecretsUnavailableException>()),
    );

    secureStore.failWrites = false;
    await AISettingsDao.saveFor(
      'account-a',
      _settingsWithSecrets('recovered-normal-save'),
    ).timeout(const Duration(seconds: 5));
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-recovered-normal-save');
    expect(reloaded.tavilyApiKey, 'tavily-recovered-normal-save');
  });

  test('条件保存尊重 clear tombstone，不复活用户已清除的配置', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor(
      'account-a',
      _settingsWithSecrets('user-cleared'),
    );
    await AISettingsDao.clearFor('account-a');
    expect(AISettingsDao.hasSettings('account-a'), isFalse);

    final imported = await AISettingsDao.saveForIfAbsent(
      'account-a',
      _settingsWithSecrets('guest-must-not-return'),
    );

    expect(imported, isFalse);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, isEmpty);
    expect(reloaded.tavilyApiKey, isEmpty);
  });

  test('条件保存直接认领正式账号旧全局配置并拒绝游客导入', () async {
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'account-token',
      userName: 'account-a',
      extras: const {'accountHash': 'account-a'},
    );
    final legacyRaw = jsonEncode(
      _settingsWithSecrets('legacy-global-target').toJson(),
    );
    await HiCache.getInstance().setString('ai_settings_v1', legacyRaw);
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);

    final imported = await AISettingsDao.saveForIfAbsent(
      'account-a',
      _settingsWithSecrets('guest-must-not-overwrite-legacy'),
    );

    expect(imported, isFalse);
    expect(HiCache.getInstance().get('ai_settings_v1'), isNull);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('account-a');
    expect(reloaded.activeProvider.apiKey, 'provider-legacy-global-target');
    expect(reloaded.tavilyApiKey, 'tavily-legacy-global-target');
  });

  test('双槽提交半写新槽时保留上一版完整 secure 快照', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('stable'));
    secureStore.truncateNextWrite = true;

    await expectLater(
      AISettingsDao.saveFor('account-a', _settingsWithSecrets('partial-new')),
      throwsA(isA<AISecretsUnavailableException>()),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-stable');
    expect(loaded.tavilyApiKey, 'tavily-stable');
  });

  test('secure write 已完成但回读瞬时失败时按已提交处理且重启一致', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('old-ack'));
    secureStore.failReadAfterNextWrite = true;

    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('new-ack'));

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-new-ack');
    expect(loaded.tavilyApiKey, 'tavily-new-ack');
  });

  test('secure write 静默未持久化且首次回读异常时拒绝提交并保留旧快照', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('old-safe'));
    secureStore
      ..ignoreNextWrite = true
      ..failReadAfterNextWrite = true;

    await expectLater(
      AISettingsDao.saveFor('account-a', _settingsWithSecrets('lost-write')),
      throwsA(isA<AISecretsUnavailableException>()),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-old-safe');
    expect(loaded.tavilyApiKey, 'tavily-old-safe');
    expect(
      loaded.mcpServers.single.headers['Authorization'],
      'Bearer mcp-old-safe',
    );
  });

  test('secure write 已真实落盘但两次回读异常时重启仍保留旧快照', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('old-safe'));
    secureStore.failReadCountAfterNextWrite = 2;

    await expectLater(
      AISettingsDao.saveFor('account-a', _settingsWithSecrets('unconfirmed')),
      throwsA(isA<AISecretsUnavailableException>()),
    );
    expect(
      secureStore.values[AISettingsDao.secondarySecretKeyFor('account-a')],
      contains('provider-unconfirmed'),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-old-safe');
    expect(loaded.tavilyApiKey, 'tavily-old-safe');
  });

  test('secure 回读为不同的更高 generation 时重启仍保留旧快照', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('old-safe'));
    secureStore.transformNextWrite = (raw) {
      final payload = (jsonDecode(raw) as Map).cast<String, dynamic>();
      payload['generation'] = (payload['generation'] as int) + 100;
      return jsonEncode(payload);
    };

    await expectLater(
      AISettingsDao.saveFor('account-a', _settingsWithSecrets('different')),
      throwsA(isA<AISecretsUnavailableException>()),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-old-safe');
    expect(loaded.tavilyApiKey, 'tavily-old-safe');
  });

  test('quarantine 平台删除失败且内存 cache 已清时重启仍保留旧快照', () async {
    final prefs = HiCache.getInstance().prefs!;
    final preferencesStore = _FailingRemoveSharedPreferencesStore();
    SharedPreferencesStorePlatform.instance = preferencesStore;
    await prefs.reload();
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('old-safe'));
    preferencesStore.failNextRemove = true;

    await expectLater(
      AISettingsDao.saveFor('account-a', _settingsWithSecrets('new-save')),
      throwsA(isA<AISecretsUnavailableException>()),
    );
    expect(
      preferencesStore.values[
          'flutter.ai_settings_secure_verification_quarantine_v1_account-a'],
      AISettingsDao.secondarySecretKeyFor('account-a'),
    );

    AISettingsDao.resetSecureStateForTest();
    await prefs.reload();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-old-safe');
    expect(loaded.tavilyApiKey, 'tavily-old-safe');
  });

  test('新槽读取异常时不回退并覆盖旧槽，恢复后仍加载较新 generation', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('slot-old'));
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('slot-new'));
    final secondary = AISettingsDao.secondarySecretKeyFor('account-a');

    AISettingsDao.resetSecureStateForTest();
    secureStore.failReadKeys.add(secondary);
    AISettingsDao.configureSecretStore(secureStore);
    await expectLater(
      AISettingsDao.loadForAsync('account-a'),
      throwsA(isA<AISecretsUnavailableException>()),
    );

    secureStore.failReadKeys.clear();
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-slot-new');
  });

  test('saveFor 中心边界保留同配置的新 success，并清除改 Key 携带的旧 success', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final initial = _settingsWithSecrets('health');
    await AISettingsDao.saveFor('account-a', initial);

    final tested = initial.clone();
    tested.activeProvider.models.first
      ..lastTestStatus = 'success'
      ..lastTestAt = 123;
    await AISettingsDao.saveFor('account-a', tested);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    var loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.models.first.lastTestStatus, 'success');
    expect(loaded.activeProvider.models.first.lastTestAt, 123);

    loaded.activeProvider.apiKey = 'provider-health-changed';
    await AISettingsDao.saveFor('account-a', loaded);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.models.first.lastTestStatus, 'unknown');
    expect(loaded.activeProvider.models.first.lastTestAt, isNull);
    expect(loaded.activeProvider.models.first.lastTestError, isNull);
  });

  test('Provider 乐观更新立即清除改配置携带的 success，同配置测试结果保留', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final provider = AISettingsProvider();
    final configured = provider.settings.clone()
      ..activeProvider.apiKey = 'provider-health-provider';
    await provider.update(configured);

    final tested = provider.settings.clone();
    tested.activeProvider.models.first
      ..lastTestStatus = 'success'
      ..lastTestAt = 456;
    await provider.update(tested);
    expect(provider.settings.activeProvider.models.first.lastTestStatus,
        'success');

    final changed = provider.settings.clone()
      ..activeProvider.apiHost = 'https://changed.example.com';
    final saving = provider.update(changed);
    expect(
      provider.settings.activeProvider.models.first.lastTestStatus,
      'unknown',
    );
    await saving;
  });

  test('Provider 丢弃测试期间旧配置返回的 success，不覆盖当前配置', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final provider = AISettingsProvider();
    final configured = provider.settings.clone()
      ..activeProvider.apiKey = 'provider-health-race-old';
    await provider.update(configured);
    final providerId = provider.settings.activeProvider.id;
    final modelId = provider.settings.activeProvider.effectiveModelId;
    final expected = AIProviderHealthConfiguration.capture(
      provider.settings.activeProvider,
    );

    final changed = provider.settings.clone()
      ..activeProvider.apiKey = 'provider-health-race-new';
    await provider.update(changed);
    final recorded = await provider.recordModelTestResult(
      providerId: providerId,
      modelId: modelId,
      expectedConfiguration: expected,
      success: true,
    );

    expect(recorded, isFalse);
    expect(provider.settings.activeProvider.apiKey, 'provider-health-race-new');
    expect(
      provider.settings.activeProvider.models
          .firstWhere((model) => model.id == modelId)
          .lastTestStatus,
      'unknown',
    );
  });

  test('Provider 采用 DAO 权威快照，原地改 Key 后不会内存保留 success', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final provider = AISettingsProvider();
    final configured = provider.settings.clone()
      ..activeProvider.apiKey = 'provider-canonical-old';
    await provider.update(configured);

    final tested = provider.settings.clone();
    tested.activeProvider.models.first
      ..lastTestStatus = 'success'
      ..lastTestAt = 789;
    await provider.update(tested);
    expect(provider.settings.activeProvider.models.first.lastTestStatus,
        'success');

    // 模拟旧页面拿到公开可变 settings 后原地编辑；Provider 自身的 previous
    // 已被污染，最终仍必须采用 DAO 基于持久化旧 Key 清理后的权威结果。
    provider.settings.activeProvider.apiKey = 'provider-canonical-new';
    await provider.saveQuietly();

    expect(provider.settings.activeProvider.apiKey, 'provider-canonical-new');
    expect(provider.settings.activeProvider.models.first.lastTestStatus,
        'unknown');
    expect(provider.settings.activeProvider.models.first.lastTestAt, isNull);
  });

  test('Provider 快速连续编辑以最新乐观设置为基线，不会让后操作覆盖新 Key', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final provider = AISettingsProvider();
    final first = provider.settings.clone();
    first.activeProvider
      ..apiKey = 'provider-optimistic'
      ..apiHost = 'https://optimistic.example';
    final blocked = secureStore.blockNextWrite();

    final firstSave = provider.update(first);
    await blocked.started;
    final second = provider.settings.clone()..streamEnabled = false;
    final secondSave = provider.update(second);
    blocked.release();
    await Future.wait([firstSave, secondSave]);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('guest');
    expect(reloaded.activeProvider.apiKey, 'provider-optimistic');
    expect(reloaded.activeProvider.apiHost, 'https://optimistic.example');
    expect(reloaded.streamEnabled, isFalse);
  });

  test('Provider 前一提交快照不会被后一乐观变更污染，后一失败可准确回滚', () async {
    final secureStore = _MemorySecureStore()..failOnWriteNumber = 2;
    AISettingsDao.configureSecretStore(secureStore);
    final provider = AISettingsProvider();
    final first = provider.settings.clone();
    first.activeProvider.apiKey = 'provider-first-committed';
    final blocked = secureStore.blockNextWrite();

    final firstSave = provider.update(first);
    await blocked.started;
    final second = provider.settings.clone()..streamEnabled = false;
    final secondSave = provider.update(second);
    blocked.release();
    await firstSave;
    await expectLater(
      secondSave,
      throwsA(isA<AISecretsUnavailableException>()),
    );

    expect(provider.settings.activeProvider.apiKey, 'provider-first-committed');
    expect(provider.settings.streamEnabled, isTrue);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final reloaded = await AISettingsDao.loadForAsync('guest');
    expect(reloaded.activeProvider.apiKey, 'provider-first-committed');
    expect(reloaded.streamEnabled, isTrue);
  });

  test('页面绑定旧账号后发生登录态切换时拒绝把旧 Key 写入新账号', () async {
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'token-a',
      userName: 'account-a',
      extras: const {'accountHash': 'account-a'},
    );
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final provider = AISettingsProvider();
    await provider.load();
    final oldPageAccount = provider.accountHash;
    final oldPageSettings = provider.settings.clone();
    oldPageSettings.activeProvider.apiKey = 'account-a-page-key';

    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'token-b',
      userName: 'account-b',
      extras: const {'accountHash': 'account-b'},
    );
    await provider.load();

    await expectLater(
      provider.update(
        oldPageSettings,
        expectedAccountHash: oldPageAccount,
      ),
      throwsA(isA<AISettingsAccountChangedException>()),
    );
    expect(AISettingsDao.hasSettings('account-b'), isFalse);
    expect(
      secureStore.values[AISettingsDao.secretKeyFor('account-b')],
      isNull,
    );
  });

  test('正常保存先提交 secure v2，普通区从未出现凭据且可恢复中断', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    Object? plainAtSecureWrite;
    secureStore.onWrite = () {
      plainAtSecureWrite =
          HiCache.getInstance().get(AISettingsDao.keyFor('account-a'));
    };

    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('journal'));

    expect(plainAtSecureWrite, isNull);
    final finalPlain = _plainSettingsJson('account-a');
    expect(finalPlain['_secretStorage'], 'secure-v1');
    expect(_providerKey(finalPlain, 'deepseek'), isEmpty);

    // 模拟 secure 已提交、进程在普通脱敏副本落盘前退出。
    await HiCache.getInstance().prefs?.remove(
          AISettingsDao.keyFor('account-a'),
        );
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final recovered = await AISettingsDao.loadForAsync('account-a');
    expect(recovered.activeProvider.apiKey, 'provider-journal');
    expect(recovered.tavilyApiKey, 'tavily-journal');
    expect(_plainSettingsJson('account-a')['_secretStorage'], 'secure-v1');
  });

  test('secure 成功但普通脱敏写失败时同进程下一次读取从 v2 修复', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    AISettingsDao.plainWriteOverrideForTest = (key, value) async => false;

    await AISettingsDao.saveFor(
      'account-a',
      _settingsWithSecrets('plain-fail'),
    );

    AISettingsDao.plainWriteOverrideForTest = null;
    final recovered = await AISettingsDao.loadForAsync('account-a');
    expect(recovered.activeProvider.apiKey, 'provider-plain-fail');
    expect(recovered.tavilyApiKey, 'tavily-plain-fail');
    expect(_plainSettingsJson('account-a')['_secretStorage'], 'secure-v1');
  });

  test('更旧或无 generation 的 pending 不能覆盖更新的 secure v2', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final latest = _settingsWithSecrets('latest')
      ..activeProvider.apiHost = 'https://latest.example';
    await AISettingsDao.saveFor('account-a', latest);

    final staleJson = _settingsWithSecrets('stale').toJson()
      ..['_secretWritePending'] = true;
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(staleJson),
    );
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);

    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-latest');
    expect(loaded.activeProvider.apiHost, 'https://latest.example');
  });

  test('generation 更高的 pending 是安全存储失败后的权威恢复副本', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('old'));
    final secureRaw = jsonDecode(
      secureStore.values[AISettingsDao.secretKeyFor('account-a')]!,
    ) as Map<String, dynamic>;
    final pendingJson = _settingsWithSecrets('pending').toJson()
      ..['_secretWritePending'] = true
      ..['_secretGeneration'] = (secureRaw['generation'] as int) + 1;
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(pendingJson),
    );
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);

    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-pending');
    expect(loaded.tavilyApiKey, 'tavily-pending');
    expect(_plainSettingsJson('account-a')['_secretStorage'], 'secure-v1');
  });

  test('v1 secrets-only payload 在 plain marker 丢失时仍可无损升级', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('seed'));
    secureStore.values[AISettingsDao.secretKeyFor('account-a')] =
        jsonEncode(_v1Secrets('v1'));
    final plain = _plainSettingsJson('account-a')..remove('_secretStorage');
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      jsonEncode(plain),
    );
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);

    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-v1');
    expect(loaded.tavilyApiKey, 'tavily-v1');
    expect(loaded.mcpServers.single.headers['Authorization'], 'Bearer mcp-v1');
    expect(_latestSecureJson(secureStore, 'account-a')['_schema'], 2);
  });

  test('损坏 plain 搭配 v1 secrets-only 时阻止覆盖', () async {
    final secureStore = _MemorySecureStore();
    secureStore.values[AISettingsDao.secretKeyFor('account-a')] =
        jsonEncode(_v1Secrets('protected-v1'));
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      '{"providers": [',
    );
    AISettingsDao.configureSecretStore(secureStore);

    await expectLater(
      AISettingsDao.loadForAsync('account-a'),
      throwsA(
        isA<AISecretsUnavailableException>()
            .having((error) => error.corrupt, 'corrupt', isTrue),
      ),
    );
    expect(
      secureStore.values[AISettingsDao.secretKeyFor('account-a')],
      jsonEncode(_v1Secrets('protected-v1')),
    );
  });

  test('secure 合法 JSON 缺字段或 v2 secrets 不一致时按损坏处理', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('strict'));
    final secureKey = AISettingsDao.secretKeyFor('account-a');

    for (final corrupted in <String>[
      '{}',
      (() {
        final json = (jsonDecode(secureStore.values[secureKey]!) as Map)
            .cast<String, dynamic>()
          ..remove('_schema');
        return jsonEncode(json);
      })(),
      (() {
        final json = (jsonDecode(secureStore.values[secureKey]!) as Map)
            .cast<String, dynamic>();
        final secrets = (json['secrets'] as Map).cast<String, dynamic>();
        final providerKeys =
            (secrets['providerApiKeys'] as Map).cast<String, dynamic>();
        providerKeys['deepseek'] = 'tampered';
        return jsonEncode(json);
      })(),
    ]) {
      secureStore.values[secureKey] = corrupted;
      AISettingsDao.resetSecureStateForTest();
      AISettingsDao.configureSecretStore(secureStore);
      await expectLater(
        AISettingsDao.loadForAsync('account-a'),
        throwsA(
          isA<AISecretsUnavailableException>()
              .having((error) => error.corrupt, 'corrupt', isTrue),
        ),
      );
    }
  });

  test('重复 provider 或 MCP id 在覆盖 secure 前被拒绝且旧快照仍可恢复', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('account-a', _settingsWithSecrets('valid'));

    final duplicateProvider = _settingsWithSecrets('duplicate-provider');
    duplicateProvider.providers.add(
      duplicateProvider.activeProvider.copy()..apiKey = 'conflicting-key',
    );
    await expectLater(
      AISettingsDao.saveFor('account-a', duplicateProvider),
      throwsA(isA<FormatException>()),
    );

    final duplicateMcp = _settingsWithSecrets('duplicate-mcp');
    duplicateMcp.mcpServers.add(
      duplicateMcp.mcpServers.single.copyWith(
        headers: const {'Authorization': 'conflicting-header'},
      ),
    );
    await expectLater(
      AISettingsDao.saveFor('account-a', duplicateMcp),
      throwsA(isA<FormatException>()),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiKey, 'provider-valid');
    expect(
        loaded.mcpServers.single.headers['Authorization'], 'Bearer mcp-valid');
  });

  test('clear tombstone 阻止删除失败的 secure 快照复活并在启动重试清理', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('guest', _settingsWithSecrets('clear'));
    final secureKey = AISettingsDao.secretKeyFor('guest');
    secureStore.failDeletes = true;

    await AISettingsDao.clear();
    expect(secureStore.values[secureKey], isNotNull);
    expect(AISettingsDao.hasSettings('guest'), isFalse);

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    var loaded = await AISettingsDao.loadForAsync('guest');
    expect(loaded.activeProvider.apiKey, isEmpty);

    AISettingsDao.resetSecureStateForTest();
    secureStore.failDeletes = false;
    AISettingsDao.configureSecretStore(secureStore);
    loaded = await AISettingsDao.loadForAsync('guest');
    expect(loaded.activeProvider.apiKey, isEmpty);
    expect(secureStore.values[secureKey], isNull);
  });

  test('clear 删除失败后重配先清残留槽并沿用更高 generation', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('guest', _settingsWithSecrets('old-clear'));
    await AISettingsDao.saveFor('guest', _settingsWithSecrets('old-clear-2'));
    secureStore.failDeletes = true;
    await AISettingsDao.clear();

    secureStore.failDeletes = false;
    await AISettingsDao.saveFor('guest', _settingsWithSecrets('reconfigured'));

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('guest');
    expect(loaded.activeProvider.apiKey, 'provider-reconfigured');
    expect(loaded.tavilyApiKey, 'tavily-reconfigured');
  });

  test('clear 后普通区替换失败不会把会被 tombstone 删除的新 secure 报为成功', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.saveFor('guest', _settingsWithSecrets('before-clear'));
    await AISettingsDao.clear();
    AISettingsDao.plainWriteOverrideForTest = (key, value) async => false;

    await expectLater(
      AISettingsDao.saveFor('guest', _settingsWithSecrets('after-clear')),
      throwsA(isA<StateError>()),
    );

    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('guest');
    expect(loaded.activeProvider.apiKey, isEmpty);
    expect(
      secureStore.values[AISettingsDao.secretKeyFor('guest')],
      isNull,
    );
    expect(
      secureStore.values[AISettingsDao.secondarySecretKeyFor('guest')],
      isNull,
    );
  });

  test('凭据自助修复保留可读的非敏感 provider 与 MCP 配置', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    final settings = _settingsWithSecrets('repair')
      ..activeProvider.apiHost = 'https://custom.example'
      ..searchMaxResults = 9;
    await AISettingsDao.saveFor('account-a', settings);
    secureStore.values[AISettingsDao.secretKeyFor('account-a')] = '{broken';

    final preserved = await AISettingsDao.resetCredentialsFor('account-a');

    expect(preserved, isTrue);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secureStore);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.activeProvider.apiHost, 'https://custom.example');
    expect(loaded.searchMaxResults, 9);
    expect(loaded.mcpServers.single.url, 'https://example.com/mcp');
    expect(loaded.activeProvider.apiKey, isEmpty);
    expect(loaded.mcpServers.single.headers, isEmpty);
  });

  test('clear 与进行中的 save 串行，最后调用的清除不会被旧保存撤销', () async {
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);
    await AISettingsDao.prepareAccount('guest');
    final blocked = secureStore.blockNextWrite();

    final saving = AISettingsDao.saveFor('guest', _settingsWithSecrets('race'));
    await blocked.started;
    final clearing = AISettingsDao.clear();
    blocked.release();
    await Future.wait([saving, clearing]);

    expect(AISettingsDao.hasSettings('guest'), isFalse);
    expect((await AISettingsDao.loadForAsync('guest')).activeProvider.apiKey,
        isEmpty);
  });

  test('账号 key 与旧全局 key 同时存在时成功迁移后清理旧明文', () async {
    final settings = _settingsWithSecrets('duplicate-old-key');
    final raw = jsonEncode(settings.toJson());
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'guest-mode',
      userName: 'guest',
      extras: const {'accountHash': 'guest'},
    );
    await HiCache.getInstance().setString(AISettingsDao.keyFor('guest'), raw);
    await HiCache.getInstance().setString('ai_settings_v1', raw);
    final secureStore = _MemorySecureStore();
    AISettingsDao.configureSecretStore(secureStore);

    final loaded = await AISettingsDao.loadForAsync('guest');

    expect(loaded.activeProvider.apiKey, 'provider-duplicate-old-key');
    expect(HiCache.getInstance().get('ai_settings_v1'), isNull);
    expect(_plainSettingsJson('guest')['_secretStorage'], 'secure-v1');
  });

  test('账号配置与旧全局 key 来源不同时不误删旧明文', () async {
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'account-token',
      userName: 'account-a',
      extras: const {'accountHash': 'account-a'},
    );
    final accountRaw = jsonEncode(_settingsWithSecrets('account').toJson());
    final unrelatedOldRaw = jsonEncode(
      (_settingsWithSecrets('unrelated')
            ..streamEnabled = false
            ..maxOutputTokens = 1234)
          .toJson(),
    );
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('account-a'),
      accountRaw,
    );
    await HiCache.getInstance().setString('ai_settings_v1', unrelatedOldRaw);
    AISettingsDao.configureSecretStore(_MemorySecureStore());

    final loaded = await AISettingsDao.loadForAsync('account-a');

    expect(loaded.activeProvider.apiKey, 'provider-account');
    expect(HiCache.getInstance().get('ai_settings_v1'), unrelatedOldRaw);
  });

  test('尚未登录时不会把旧全局设置提前迁入 guest', () async {
    final oldRaw = jsonEncode(_settingsWithSecrets('real-user').toJson());
    await HiCache.getInstance().setString('ai_settings_v1', oldRaw);
    AISettingsDao.configureSecretStore(_MemorySecureStore());

    expect(AISettingsDao.load().activeProvider.apiKey, isEmpty);
    final guest = await AISettingsDao.loadForAsync('guest');

    expect(guest.activeProvider.apiKey, isEmpty);
    expect(HiCache.getInstance().get('ai_settings_v1'), oldRaw);
    expect(HiCache.getInstance().get(AISettingsDao.keyFor('guest')), isNull);
  });
}

AISettings _settingsWithSecrets(String suffix) {
  final settings = AISettings.defaults();
  settings.activeProvider.apiKey = 'provider-$suffix';
  return settings
    ..tavilyApiKey = 'tavily-$suffix'
    ..exaApiKey = 'exa-$suffix'
    ..bochaApiKey = 'bocha-$suffix'
    ..zhipuApiKey = 'zhipu-$suffix'
    ..mcpServers = [
      McpServerConfig(
        id: 'remote-mcp',
        name: 'Remote MCP',
        url: 'https://example.com/mcp',
        headers: {'Authorization': 'Bearer mcp-$suffix'},
      ),
    ];
}

Map<String, dynamic> _v1Secrets(String suffix) => {
      'providerApiKeys': {'deepseek': 'provider-$suffix'},
      'tavilyApiKey': 'tavily-$suffix',
      'exaApiKey': 'exa-$suffix',
      'bochaApiKey': 'bocha-$suffix',
      'zhipuApiKey': 'zhipu-$suffix',
      'mcpHeaders': {
        'remote-mcp': {'Authorization': 'Bearer mcp-$suffix'},
      },
    };

Map<String, dynamic> _plainSettingsJson(String hash) {
  final raw = HiCache.getInstance().get(AISettingsDao.keyFor(hash)) as String;
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

Map<String, dynamic> _latestSecureJson(
  _MemorySecureStore store,
  String hash,
) {
  final candidates = <Map<String, dynamic>>[];
  for (final key in [
    AISettingsDao.secretKeyFor(hash),
    AISettingsDao.secondarySecretKeyFor(hash),
  ]) {
    final raw = store.values[key];
    if (raw == null) continue;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (json['_schema'] == 2) candidates.add(json);
    } catch (_) {}
  }
  candidates.sort(
    (left, right) =>
        (left['generation'] as int).compareTo(right['generation'] as int),
  );
  return candidates.last;
}

String _providerKey(Map<String, dynamic> json, String providerId) {
  final provider = (json['providers'] as List)
      .cast<Map>()
      .firstWhere((entry) => entry['id'] == providerId);
  return provider['apiKey'] as String;
}

class _FailingRemoveSharedPreferencesStore
    extends SharedPreferencesStorePlatform {
  final Map<String, Object> values = {};
  bool failNextRemove = false;

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);

  @override
  Future<bool> remove(String key) async {
    if (failNextRemove) {
      failNextRemove = false;
      return false;
    }
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values[key] = value is List<String> ? value.toList() : value;
    return true;
  }
}

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};
  bool failReads = false;
  final Set<String> failReadKeys = {};
  bool failReadAfterNextWrite = false;
  int failReadCountAfterNextWrite = 0;
  bool _failNextRead = false;
  int _remainingReadFailures = 0;
  bool failWrites = false;
  int? failOnWriteNumber;
  bool failDeletes = false;
  bool truncateNextWrite = false;
  bool ignoreNextWrite = false;
  String Function(String value)? transformNextWrite;
  int writeCount = 0;
  void Function()? onWrite;
  Completer<void>? _nextWriteStarted;
  Completer<void>? _nextWriteGate;

  ({Future<void> started, void Function() release}) blockNextWrite() {
    final started = Completer<void>();
    final gate = Completer<void>();
    _nextWriteStarted = started;
    _nextWriteGate = gate;
    return (
      started: started.future,
      release: () {
        if (!gate.isCompleted) gate.complete();
      },
    );
  }

  @override
  Future<String?> read(String key) async {
    if (_remainingReadFailures > 0) {
      _remainingReadFailures--;
      throw StateError('secure read acknowledgement failed');
    }
    if (_failNextRead) {
      _failNextRead = false;
      throw StateError('secure read acknowledgement failed');
    }
    if (failReads || failReadKeys.contains(key)) {
      throw StateError('secure read failed');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    if (failWrites || writeCount == failOnWriteNumber) {
      throw StateError('secure write failed');
    }
    onWrite?.call();
    final started = _nextWriteStarted;
    final gate = _nextWriteGate;
    _nextWriteStarted = null;
    _nextWriteGate = null;
    if (started != null && !started.isCompleted) started.complete();
    if (gate != null) await gate.future;
    if (truncateNextWrite) {
      truncateNextWrite = false;
      values[key] = value.substring(0, value.length.clamp(1, 24).toInt());
      return;
    }
    final transform = transformNextWrite;
    transformNextWrite = null;
    if (ignoreNextWrite) {
      ignoreNextWrite = false;
    } else if (transform != null) {
      values[key] = transform(value);
    } else {
      values[key] = value;
    }
    if (failReadCountAfterNextWrite > 0) {
      _remainingReadFailures = failReadCountAfterNextWrite;
      failReadCountAfterNextWrite = 0;
    }
    if (failReadAfterNextWrite) {
      failReadAfterNextWrite = false;
      _failNextRead = true;
    }
  }

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('secure delete failed');
    values.remove(key);
  }
}
