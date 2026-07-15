import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/secure_key_value_store.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _MemorySecureStore secure;
  late _MemoryTokenStorage legacy;

  setUp(() async {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    secure = _MemorySecureStore();
    legacy = _MemoryTokenStorage();
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  test('首次启动迁移旧登录态但保留一轮旧值', () async {
    await legacy.writeProfile(
      token: 'legacy-token',
      userName: 'alice',
      extras: const {'accountHash': 'stable-alice'},
    );
    final storage = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );

    await storage.initialize();

    expect(storage.readTokenSync(), 'legacy-token');
    expect(storage.readProfileSync()?['accountHash'], 'stable-alice');
    expect(legacy.readTokenSync(), 'legacy-token');
    expect(secure.values[MigratingTokenStorage.secureProfileKey], isNotNull);
  });

  test('第二次启动读回安全值后才删除旧登录态', () async {
    await legacy.writeProfile(token: 'token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();

    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restarted.initialize();

    expect(restarted.readTokenSync(), 'token');
    expect(legacy.readTokenSync(), isNull);
  });

  test('安全存储异常时继续使用旧值，不要求用户重新登录', () async {
    await legacy.writeProfile(token: 'fallback-token', userName: 'alice');
    secure
      ..failRead = true
      ..failWrite = true;

    final storage = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await storage.initialize();

    expect(storage.readTokenSync(), 'fallback-token');
    expect(legacy.readTokenSync(), 'fallback-token');
  });

  test('登出 tombstone 阻止删除失败的安全 token 在重启后复活', () async {
    await legacy.writeProfile(token: 'token', userName: 'alice');
    final storage = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await storage.initialize();
    secure.failDelete = true;

    await storage.clear();
    expect(secure.values[MigratingTokenStorage.secureProfileKey], isNotNull);

    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restarted.initialize();

    expect(restarted.readTokenSync(), isNull);
    expect(legacy.readTokenSync(), isNull);
  });

  test('验证完成后的新登录只写安全存储', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    final verified = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await verified.initialize();

    await verified.writeProfile(token: 'new-token', userName: 'alice');

    expect(verified.readTokenSync(), 'new-token');
    expect(legacy.readTokenSync(), isNull);
    expect(
      secure.values[MigratingTokenStorage.secureProfileKey],
      contains('new-token'),
    );
  });

  test('验证完成后的新 token 从未经过 legacy 明文存储', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    final verified = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await verified.initialize();
    legacy.writtenTokens.clear();

    await verified.writeProfile(token: 'new-token', userName: 'alice');

    expect(legacy.writtenTokens, isEmpty);
    expect(legacy.readTokenSync(), isNull);
    expect(verified.readTokenSync(), 'new-token');
  });

  test('verified 前遗留的旧 legacy 无法清理时拒绝更新且保留旧安全会话', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    legacy.failClears = true;
    final verified = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await verified.initialize();
    expect(legacy.readTokenSync(), 'old-token');

    await expectLater(
      verified.writeProfile(token: 'new-token', userName: 'alice'),
      throwsA(isA<SecureStorageUnavailableException>()),
    );

    expect(verified.readTokenSync(), 'old-token');
    expect(legacy.readTokenSync(), 'old-token');
    expect(
      secure.values[MigratingTokenStorage.secureProfileKey],
      allOf(contains('old-token'), isNot(contains('new-token'))),
    );
  });

  test('verified 状态下 secure 与 legacy 冲突时以较新的 legacy 为准', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();

    // 模拟新登录已写入 legacy、但进程在 migration state 更新前退出。
    await legacy.writeProfile(token: 'new-token', userName: 'alice');
    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restarted.initialize();

    expect(restarted.readTokenSync(), 'new-token');
    expect(
      secure.values[MigratingTokenStorage.secureProfileKey],
      contains('new-token'),
    );
  });

  test('secure profile 缺少有效 token 时不会覆盖可用 legacy 登录态', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();

    secure.values[MigratingTokenStorage.secureProfileKey] =
        '{"userName":"alice","boardingPass":42}';
    await legacy.writeProfile(token: 'valid-token', userName: 'alice');
    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restarted.initialize();

    expect(restarted.readTokenSync(), 'valid-token');
  });

  test('verified secure profile 缺少 accountHash 时可从 userName 恢复', () async {
    await legacy.writeProfile(token: 'token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    secure.values[MigratingTokenStorage.secureProfileKey] =
        '{"userName":"alice","boardingPass":"token"}';
    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );

    await restarted.initialize();

    expect(restarted.readTokenSync(), 'token');
    expect(
      restarted.readProfileSync()?['accountHash'],
      'alice'.hashCode,
    );
  });

  test('verified 后 secure read 异常不会被误判为登出，恢复后同实例可重试', () async {
    await legacy.writeProfile(token: 'token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    secure.failRead = true;
    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );

    await expectLater(
      restarted.initialize(),
      throwsA(isA<SecureStorageUnavailableException>()),
    );
    secure.failRead = false;
    await restarted.initialize();

    expect(restarted.readTokenSync(), 'token');
  });

  test('系统恢复仅带回 verified marker 时安全登出并允许重新登录', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    secure.values.remove(MigratingTokenStorage.secureProfileKey);

    final restoredDevice = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restoredDevice.initialize();
    expect(restoredDevice.readTokenSync(), isNull);

    await restoredDevice.writeProfile(token: 'new-token', userName: 'alice');
    expect(restoredDevice.readTokenSync(), 'new-token');
    expect(
      secure.values[MigratingTokenStorage.secureProfileKey],
      contains('new-token'),
    );
  });

  test('verified 后 secure write 静默未生效时拒绝明文降级并恢复旧 token', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    final verified = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await verified.initialize();

    secure.ignoreWrites = true;
    await expectLater(
      verified.writeProfile(token: 'new-token', userName: 'alice'),
      throwsA(isA<SecureStorageUnavailableException>()),
    );
    expect(verified.readTokenSync(), 'old-token');
    expect(legacy.readTokenSync(), isNull);
    expect(
      secure.values[MigratingTokenStorage.secureProfileKey],
      contains('old-token'),
    );

    secure.ignoreWrites = false;
    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restarted.initialize();
    expect(restarted.readTokenSync(), 'old-token');
  });

  test('verified 后无法验证 secure 回滚时安全登出且不保留明文 token', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    final verified = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await verified.initialize();

    secure.failWrite = true;
    await expectLater(
      verified.writeProfile(token: 'new-token', userName: 'alice'),
      throwsA(isA<SecureStorageUnavailableException>()),
    );

    expect(verified.readTokenSync(), isNull);
    expect(legacy.readTokenSync(), isNull);

    secure.failWrite = false;
    final restarted = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await restarted.initialize();
    expect(restarted.readTokenSync(), isNull);
  });

  test('LoginDao 不会把 verified 写失败后的安全登出降级回明文旧 token', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    final verified = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await verified.initialize();
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const <String, String>{},
      syncHeaders: () => const <String, String>{},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: verified,
      onLogoutNavigate: () {},
    ));

    secure.failWrite = true;
    await expectLater(
      LoginDao.saveAuthToken('new-token', userName: 'alice'),
      throwsA(isA<SecureStorageUnavailableException>()),
    );

    expect(LoginDao.getBoardingPass(), isNull);
    expect(legacy.readTokenSync(), isNull);
  });

  test('迁移未验证阶段 legacy durable 写入失败时内存不会提前切到新 token', () async {
    await legacy.writeProfile(token: 'old-token', userName: 'alice');
    final awaitingVerification = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    );
    await awaitingVerification.initialize();
    legacy.failWrites = true;

    await expectLater(
      awaitingVerification.writeProfile(token: 'new-token', userName: 'alice'),
      throwsStateError,
    );

    expect(awaitingVerification.readTokenSync(), 'old-token');
  });

  test('readOnly 后台恢复不写 secure、不清 legacy、不改迁移状态', () async {
    await legacy.writeProfile(token: 'token', userName: 'alice');
    await MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
    ).initialize();
    final writesBefore = secure.writeCount;
    final clearsBefore = legacy.clearCount;
    final readOnly = MigratingTokenStorage(
      secureStore: secure,
      legacyStorage: legacy,
      readOnly: true,
    );

    await readOnly.initialize();

    expect(readOnly.readTokenSync(), 'token');
    expect(secure.writeCount, writesBefore);
    expect(legacy.clearCount, clearsBefore);
  });
}

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  bool ignoreWrites = false;
  int writeCount = 0;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('read failed');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    if (failWrite) throw StateError('write failed');
    if (ignoreWrites) return;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('delete failed');
    values.remove(key);
  }
}

class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? profile;
  int clearCount = 0;
  bool failWrites = false;
  bool failClears = false;
  final List<String> writtenTokens = [];

  @override
  Future<void> clear() async {
    clearCount++;
    if (failClears) throw StateError('legacy clear failed');
    profile = null;
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      profile == null ? null : Map<String, dynamic>.from(profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    if (failWrites) throw StateError('legacy write failed');
    writtenTokens.add(token);
    profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode,
      ...extras,
    };
  }
}
