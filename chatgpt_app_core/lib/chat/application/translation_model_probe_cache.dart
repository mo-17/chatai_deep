import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/chat/domain/backend_selection_error.dart';

import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';

enum TranslationModelProbeStatus { verified, failed }

final class TranslationModelProbeCacheToken {
  final int accountGeneration;
  final int providerGeneration;
  final int runtimeProviderGeneration;

  const TranslationModelProbeCacheToken({
    required this.accountGeneration,
    required this.providerGeneration,
    this.runtimeProviderGeneration = 0,
  });

  bool sameAs(TranslationModelProbeCacheToken other) =>
      accountGeneration == other.accountGeneration &&
      providerGeneration == other.providerGeneration &&
      runtimeProviderGeneration == other.runtimeProviderGeneration;
}

/// Provider 配置乐观发布与持久 cache 失效之间的进程内屏障。
///
/// 它只持有账号/provider 标识与计数，不持有凭据；release 可重复调用。
final class TranslationModelProbeInvalidationBarrier {
  final void Function() _release;
  bool _released = false;

  TranslationModelProbeInvalidationBarrier._(this._release);

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

final class TranslationModelProbeRecord {
  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _allowedSafeErrorCodes = {
    'auth_failed',
    'unsupported_api',
    'rate_limited',
    'first_event_timeout',
    'idle_timeout',
    'network_unreachable',
    'invalid_output',
    'unknown',
  };

  final String fingerprint;
  final TranslationModelProbeStatus status;
  final DateTime checkedAt;
  final int? firstEventMs;
  final int? totalMs;
  final String? safeErrorCode;
  final bool reasoningControlSuppressed;

  TranslationModelProbeRecord({
    required this.fingerprint,
    required this.status,
    required this.checkedAt,
    this.firstEventMs,
    this.totalMs,
    this.safeErrorCode,
    required this.reasoningControlSuppressed,
  }) {
    if (!_isAllowedSafeErrorCode(safeErrorCode)) {
      throw ArgumentError('必须是计划内脱敏错误码', 'safeErrorCode');
    }
  }

  Map<String, dynamic> toJson() {
    _validateFingerprint(fingerprint);
    _validateMilliseconds(firstEventMs, 'firstEventMs');
    _validateMilliseconds(totalMs, 'totalMs');
    return {
      'fingerprint': fingerprint,
      'status': status.name,
      'checkedAt': checkedAt.toUtc().millisecondsSinceEpoch,
      if (firstEventMs != null) 'firstEventMs': firstEventMs,
      if (totalMs != null) 'totalMs': totalMs,
      if (safeErrorCode != null) 'safeErrorCode': safeErrorCode,
      'reasoningControlSuppressed': reasoningControlSuppressed,
    };
  }

  factory TranslationModelProbeRecord.fromJson(Map<String, dynamic> json) {
    final fingerprint = json['fingerprint'];
    if (fingerprint is! String) {
      throw const FormatException('fingerprint 必须是字符串');
    }
    _validateFingerprint(fingerprint);

    final rawStatus = json['status'];
    if (rawStatus is! String) {
      throw const FormatException('status 必须是枚举名称');
    }
    final TranslationModelProbeStatus status;
    switch (rawStatus) {
      case 'verified':
        status = TranslationModelProbeStatus.verified;
      case 'failed':
        status = TranslationModelProbeStatus.failed;
      default:
        throw const FormatException('status 包含未知枚举名称');
    }

    final rawCheckedAt = json['checkedAt'];
    if (rawCheckedAt is! int) {
      throw const FormatException('checkedAt 必须是整数毫秒时间戳');
    }
    final DateTime checkedAt;
    try {
      checkedAt = DateTime.fromMillisecondsSinceEpoch(
        rawCheckedAt,
        isUtc: true,
      );
    } on RangeError {
      throw const FormatException('checkedAt 超出有效范围');
    }

    final firstEventMs = _optionalInt(json['firstEventMs'], 'firstEventMs');
    final totalMs = _optionalInt(json['totalMs'], 'totalMs');
    final rawSafeErrorCode = json['safeErrorCode'];
    if (rawSafeErrorCode != null && rawSafeErrorCode is! String) {
      throw const FormatException('safeErrorCode 必须是字符串');
    }
    if (!_isAllowedSafeErrorCode(rawSafeErrorCode)) {
      throw const FormatException('safeErrorCode 不是计划内脱敏错误码');
    }
    final rawSuppressed = json['reasoningControlSuppressed'];
    if (rawSuppressed is! bool) {
      throw const FormatException('reasoningControlSuppressed 必须是 bool');
    }
    return TranslationModelProbeRecord(
      fingerprint: fingerprint,
      status: status,
      checkedAt: checkedAt,
      firstEventMs: firstEventMs,
      totalMs: totalMs,
      safeErrorCode: rawSafeErrorCode,
      reasoningControlSuppressed: rawSuppressed,
    );
  }

