import 'dart:convert';

import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/config/secure_key_value_store.dart';

import 'account_scope_index.dart';

/// 登录态持久化适配器。默认实现 [HiCacheTokenStorage] 走仓库现有的
/// flutter_hi_cache；想换 shared_preferences / flutter_secure_storage
/// 只要实现这个接口并在 [LoginSdkConfig.install] 时注入。
///
/// 注意：[readTokenSync] / [readProfileSync] 是同步访问，给 [LoginDao.getBoardingPass]
/// 等历史同步 API 兜底用。新增功能尽量走异步 [readToken] / [readProfile]。
abstract class TokenStorage {
  /// 异步读 token（推荐路径）
  Future<String?> readToken();

  /// 异步读完整 profile
  Future<Map<String, dynamic>?> readProfile();

  /// 同步读 token —— 给历史同步 API 兜底；存储后端不支持同步时返回 null。
  String? readTokenSync();

  /// 同步读 profile —— 同上。
  Map<String, dynamic>? readProfileSync();

  /// 写入 token + profile。profile 至少包含 userName，用于派生 accountHash。
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras,
  });

  /// 清空
  Future<void> clear();
}

/// 需要在历史同步读取 API 生效前完成预热的登录存储。
///
/// 单独使用扩展接口，避免破坏现有实现了 [TokenStorage] 的宿主与测试 fake。
abstract interface class InitializableTokenStorage {
  Future<void> initialize();
}

/// 平台安全存储当前无法可靠读取。调用方应重试，不能把它当成“未登录”。
class SecureStorageUnavailableException implements Exception {
  final String operation;
  final bool corrupt;
  final Object? cause;

  const SecureStorageUnavailableException(
    this.operation, {
    this.corrupt = false,
    this.cause,
  });

  @override
  String toString() => corrupt
      ? 'Secure storage data is corrupt during $operation'
      : 'Secure storage is unavailable during $operation';
}

/// 用仓库现有的 flutter_hi_cache 做持久化。kUserInfo 与原 LoginDao 保持一致，
/// 便于无缝替换（旧账号无须重新登录）。
class HiCacheTokenStorage implements TokenStorage, InitializableTokenStorage {
  static const _kUserInfo = 'user_info';

  @override
  Future<void> initialize() => AccountScopeIndex.remember(_decode());

  Map<String, dynamic>? _decode() {
    final s = HiCache.getInstance().get(_kUserInfo);
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  String? readTokenSync() => _decode()?['boardingPass'] as String?;

  @override
  Map<String, dynamic>? readProfileSync() => _decode();

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    final map = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': AccountScopeIndex.resolve(userName, extras),
      AccountScopeIndex.originField: AccountScopeIndex.origin,
      ...extras,
    };
    await AccountScopeIndex.remember(map);
    final prefs = HiCache.getInstance().prefs;
    if (prefs == null || !await prefs.setString(_kUserInfo, jsonEncode(map))) {
      throw StateError('登录态写入失败');
    }
  }

  @override
  Future<void> clear() async {
    // 索引失败也必须允许退出；凭据清理优先于保留分区元数据。
    try {
      await AccountScopeIndex.remember(_decode());
    } catch (_) {}
    final prefs = HiCache.getInstance().prefs;
    if (prefs == null || !await prefs.remove(_kUserInfo)) {
      throw StateError('登录态删除失败');
    }
  }
}

/// 把既有 HiCache 登录态无感迁移到平台安全存储。
///
/// 兼容原则：
/// - 首次迁移先写安全存储，保留旧值；下一次成功读回后才删除旧值。
/// - 安全存储异常时继续使用旧值，不让升级用户被迫重新登录。
/// - 登出先写 tombstone；即使安全存储删除暂时失败，旧 token 也不会复活。
class MigratingTokenStorage implements TokenStorage, InitializableTokenStorage {
  static const secureProfileKey = 'login_profile_v1';
  static const _migrationStateKey = 'secure_login_profile_state_v1';
  static const _awaitingVerification = 'awaiting_verification';
  static const _verified = 'verified';
  static const _cleared = 'cleared';

  final SecureKeyValueStore secureStore;
  final TokenStorage legacyStorage;
  final bool readOnly;

  Map<String, dynamic>? _profile;
  bool _initialized = false;
  Future<void>? _initializing;

  MigratingTokenStorage({
    required this.secureStore,
    TokenStorage? legacyStorage,
    this.readOnly = false,
  }) : legacyStorage = legacyStorage ?? HiCacheTokenStorage();

