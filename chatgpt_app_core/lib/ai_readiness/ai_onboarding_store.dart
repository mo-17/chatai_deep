import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';

enum AIOnboardingStatus { unseen, dismissed, grandfathered, completed }

/// 判断旧账号是否应静默沿用现状的只读证据。
final class AIOnboardingEvidence {
  final bool hasStoredSettings;
  final bool hasConversationHistory;
  final bool hasCustomProvider;
  final bool hasSuccessfulHealthCheck;

  const AIOnboardingEvidence({
    required this.hasStoredSettings,
    required this.hasConversationHistory,
    required this.hasCustomProvider,
    required this.hasSuccessfulHealthCheck,
  });

  static const empty = AIOnboardingEvidence(
    hasStoredSettings: false,
    hasConversationHistory: false,
    hasCustomProvider: false,
    hasSuccessfulHealthCheck: false,
  );

  bool get hasLegacyEvidence =>
      hasStoredSettings ||
      hasConversationHistory ||
      hasCustomProvider ||
      hasSuccessfulHealthCheck;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AIOnboardingEvidence &&
          hasStoredSettings == other.hasStoredSettings &&
          hasConversationHistory == other.hasConversationHistory &&
          hasCustomProvider == other.hasCustomProvider &&
          hasSuccessfulHealthCheck == other.hasSuccessfulHealthCheck;

  @override
  int get hashCode => Object.hash(
        hasStoredSettings,
        hasConversationHistory,
        hasCustomProvider,
        hasSuccessfulHealthCheck,
      );
}

abstract interface class AIOnboardingKeyValueStore {
  Object? read(String key);

  Future<bool> writeString(String key, String value);

  Future<bool> remove(String key);
}

/// HiCache 的可等待适配器。直接等待 SharedPreferences 的返回值，避免旧
/// wrapper 丢弃 Future 后把失败写入误当成已持久化。
final class HiCacheAIOnboardingKeyValueStore
    implements AIOnboardingKeyValueStore {
  const HiCacheAIOnboardingKeyValueStore();

  @override
  Object? read(String key) => HiCache.getInstance().prefs?.get(key);

  @override
  Future<bool> writeString(String key, String value) async {
    final preferences = HiCache.getInstance().prefs;
    if (preferences == null) throw StateError('HiCache 尚未初始化');
    return preferences.setString(key, value);
  }

  @override
  Future<bool> remove(String key) async {
    final preferences = HiCache.getInstance().prefs;
    if (preferences == null) throw StateError('HiCache 尚未初始化');
    return preferences.remove(key);
  }
}

typedef AIOnboardingAccountHashReader = String? Function();

/// 按账号隔离的非打断式 AI 引导状态。
///
/// 状态与 `AISettings` 分开存放，因此不会改变已有设置 JSON 或 secure payload
/// 合同。每次写入在 await 前后校验账号，账号切换或落盘失败时恢复原值，并且
/// 当前 store 的可见状态不会提前改变。
final class AIOnboardingStore {
  static const _keyPrefix = 'ai_onboarding_v1_';
  static const _allowedValues = <String, AIOnboardingStatus>{
    'unseen': AIOnboardingStatus.unseen,
    'dismissed': AIOnboardingStatus.dismissed,
    'grandfathered': AIOnboardingStatus.grandfathered,
    'completed': AIOnboardingStatus.completed,
  };

  final AIOnboardingKeyValueStore _storage;
  final AIOnboardingAccountHashReader _currentAccountHash;

  /// 已经被本实例观察到的状态。只有 durable write 成功后才更新，避免
  /// SharedPreferences 在平台写失败前先修改内存 cache 导致 UI 闪变。
  final Map<String, AIOnboardingStatus> _visibleStatuses = {};
  final Map<String, Future<void>> _saveTails = {};

  AIOnboardingStore({
    AIOnboardingKeyValueStore storage =
        const HiCacheAIOnboardingKeyValueStore(),
    AIOnboardingAccountHashReader? currentAccountHash,
  })  : _storage = storage,
        _currentAccountHash = currentAccountHash ?? _defaultCurrentAccountHash;

  static String? _defaultCurrentAccountHash() => LoginDao.getAccountHash();

  static String keyFor(String accountHash) {
    if (accountHash.trim().isEmpty) {
      throw ArgumentError.value(accountHash, 'accountHash', '不能为空');
    }
    return '$_keyPrefix$accountHash';
  }

  AIOnboardingStatus read(String accountHash) {
    final key = keyFor(accountHash);
    return _visibleStatuses.putIfAbsent(key, () {
      try {
        final raw = _storage.read(key);
        return raw is String
            ? (_allowedValues[raw] ?? AIOnboardingStatus.unseen)
            : AIOnboardingStatus.unseen;
      } catch (_) {
        return AIOnboardingStatus.unseen;
      }
    });
  }

  Future<void> save(
    AIOnboardingStatus status, {
    required String expectedAccountHash,
  }) {
    final key = keyFor(expectedAccountHash);
    final previous = _saveTails[key];
    final ready = previous?.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ) ??
        Future<void>.value();
    late final Future<void> saving;
    saving = ready
        .then((_) => _saveNow(
              status,
              expectedAccountHash: expectedAccountHash,
              key: key,
            ))
        .whenComplete(() {
      if (identical(_saveTails[key], saving)) _saveTails.remove(key);
    });
    _saveTails[key] = saving;
    return saving;
  }

  Future<void> _saveNow(
    AIOnboardingStatus status, {
    required String expectedAccountHash,
    required String key,
  }) async {
    _ensureCurrentAccount(expectedAccountHash);
    final previousVisible = read(expectedAccountHash);
    Object? previousRaw;
    try {
      previousRaw = _storage.read(key);
    } catch (_) {
      previousRaw = null;
    }

    try {
      final persisted = await _storage.writeString(key, status.name);
      if (!persisted) {
        throw StateError('AI 引导状态未能持久化');
      }
      _ensureCurrentAccount(expectedAccountHash);
    } catch (error, stackTrace) {
      _visibleStatuses[key] = previousVisible;
      final restored = await _restoreRaw(key, previousRaw);
      if (!restored) {
        throw StateError(
          'AI 引导状态写入失败且回滚未持久化；当前会话继续使用旧状态。'
          '原始错误：$error',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    _visibleStatuses[key] = status;
  }

  /// 首次加载时把有任一旧用户证据的账号静默标记为 grandfathered。
  /// 已持久化状态始终优先，因此重复调用不会覆盖 dismissed/completed，也不会
  /// 对 grandfathered 重复写盘。
  Future<AIOnboardingStatus> classify({
    required String expectedAccountHash,
    required AIOnboardingEvidence evidence,
  }) async {
    final persisted = read(expectedAccountHash);
    if (persisted != AIOnboardingStatus.unseen) return persisted;
    if (!evidence.hasLegacyEvidence) return AIOnboardingStatus.unseen;

    await save(
      AIOnboardingStatus.grandfathered,
      expectedAccountHash: expectedAccountHash,
    );
    return AIOnboardingStatus.grandfathered;
  }

  void _ensureCurrentAccount(String expectedAccountHash) {
    final current = _currentAccountHash();
    if (current != expectedAccountHash) {
      throw StateError(
        '账号已切换：expected=$expectedAccountHash, current=$current',
      );
    }
  }

  Future<bool> _restoreRaw(String key, Object? previousRaw) async {
    try {
      if (previousRaw is String && _allowedValues.containsKey(previousRaw)) {
        return await _storage.writeString(key, previousRaw);
      }
      return await _storage.remove(key);
    } catch (_) {
      return false;
    }
  }
}