  static void _validateFingerprint(String fingerprint) {
    if (!_fingerprintPattern.hasMatch(fingerprint)) {
      throw const FormatException('fingerprint 必须是小写 SHA-256 摘要');
    }
  }

  static bool _isAllowedSafeErrorCode(String? code) =>
      code == null ||
      _allowedSafeErrorCodes.contains(code) ||
      isBackendSelectionError(code);

  static int? _optionalInt(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is! int) throw FormatException('$field 必须是整数毫秒');
    _validateMilliseconds(raw, field);
    return raw;
  }

  static void _validateMilliseconds(int? value, String field) {
    if (value != null && value < 0) {
      throw FormatException('$field 不能为负数');
    }
  }
}

/// 账号级翻译模型预检缓存。
///
/// 缓存只落盘 SHA-256 身份与脱敏探测证据。所有实例共享同一条 per-key
/// mutation 队列，provider/account generation 则阻止失效前启动的旧请求回填。
final class TranslationModelProbeCache {
  static const ttl = Duration(days: 7);
  static const maxRecords = 50;
  static const _schemaVersion = 1;
  static const _keyPrefix = 'translation_model_probe_v1_';

  static final shared = TranslationModelProbeCache();
  static final Map<String, Future<dynamic>> _mutationTails = {};
  static final Map<String, int> _runtimeProviderGenerations = {};
  static final Map<String, int> _pendingProviderInvalidations = {};

  final DateTime Function() _now;