  @override
  Future<void> initialize() {
    final current = _initializing;
    if (current != null) return current;
    if (_initialized) return Future<void>.value();

    late final Future<void> future;
    future = _initialize().then((_) async {
      if (!readOnly) await AccountScopeIndex.remember(_profile);
    }).catchError((Object error) {
      _initialized = false;
      throw error;
    }).whenComplete(() {
      if (identical(_initializing, future)) _initializing = null;
    });
    _initializing = future;
    return future;
  }

  Future<void> _initialize() async {
    final state = _readMigrationState();
    if (state == _cleared) {
      _profile = null;
      if (!readOnly) {
        await _bestEffort(legacyStorage.clear);
        await _bestEffort(() => secureStore.delete(secureProfileKey));
      }
      _initialized = true;
      return;
    }

    final legacyProfile = await _safeLegacyProfile();
    Map<String, dynamic>? secureProfile;
    var secureWasCorrupt = false;
    try {
      secureProfile = await _readSecureProfile();
    } on SecureStorageUnavailableException catch (error) {
      if (legacyProfile == null || (state == _verified && !error.corrupt)) {
        rethrow;
      }
      if (!error.corrupt) {
        // awaiting/旧版迁移阶段可继续用 legacy，但绝不在读异常时写 secure。
        _profile = legacyProfile;
        _initialized = true;
        return;
      }
      // secure 内容损坏而 legacy 有效时，让普通前台路径用 legacy 修复它。
      secureWasCorrupt = true;
      secureProfile = null;
    }

    // KeyStore/ThisDeviceOnly 凭据不会随系统备份迁移。verified marker 被恢复、
    // secure key 明确不存在时应安全登出；read 抛异常仍走上面的可重试路径。
    if (state == _verified && secureProfile == null && !secureWasCorrupt) {
      _profile = null;
      if (!readOnly) await _writeMigrationState(_cleared);
      _initialized = true;
      return;
    }

    if (readOnly) {
      if (state == _verified) {
        _profile = secureProfile;
      } else {
        _profile = legacyProfile ?? secureProfile;
      }
      _initialized = true;
      return;
    }

    // legacy 仍存在时始终参与冲突判断。它可能是一次新登录已落盘、但进程
    // 尚未来得及把 migration state 从 verified 改回 awaiting 的更新值。
    if (legacyProfile != null) {
      if (secureProfile != null && _sameProfile(secureProfile, legacyProfile)) {
        _profile = secureProfile;
        await _writeMigrationState(_verified);
        await _bestEffort(legacyStorage.clear);
        _initialized = true;
        return;
      }

      _profile = legacyProfile;
      await _writeMigrationState(_awaitingVerification);
      final migrated = await _writeSecureProfile(legacyProfile);
      if (migrated) {
        await _writeMigrationState(_awaitingVerification);
      }
      _initialized = true;
      return;
    }

    if (secureProfile != null) {
      _profile = secureProfile;
      await _writeMigrationState(_verified);
      _initialized = true;
      return;
    }

    _profile = null;
    _initialized = true;
  }

  @override
  Future<String?> readToken() async {
    await initialize();
    return readTokenSync();
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async {
    await initialize();
    return readProfileSync();
  }

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    if (readOnly) throw StateError('只读登录存储不能写入 profile');
    await initialize();
    final previousState = _readMigrationState();
    final previousProfile = readProfileSync();
    final profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': AccountScopeIndex.resolve(userName, extras),
      AccountScopeIndex.originField: AccountScopeIndex.origin,
      ...extras,
    };
    await AccountScopeIndex.remember(profile);

    if (previousState == _verified) {
      // verified 后 secure 是唯一持久化来源。先清掉迁移期可能遗留的明文，
      // 清理失败时保持旧安全会话，不得让新 token 经过 legacy。
      try {
        await legacyStorage.clear();
      } catch (error) {
        throw SecureStorageUnavailableException(
          'legacy-clear',
          cause: error,
        );
      }

      // secure 写入不是事务；先持久化 fail-closed tombstone，保证进程在
      // secure mutation 与最终 marker 提交之间退出时，下次启动不会接受
      // 状态不明的新 token。
      try {
        await _writeMigrationState(_cleared);
      } catch (error) {
        throw SecureStorageUnavailableException(
          'state-prepare',
          cause: error,
        );
      }

      final secureSaved = await _writeSecureProfile(profile);
      if (secureSaved) {
        try {
          await _writeMigrationState(_verified);
        } catch (error) {
          await _stayCleared();
          throw SecureStorageUnavailableException(
            'state-commit',
            cause: error,
          );
        }
        _profile = profile;
        return;
      }

      // 已完成安全迁移的账号不能因为 Keychain/KeyStore 抖动重新长期降级为
      // 明文 SharedPreferences。优先把旧登录态重新写回并回读 secure；若连
      // 旧值也无法验证，则写 tombstone 安全登出，避免接受状态不明的 token。
      final restoredSecure =
          previousProfile != null && await _writeSecureProfile(previousProfile);
      if (restoredSecure) {
        try {
          await _writeMigrationState(_verified);
        } catch (error) {
          await _stayCleared();
          throw SecureStorageUnavailableException(
            'state-rollback',
            cause: error,
          );
        }
        _profile = previousProfile;
        throw const SecureStorageUnavailableException('write');
      }

      await _stayCleared();
      throw const SecureStorageUnavailableException('write');
    }

