import 'dart:convert';

import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';

abstract interface class TranslationPreferenceKeyValueStore {
  Object? read(String key);

  Future<bool> writeString(String key, String value);

  Future<bool> remove(String key);
}

/// HiCache 的可等待适配器，确保平台落盘失败能反馈给调用方。
final class HiCacheTranslationPreferenceKeyValueStore
    implements TranslationPreferenceKeyValueStore {
  const HiCacheTranslationPreferenceKeyValueStore();

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

typedef TranslationPreferenceAccountHashReader = String? Function();

/// 按账号隔离的翻译模型偏好。
///
/// 写入在 await 前后都校验账号；平台写入失败或期间切换账号时，会恢复旧 JSON
/// 与本实例的旧可见值，避免把账号 A 的操作误展示成账号 B 的配置。
final class TranslationModelPreferenceStore {
  static const _keyPrefix = 'translation_model_preference_v1_';
  static const _fallback = TranslationModelPreference(
    mode: TranslationModelPreferenceMode.followGlobal,
    reasoningPolicy: ChatReasoningPolicy.offIfSupported,
  );

  final TranslationPreferenceKeyValueStore _storage;
  final TranslationPreferenceAccountHashReader _currentAccountHash;
  final Map<String, TranslationModelPreference> _visiblePreferences = {};
  final Map<String, Future<void>> _saveTails = {};

  TranslationModelPreferenceStore({
    TranslationPreferenceKeyValueStore storage =
        const HiCacheTranslationPreferenceKeyValueStore(),
    TranslationPreferenceAccountHashReader? currentAccountHash,
  })  : _storage = storage,
        _currentAccountHash = currentAccountHash ?? _defaultCurrentAccountHash;

  static String? _defaultCurrentAccountHash() => LoginDao.getAccountHash();

  static String keyFor(String accountHash) {
    if (accountHash.trim().isEmpty) {
      throw ArgumentError.value(accountHash, 'accountHash', '不能为空');
    }
    return '$_keyPrefix$accountHash';
  }

  TranslationModelPreference read(String accountHash) {
    final key = keyFor(accountHash);
    return _visiblePreferences.putIfAbsent(key, () {
      try {
        final raw = _storage.read(key);
        if (raw is! String) return _fallback;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return _fallback;
        return TranslationModelPreference.fromJson(
          decoded.cast<String, dynamic>(),
        );
      } catch (_) {
        return _fallback;
      }
    });
  }

  Future<void> save(
    TranslationModelPreference preference, {
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
              preference,
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
    TranslationModelPreference preference, {
    required String expectedAccountHash,
    required String key,
  }) async {
    _ensureCurrentAccount(expectedAccountHash);
    // 直接构造器允许 const；落盘前通过公共 JSON 契约做完整字段校验。
    final validated = TranslationModelPreference.fromJson(preference.toJson());
    final previousVisible = read(expectedAccountHash);
    Object? previousRaw;
    try {
      previousRaw = _storage.read(key);
    } catch (_) {
      previousRaw = null;
    }

    try {
      final raw = jsonEncode(validated.toJson());
      final persisted = await _storage.writeString(key, raw);
      if (!persisted) {
        throw StateError('翻译模型偏好未能持久化');
      }
      _ensureCurrentAccount(expectedAccountHash);
    } catch (error, stackTrace) {
      _visiblePreferences[key] = previousVisible;
      final restored = await _restoreRaw(key, previousRaw);
      if (!restored) {
        throw StateError(
          '翻译模型偏好写入失败且回滚未持久化；当前会话继续使用旧偏好。'
          '原始错误：$error',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    _visiblePreferences[key] = validated;
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
      if (previousRaw is String) {
        return await _storage.writeString(key, previousRaw);
      }
      return await _storage.remove(key);
    } catch (_) {
      return false;
    }
  }
}