  TranslationModelProbeCache({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static String keyFor(String accountHash) {
    if (accountHash.trim().isEmpty) {
      throw ArgumentError.value(accountHash, 'accountHash', '不能为空');
    }
    return '$_keyPrefix$accountHash';
  }

  TranslationModelProbeCacheToken tokenFor({
    required String accountHash,
    required String? providerId,
  }) {
    _validateProviderId(providerId);
    final envelope = _readEnvelope(keyFor(accountHash));
    return _tokenFor(accountHash, envelope, providerId);
  }

  TranslationModelProbeRecord? lookup({
    required String accountHash,
    required String fingerprint,
    String? providerId,
  }) {
    _validateProviderId(providerId);
    if (providerId != null &&
        (_pendingProviderInvalidations[
                    _runtimeProviderKey(accountHash, providerId)] ??
                0) >
            0) {
      return null;
    }
    final envelope = _readEnvelope(keyFor(accountHash));
    final record = envelope.records[fingerprint];
    if (record == null || _isExpired(record)) return null;
    return record;
  }

  Future<bool> put(
    TranslationModelProbeRecord record, {
    required String expectedAccountHash,
    required String? providerId,
    required TranslationModelProbeCacheToken expectedToken,
    bool Function()? isIdentityCurrent,
  }) {
    _validateProviderId(providerId);
    final validated = TranslationModelProbeRecord.fromJson(record.toJson());
    final key = keyFor(expectedAccountHash);
    final runtimeGenerationAtEnqueue = _runtimeProviderGenerationFor(
      expectedAccountHash,
      providerId,
    );
    final invalidationPendingAtEnqueue = _providerInvalidationPending(
      expectedAccountHash,
      providerId,
    );
    return _enqueue<bool>(key, () async {
      if (!_identityCurrent(isIdentityCurrent)) return false;
      _ensureCurrentAccount(expectedAccountHash);
      if (invalidationPendingAtEnqueue ||
          _providerInvalidationPending(expectedAccountHash, providerId)) {
        return false;
      }
      if (runtimeGenerationAtEnqueue !=
              expectedToken.runtimeProviderGeneration ||
          _runtimeProviderGenerationFor(expectedAccountHash, providerId) !=
              runtimeGenerationAtEnqueue) {
        return false;
      }
      final previousRaw = _readRaw(key);
      final envelope = _decodeEnvelope(previousRaw);
      if (!_tokenFor(expectedAccountHash, envelope, providerId)
          .sameAs(expectedToken)) {
        return false;
      }

      _clean(envelope);
      _removeFromProviderIndexes(envelope, {validated.fingerprint});
      envelope.records[validated.fingerprint] = validated;
      if (providerId != null) {
        envelope.providers
            .putIfAbsent(providerId, () => <String>{})
            .add(validated.fingerprint);
      }
      _evictOldest(envelope);
      await _writeWithRollback(
        key,
        envelope,
        previousRaw: previousRaw,
        expectedAccountHash: expectedAccountHash,
        isIdentityCurrent: isIdentityCurrent,
      );
      if (!_identityCurrent(isIdentityCurrent) ||
          _providerInvalidationPending(expectedAccountHash, providerId) ||
          _runtimeProviderGenerationFor(expectedAccountHash, providerId) !=
              runtimeGenerationAtEnqueue) {
        final restored = await _restoreRaw(key, previousRaw);
        if (!restored) {
          throw StateError('翻译模型预检缓存跨代写入后旧值回滚未持久化');
        }
        return false;
      }
      return true;
    });
  }

  Future<void> invalidateProviders({
    required String accountHash,
    required Set<String> providerIds,
  }) {
    final frozenProviderIds = Set<String>.unmodifiable(providerIds);
    if (frozenProviderIds.isEmpty) return Future<void>.value();
    for (final providerId in frozenProviderIds) {
      _validateProviderId(providerId);
    }
    final key = keyFor(accountHash);
    return _enqueue<void>(key, () async {
      final previousRaw = _readRaw(key);
      final envelope = _decodeEnvelope(previousRaw);
      _clean(envelope);
      final removed = <String>{};
      for (final providerId in frozenProviderIds) {
        envelope.providerGenerations[providerId] =
            (envelope.providerGenerations[providerId] ?? 0) + 1;
        removed.addAll(envelope.providers.remove(providerId) ?? const {});
      }
      envelope.records.removeWhere(
        (fingerprint, _) => removed.contains(fingerprint),
      );
      _removeFromProviderIndexes(envelope, removed);
      await _writeWithRollback(
        key,
        envelope,
        previousRaw: previousRaw,
      );
    });
  }

  /// 在新的 provider 配置对 UI 可见前同步开启屏障。
  ///
  /// 持久失效仍由 [invalidateProviders] 串行执行；屏障期间 lookup fail closed，
  /// runtime generation 同时让旧 identity/single-flight 立即失效。
  TranslationModelProbeInvalidationBarrier beginProviderInvalidation({
    required String accountHash,
    required Set<String> providerIds,
  }) {
    final frozenProviderIds = Set<String>.unmodifiable(providerIds);
    for (final providerId in frozenProviderIds) {
      _validateProviderId(providerId);
    }
    for (final providerId in frozenProviderIds) {
      final key = _runtimeProviderKey(accountHash, providerId);
      _runtimeProviderGenerations[key] =
          (_runtimeProviderGenerations[key] ?? 0) + 1;
      _pendingProviderInvalidations[key] =
          (_pendingProviderInvalidations[key] ?? 0) + 1;
    }
    return TranslationModelProbeInvalidationBarrier._(() {
      for (final providerId in frozenProviderIds) {
        final key = _runtimeProviderKey(accountHash, providerId);
        final remaining = (_pendingProviderInvalidations[key] ?? 1) - 1;
        if (remaining <= 0) {
          _pendingProviderInvalidations.remove(key);
        } else {
          _pendingProviderInvalidations[key] = remaining;
        }
      }
    });
  }

  Future<void> clearAccount(String accountHash) {
    final key = keyFor(accountHash);
    return _enqueue<void>(key, () async {
      final previousRaw = _readRaw(key);
      final previous = _decodeEnvelope(previousRaw);
      final cleared = _ProbeEnvelope.empty(
        accountGeneration: previous.accountGeneration + 1,
      );
      await _writeWithRollback(
        key,
        cleared,
        previousRaw: previousRaw,
      );
    });
  }

  static Future<T> _enqueue<T>(
    String key,
    Future<T> Function() operation,
  ) {
    final previous = _mutationTails[key];
    final ready = previous?.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ) ??
        Future<void>.value();
    late final Future<T> current;
    current = ready.then<T>((_) => operation()).whenComplete(() {
      if (identical(_mutationTails[key], current)) {
        _mutationTails.remove(key);
      }
    });
    _mutationTails[key] = current;
    return current;
  }

  TranslationModelProbeCacheToken _tokenFor(
    String accountHash,
    _ProbeEnvelope envelope,
    String? providerId,
  ) {
    return TranslationModelProbeCacheToken(
      accountGeneration: envelope.accountGeneration,
      providerGeneration: providerId == null
          ? 0
          : envelope.providerGenerations[providerId] ?? 0,
      runtimeProviderGeneration: providerId == null
          ? 0
          : _runtimeProviderGenerations[
                  _runtimeProviderKey(accountHash, providerId)] ??
              0,
    );
  }

  bool _isExpired(TranslationModelProbeRecord record) {
    return !record.checkedAt.isAfter(_now().subtract(ttl));
  }

  void _clean(_ProbeEnvelope envelope) {
    final removed = <String>{};
    envelope.records.removeWhere((fingerprint, record) {
      final expired = _isExpired(record);
      if (expired) removed.add(fingerprint);
      return expired;
    });
    _removeFromProviderIndexes(envelope, removed);
    final valid = envelope.records.keys.toSet();
    for (final entry in envelope.providers.entries.toList()) {
      entry.value.retainAll(valid);
      if (entry.value.isEmpty) envelope.providers.remove(entry.key);
    }
  }

  void _evictOldest(_ProbeEnvelope envelope) {
    final overflow = envelope.records.length - maxRecords;
    if (overflow <= 0) return;
    final oldest = envelope.records.values.toList()
      ..sort((left, right) {
        final byTime = left.checkedAt.compareTo(right.checkedAt);
        return byTime != 0
            ? byTime
            : left.fingerprint.compareTo(right.fingerprint);
      });
    final removed =
        oldest.take(overflow).map((record) => record.fingerprint).toSet();
    envelope.records.removeWhere(
      (fingerprint, _) => removed.contains(fingerprint),
    );
    _removeFromProviderIndexes(envelope, removed);
  }

  static void _removeFromProviderIndexes(
    _ProbeEnvelope envelope,
    Set<String> fingerprints,
  ) {
    if (fingerprints.isEmpty) return;
    for (final entry in envelope.providers.entries.toList()) {
      entry.value.removeAll(fingerprints);
      if (entry.value.isEmpty) envelope.providers.remove(entry.key);
    }
  }

  static void _validateProviderId(String? providerId) {
    if (providerId != null && providerId.trim().isEmpty) {
      throw ArgumentError.value(providerId, 'providerId', '不能为空');
    }
  }

  static String _runtimeProviderKey(String accountHash, String providerId) =>
      '$accountHash\u0000$providerId';

  static int _runtimeProviderGenerationFor(
    String accountHash,
    String? providerId,
  ) =>
      providerId == null
          ? 0
          : _runtimeProviderGenerations[
                  _runtimeProviderKey(accountHash, providerId)] ??
              0;

  static bool _providerInvalidationPending(
    String accountHash,
    String? providerId,
  ) =>
      providerId != null &&
      (_pendingProviderInvalidations[
                  _runtimeProviderKey(accountHash, providerId)] ??
              0) >
          0;

  static String _currentAccountHash() => LoginDao.getAccountHash() ?? 'guest';

  static void _ensureCurrentAccount(String expectedAccountHash) {
    if (_currentAccountHash() != expectedAccountHash) {
      throw StateError('账号已切换，拒绝写入旧账号的模型预检缓存');
    }
  }

  static Object? _readRaw(String key) => HiCache.getInstance().prefs?.get(key);

  static _ProbeEnvelope _readEnvelope(String key) =>
      _decodeEnvelope(_readRaw(key));

  static _ProbeEnvelope _decodeEnvelope(Object? raw) {
    if (raw is! String) return _ProbeEnvelope.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _ProbeEnvelope.empty();
      return _ProbeEnvelope.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return _ProbeEnvelope.empty();
    }
  }

