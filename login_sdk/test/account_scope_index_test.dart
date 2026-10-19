import 'dart:convert';

import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/account_scope_index.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late String oldHost;
  late bool oldHttps;

  setUp(() async {
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'scope-a.example';
    BackendConfig.useHttps = true;
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
  });

  tearDown(() {
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
  });

  Future<void> seedLegacy() async {
    // 模拟升级前保存的分区，与当前 hashCode 不同；没有任何分区索引。
    await HiCache.getInstance().prefs!.setString(
        'user_info',
        jsonEncode({
          'boardingPass': 'old-token',
          'userName': 'alice',
          'accountHash': 'historical-alice',
        }));
  }

  test('旧普通存储重启并退出后，重登仍复用历史分区', () async {
    await seedLegacy();
    final old = HiCacheTokenStorage();
    await old.initialize();
    await old.clear();
    expect(old.readProfileSync(), isNull);

    final restarted = HiCacheTokenStorage();
    await restarted.initialize();
    await restarted.writeProfile(token: 'new-token', userName: 'alice');
    expect(restarted.readProfileSync()?['accountHash'], 'historical-alice');
    expect(restarted.readTokenSync(), 'new-token');
  });

  test('HUKS/安全存储迁移、登出及新实例重登保留旧分区', () async {
    await seedLegacy();
    final secure = _SecureStore();
    final old = MigratingTokenStorage(secureStore: secure);
    await old.initialize();
    await old.clear();
    expect(old.readProfileSync(), isNull);

    final restarted = MigratingTokenStorage(secureStore: secure);
    await restarted.initialize();
    await restarted.writeProfile(token: 'new-token', userName: 'alice');
    expect(restarted.readProfileSync()?['accountHash'], 'historical-alice');
    final again = MigratingTokenStorage(secureStore: secure);
    await again.initialize();
    expect(again.readProfileSync()?['accountHash'], 'historical-alice');
    expect(HiCacheTokenStorage().readProfileSync(), isNull);
  });

  test('游客不覆盖同名正式账号的分区索引', () async {
    final storage = HiCacheTokenStorage();
    await storage.writeProfile(
        token: 'real',
        userName: '游客',
        extras: const {'accountHash': 'real-scope'});
    await storage.clear();
    await storage.writeProfile(
        token: 'guest-mode',
        userName: '游客',
        extras: const {'accountHash': 'guest', 'guest': true});
    await storage.clear();
    await storage.writeProfile(token: 'real-again', userName: '游客');
    expect(storage.readProfileSync()?['accountHash'], 'real-scope');
  });

  test('不同账号及不同后端不复用原账号索引', () async {
    await seedLegacy();
    final storage = HiCacheTokenStorage();
    await storage.initialize();
    await storage.clear();
    expect(AccountScopeIndex.resolve('bob', const {}), 'bob'.hashCode);
    BackendConfig.host = 'scope-b.example';
    expect(AccountScopeIndex.resolve('alice', const {}), 'alice'.hashCode);
    BackendConfig.host = 'scope-a.example';
    expect(AccountScopeIndex.resolve('alice', const {}), 'historical-alice');
  });

  test('已确认的显式分区修复在后续重登保留，索引不含凭据或用户名', () async {
    final storage = HiCacheTokenStorage();
    await storage.writeProfile(
        token: 'private-token',
        userName: 'alice',
        extras: const {'accountHash': 'repaired-scope'});
    await storage.clear();
    final prefs = HiCache.getInstance().prefs!;
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith('login_account_scope_v1_'));
    expect(keys, hasLength(1));
    expect(keys.single, isNot(contains('alice')));
    expect(prefs.getString(keys.single), jsonEncode('repaired-scope'));
    expect(prefs.getString(keys.single), isNot(contains('private-token')));
    await storage.writeProfile(token: 'new-token', userName: 'alice');
    expect(storage.readProfileSync()?['accountHash'], 'repaired-scope');
  });

  test('损坏索引不静默切换空白分区，保留登录态且允许明确修复', () async {
    final storage = HiCacheTokenStorage();
    await storage.writeProfile(
        token: 'old-token',
        userName: 'alice',
        extras: const {'accountHash': 'historical-alice'});
    final prefs = HiCache.getInstance().prefs!;
    final key = prefs
        .getKeys()
        .singleWhere((key) => key.startsWith('login_account_scope_v1_'));
    await prefs.setString(key, 'broken-json');
    await expectLater(
        storage.writeProfile(token: 'new-token', userName: 'alice'),
        throwsStateError);
    expect(storage.readTokenSync(), 'old-token');
    expect(storage.readProfileSync()?['accountHash'], 'historical-alice');
    await storage.writeProfile(
        token: 'repaired-token',
        userName: 'alice',
        extras: const {'accountHash': 'historical-alice'});
    expect(storage.readTokenSync(), 'repaired-token');
  });
}

class _SecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