    // 两阶段写入：先让 legacy 成为崩溃恢复源，再写 secure 并回读验证。
    await legacyStorage.writeProfile(
      token: token,
      userName: userName,
      avatar: avatar,
      extras: {
        ...extras,
        'accountHash': profile['accountHash'],
        AccountScopeIndex.originField: profile[AccountScopeIndex.originField],
      },
    );
    await _writeMigrationState(_awaitingVerification);
    _profile = profile;
    final secureSaved = await _writeSecureProfile(profile);
    if (secureSaved) {
      await _writeMigrationState(_verified);
      await _bestEffort(legacyStorage.clear);
      return;
    }
  }

  @override
  Future<void> clear() async {
    if (readOnly) throw StateError('只读登录存储不能清除 profile');
    await _bestEffort(() => AccountScopeIndex.remember(_profile));
    // tombstone 必须先落盘，防止安全存储 delete 失败后下次启动恢复旧 token。
    await _writeMigrationState(_cleared);
    _profile = null;
    await _bestEffort(legacyStorage.clear);
    await _bestEffort(() => secureStore.delete(secureProfileKey));
  }

  Future<Map<String, dynamic>?> _safeLegacyProfile() async {
    try {
      final profile = await legacyStorage.readProfile();
      return _validatedProfile(profile);
    } catch (_) {
      return _validatedProfile(legacyStorage.readProfileSync());
    }
  }

  Future<Map<String, dynamic>?> _readSecureProfile() async {
    final String? raw;
    try {
      raw = await secureStore.read(secureProfileKey);
    } catch (error) {
      throw SecureStorageUnavailableException('read', cause: error);
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      final profile = _validatedProfile(decoded);
      if (profile == null) {
        throw const SecureStorageUnavailableException(
          'decode',
          corrupt: true,
        );
      }
      return profile;
    } on SecureStorageUnavailableException {
      rethrow;
    } catch (error) {
      throw SecureStorageUnavailableException(
        'decode',
        corrupt: true,
        cause: error,
      );
    }
  }

  Future<bool> _writeSecureProfile(Map<String, dynamic> profile) async {
    final encoded = jsonEncode(profile);
    try {
      await secureStore.write(secureProfileKey, encoded);
      final readBack = await secureStore.read(secureProfileKey);
      if (readBack == null || readBack.isEmpty) return false;
      final decoded = jsonDecode(readBack);
      final verified = _validatedProfile(decoded);
      return verified != null && _sameProfile(verified, profile);
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic>? _validatedProfile(Object? raw) {
    if (raw is! Map) return null;
    try {
      final profile = Map<String, dynamic>.from(raw);
      final token = profile['boardingPass'];
      if (token is! String || token.isEmpty) return null;
      final accountHash = profile['accountHash']?.toString().trim() ?? '';
      if (accountHash.isEmpty) {
        final userName = profile['userName'];
        if (userName is! String) return null;
        // 兼容极早期 profile：当时只有 userName，可按旧规则恢复账号分区。
        profile['accountHash'] = AccountScopeIndex.resolve(userName, const {});
      }
      return profile;
    } catch (_) {
      return null;
    }
  }

  String? _readMigrationState() {
    final value = HiCache.getInstance().prefs?.get(_migrationStateKey);
    return value is String ? value : null;
  }

  Future<void> _writeMigrationState(String state) async {
    final prefs = HiCache.getInstance().prefs;
    if (prefs == null || !await prefs.setString(_migrationStateKey, state)) {
      throw StateError('登录态迁移状态写入失败');
    }
  }

  Future<void> _stayCleared() async {
    _profile = null;
    await _bestEffort(() => _writeMigrationState(_cleared));
    await _bestEffort(() => secureStore.delete(secureProfileKey));
  }

  static bool _sameProfile(
    Map<String, dynamic> first,
    Map<String, dynamic> second,
  ) =>
      jsonEncode(first) == jsonEncode(second);

  static Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }
}