  static Future<void> _writeWithRollback(
    String key,
    _ProbeEnvelope envelope, {
    required Object? previousRaw,
    String? expectedAccountHash,
    bool Function()? isIdentityCurrent,
  }) async {
    final preferences = HiCache.getInstance().prefs;
    if (preferences == null) throw StateError('HiCache 尚未初始化');
    if (!_identityCurrent(isIdentityCurrent)) {
      throw StateError('原模型预检身份已失效，拒绝写入缓存');
    }
    try {
      final persisted = await preferences.setString(
        key,
        jsonEncode(envelope.toJson()),
      );
      if (!persisted) throw StateError('翻译模型预检缓存未能持久化');
      if (expectedAccountHash != null) {
        _ensureCurrentAccount(expectedAccountHash);
      }
      if (!_identityCurrent(isIdentityCurrent)) {
        throw StateError('原模型预检身份已失效，拒绝写入缓存');
      }
    } catch (error, stackTrace) {
      final restored = await _restoreRaw(key, previousRaw);
      if (!restored) {
        throw StateError('翻译模型预检缓存写入失败且旧值回滚未持久化');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static bool _identityCurrent(bool Function()? guard) {
    try {
      return guard?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _restoreRaw(String key, Object? raw) async {
    final preferences = HiCache.getInstance().prefs;
    if (preferences == null) return false;
    try {
      if (raw == null) return preferences.remove(key);
      if (raw is String) return preferences.setString(key, raw);
      if (raw is bool) return preferences.setBool(key, raw);
      if (raw is int) return preferences.setInt(key, raw);
      if (raw is double) return preferences.setDouble(key, raw);
      if (raw is List<String>) return preferences.setStringList(key, raw);
      return false;
    } catch (_) {
      return false;
    }
  }
}

final class _ProbeEnvelope {
  final int accountGeneration;
  final Map<String, int> providerGenerations;
  final Map<String, TranslationModelProbeRecord> records;
  final Map<String, Set<String>> providers;

  _ProbeEnvelope({
    required this.accountGeneration,
    required this.providerGenerations,
    required this.records,
    required this.providers,
  });

  factory _ProbeEnvelope.empty({int accountGeneration = 0}) {
    return _ProbeEnvelope(
      accountGeneration: accountGeneration,
      providerGenerations: {},
      records: {},
      providers: {},
    );
  }

  factory _ProbeEnvelope.fromJson(Map<String, dynamic> json) {
    if (json['version'] != TranslationModelProbeCache._schemaVersion) {
      throw const FormatException('不支持的翻译模型预检缓存版本');
    }
    final accountGeneration = json['accountGeneration'];
    if (accountGeneration is! int || accountGeneration < 0) {
      throw const FormatException('accountGeneration 必须是非负整数');
    }
    final rawProviderGenerations = json['providerGenerations'];
    final rawRecords = json['records'];
    final rawProviders = json['providers'];
    if (rawProviderGenerations is! Map ||
        rawRecords is! Map ||
        rawProviders is! Map) {
      throw const FormatException('翻译模型预检缓存 envelope 字段类型错误');
    }

    final providerGenerations = <String, int>{};
    for (final entry in rawProviderGenerations.entries) {
      final value = entry.value;
      if (entry.key is! String ||
          (entry.key as String).trim().isEmpty ||
          value is! int ||
          value < 0) {
        throw const FormatException('providerGenerations 字段类型错误');
      }
      providerGenerations[entry.key as String] = value;
    }

    final records = <String, TranslationModelProbeRecord>{};
    for (final entry in rawRecords.entries) {
      final fingerprint = entry.key;
      final value = entry.value;
      if (fingerprint is! String || value is! Map) continue;
      try {
        final record = TranslationModelProbeRecord.fromJson(
          value.cast<String, dynamic>(),
        );
        if (record.fingerprint == fingerprint) {
          records[fingerprint] = record;
        }
      } catch (_) {
        // 单条损坏不连带丢弃同账号其它有效记录；下次 mutation 会清理索引。
      }
    }

    final providers = <String, Set<String>>{};
    var providerIndexCorrupt = false;
    for (final entry in rawProviders.entries) {
      final providerId = entry.key;
      final rawFingerprints = entry.value;
      if (providerId is! String ||
          providerId.trim().isEmpty ||
          rawFingerprints is! List) {
        providerIndexCorrupt = true;
        break;
      }
      final fingerprints = <String>{};
      for (final fingerprint in rawFingerprints) {
        if (fingerprint is! String) {
          providerIndexCorrupt = true;
          break;
        }
        try {
          TranslationModelProbeRecord._validateFingerprint(fingerprint);
        } on FormatException {
          providerIndexCorrupt = true;
          break;
        }
        fingerprints.add(fingerprint);
      }
      if (providerIndexCorrupt) break;
      if (fingerprints.isNotEmpty) {
        providers[providerId] = fingerprints;
      }
    }
    if (providerIndexCorrupt) {
      return _ProbeEnvelope(
        accountGeneration: accountGeneration,
        providerGenerations: providerGenerations,
        records: {},
        providers: {},
      );
    }
    return _ProbeEnvelope(
      accountGeneration: accountGeneration,
      providerGenerations: providerGenerations,
      records: records,
      providers: providers,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': TranslationModelProbeCache._schemaVersion,
        'accountGeneration': accountGeneration,
        'providerGenerations': providerGenerations,
        'records': {
          for (final entry in records.entries) entry.key: entry.value.toJson(),
        },
        'providers': {
          for (final entry in providers.entries)
            entry.key: (entry.value.toList()..sort()),
        },
      };
}
