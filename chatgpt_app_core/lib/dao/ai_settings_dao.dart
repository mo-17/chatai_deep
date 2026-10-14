import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';

class AISecretsUnavailableException implements Exception {
  final String accountHash;
  final bool corrupt;
  final Object? cause;

  const AISecretsUnavailableException(
    this.accountHash, {
    this.corrupt = false,
    this.cause,
  });

  @override
  String toString() => 'AI secrets unavailable for account $accountHash';
}

class AISettingsDao {
  // 工具配置的同步失效代次；在相关写入排队/等待前递增，不能借旧快照发工具。
  // 只切全局当前模型不改变这个授权；凭据不落入 journal，内存比较值也只留 hash。
  static final _executionRevisions = <String, int>{};
  static final _executionConfigurations = <String, String>{};
  static int executionRevisionFor(String account) =>
      _executionRevisions[account] ?? 0;
  static String _executionConfiguration(AISettings settings) => sha256
      .convert(utf8.encode(jsonEncode({
        'servers': settings.mcpServers.map((s) => s.toJson()).toList(),
        'backend': settings.mcpBackendEnabled,
        'trusted': settings.mcpBackendTrusted,
        'search': settings.webSearchProviderId,
        'searchKey': settings.activeSearchApiKey,
      })))
      .toString();
  static void bindExecutionConfiguration(String account, AISettings settings) {
    // 仅为尚无授权记录的账号建立初始许可；clear 的失效记录不能由旧缓存补签。
    if (!_executionRevisions.containsKey(account)) {
      _executionConfigurations.putIfAbsent(
          account, () => _executionConfiguration(settings));
    }
  }

  static bool executionConfigurationMatches(
          String account, AISettings settings) =>
      _executionConfigurations[account] == _executionConfiguration(settings);
  static void _invalidateExecution(String account, [AISettings? settings]) {
    final key = settings == null ? null : _executionConfiguration(settings);
    if (key == null || key != _executionConfigurations[account]) {
      _executionRevisions[account] = executionRevisionFor(account) + 1;
    }
    if (key == null) {
      _executionConfigurations.remove(account);
    } else {
      _executionConfigurations[account] = key;
    }
  }

  static const _kOldKey = 'ai_settings_v1';
  static const _secureMarkerField = '_secretStorage';
  static const _secureMarkerValue = 'secure-v1';
  static const _pendingField = '_secretWritePending';
  static const _generationField = '_secretGeneration';
  static const _clearedField = '_secretCleared';
  static const _legacyMigrationValue = 'pending-v1';

  static SecureKeyValueStore? _secretStore;
  static final Map<String, _AISecretBundle> _secretsByAccount = {};
  static final Map<String, AISettings> _snapshotsByAccount = {};
  static final Map<String, int> _generationsByAccount = {};
  static final Map<String, String> _activeSecretKeysByAccount = {};
  static final Set<String> _plainRepairAccounts = {};
  static final Set<String> _clearPendingAccounts = {};
  static final Set<String> _preparedAccounts = {};
  static final Set<String> _unavailableAccounts = {};
  static final Set<String> _corruptPlainAccounts = {};
  static final Map<String, Future<void>> _preparingAccounts = {};
  // 同一账号的 prepare/save/clear 共用一条串行队列；save 会返回实际落盘
  // AISettings，其余操作返回 void，因此队列保存异构 Future。
  static final Map<String, Future<dynamic>> _saveTails = {};
  static Future<bool> Function(String key, String value)?
      plainWriteOverrideForTest;

  /// 指定账号 hash 的 HiCache key。游客固定为 'guest'。
  static String keyFor(String hash) => 'ai_settings_v1_$hash';

  static String secretKeyFor(String hash) => 'ai_secrets_v1_$hash';

  static String secondarySecretKeyFor(String hash) =>
      'ai_secrets_v1_${hash}_slot_b';

  static void validateSettings(AISettings settings) {
    if (!_hasUniqueCredentialIds(settings)) {
      throw const FormatException('AI 设置包含重复或空的 provider/MCP id');
    }
  }

  static String _legacyMigrationKeyFor(String hash) =>
      'ai_settings_legacy_migration_v1_$hash';

  static String _verificationQuarantineKeyFor(String hash) =>
      'ai_settings_secure_verification_quarantine_v1_$hash';

  /// 标准 Flutter 壳层注入 Keychain/KeyStore；null 保持历史 HiCache 行为。
  static void configureSecretStore(SecureKeyValueStore? store) {
    if (identical(_secretStore, store)) return;
    _secretStore = store;
    _secretsByAccount.clear();
    _snapshotsByAccount.clear();
    _generationsByAccount.clear();
    _activeSecretKeysByAccount.clear();
    _plainRepairAccounts.clear();
    _clearPendingAccounts.clear();
    _preparedAccounts.clear();
    _unavailableAccounts.clear();
    _corruptPlainAccounts.clear();
    _preparingAccounts.clear();
    _saveTails.clear();
  }

  /// 在同步 [load]/[loadFor] 之前预载某账号的 secrets。
  ///
  /// 旧明文设置只有在安全存储写入并回读一致后才会脱敏；任一步失败都保留
  /// 旧格式继续使用，确保升级不丢 API Key、搜索 Key 或 MCP 鉴权头。
  static Future<void> prepareAccount(String hash) {
    if (_preparedAccounts.contains(hash)) return Future<void>.value();
    final current = _preparingAccounts[hash];
    if (current != null) return current;

    final previous = _saveTails[hash];
    final ready = previous?.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ) ??
        Future<void>.value();
    late final Future<void> future;
    future = ready.then((_) => _prepareAccount(hash)).whenComplete(() {
      if (identical(_preparingAccounts[hash], future)) {
        _preparingAccounts.remove(hash);
      }
      if (identical(_saveTails[hash], future)) _saveTails.remove(hash);
    });
    _preparingAccounts[hash] = future;
    _saveTails[hash] = future;
    return future;
  }

  static Future<void> _prepareAccount(String hash) async {
    final currentAccountHash = LoginDao.getAccountHash();
    final isCurrentAccount =
        currentAccountHash != null && hash == currentAccountHash;
    final oldRaw = isCurrentAccount ? _cachedString(_kOldKey) : null;
    final migrationKey = _legacyMigrationKeyFor(hash);
    var migrationClaimed = _cachedString(migrationKey) == _legacyMigrationValue;
    var raw = _rawFor(hash);
    var shouldCleanupOldRaw =
        oldRaw != null && (migrationClaimed || raw == oldRaw);
    if (raw == null && oldRaw != null) {
      // 先复制、后迁移；只有新账号 key 已经安全落盘后才会删除旧全局 key。
      if (!migrationClaimed) {
        await _setCacheString(migrationKey, _legacyMigrationValue);
        migrationClaimed = true;
      }
      await _setCacheString(keyFor(hash), oldRaw);
      raw = oldRaw;
      shouldCleanupOldRaw = true;
    } else if (shouldCleanupOldRaw && !migrationClaimed) {
      await _setCacheString(migrationKey, _legacyMigrationValue);
      migrationClaimed = true;
    }

    final store = _secretStore;
    if (raw == null) {
      if (store == null) {
        await _finishPreparation(
          hash,
          cleanupOldRaw: shouldCleanupOldRaw,
          cleanupMigrationClaim: migrationClaimed,
        );
        return;
      }
      final payload = await _readPayloadOrMarkUnavailable(
        hash,
        plainIsCorrupt: true,
      );
      if (payload == null) {
        if (_unavailableAccounts.contains(hash)) return;
        await _finishPreparation(
          hash,
          cleanupOldRaw: shouldCleanupOldRaw,
          cleanupMigrationClaim: migrationClaimed,
        );
        return;
      }
      final snapshot = payload.settingsSnapshot;
      if (snapshot == null) {
        _markUnavailable(hash, corruptPlain: true);
        return;
      }
      await _writePlainSettings(
        hash,
        snapshot,
        secure: true,
        generation: payload.generation,
      );
      _cachePayload(hash, payload);
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }

    final decoded = _decodeMap(raw);
    if (decoded?[_clearedField] == true) {
      _secretsByAccount.remove(hash);
      _snapshotsByAccount.remove(hash);
      final tombstoneGeneration = _generationFrom(decoded!);
      if (tombstoneGeneration == null) {
        _generationsByAccount.remove(hash);
      } else {
        _generationsByAccount[hash] = tombstoneGeneration;
      }
      _plainRepairAccounts.remove(hash);
      if (store != null) {
        final deleted = await _deleteSecureSlots(hash);
        if (deleted) {
          _clearPendingAccounts.remove(hash);
          _activeSecretKeysByAccount.remove(hash);
        } else {
          _clearPendingAccounts.add(hash);
        }
      }
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }
    final settings = decoded == null ? null : _settingsFrom(decoded);
    if (decoded == null || settings == null) {
      if (store == null) {
        await _finishPreparation(
          hash,
          cleanupOldRaw: shouldCleanupOldRaw,
          cleanupMigrationClaim: migrationClaimed,
        );
        return;
      }
      final payload = await _readPayloadOrMarkUnavailable(
        hash,
        plainIsCorrupt: true,
      );
      if (payload == null) {
        if (_unavailableAccounts.contains(hash)) return;
        await _finishPreparation(
          hash,
          cleanupOldRaw: shouldCleanupOldRaw,
          cleanupMigrationClaim: migrationClaimed,
        );
        return;
      }
      final snapshot = payload.settingsSnapshot;
      if (snapshot == null) {
        // 旧 v1 secure payload 只有 secrets，无法从损坏的普通配置重建其余字段。
        _secretsByAccount[hash] = payload.secrets;
        _markUnavailable(hash, corruptPlain: true);
        return;
      }
      await _writePlainSettings(
        hash,
        snapshot,
        secure: true,
        generation: payload.generation,
      );
      _cachePayload(hash, payload);
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }

    if (store == null) {
      _secretsByAccount[hash] = _AISecretBundle.fromSettings(settings);
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }

    final isPending = decoded[_pendingField] == true;
    final isSecure = decoded[_secureMarkerField] == _secureMarkerValue;
    final plainGeneration = _generationFrom(decoded);
    if (isPending || !isSecure) {
      final _AISecurePayload? existingPayload;
      try {
        existingPayload = await _readSecurePayload(hash);
      } on AISecretsUnavailableException catch (error) {
        if (!error.corrupt && !isSecure) {
          // 首次升级或 pending 重试时，plain 仍是完整的既有配置。平台安全
          // 存储短暂不可读不能让旧用户无法启动；继续使用这份本来就存在的
          // legacy 副本，本进程不再迁移，下次启动会再次尝试。secure marker
          // 已存在时 plain 已脱敏，绝不能走此 fallback。
          _secretsByAccount[hash] = _AISecretBundle.fromSettings(settings);
          await _finishPreparation(
            hash,
            cleanupOldRaw: shouldCleanupOldRaw,
            cleanupMigrationClaim: migrationClaimed,
          );
          return;
        }
        if (isPending && error.corrupt) {
          // 显式 full pending 是上次 secure 写/回读失败留下的权威副本。
          // 若 secure 只写入了截断 JSON，应像登录态迁移一样用完整 plain 修复。
          final generation = plainGeneration ?? 1;
          final recovery = _AISecurePayload.fromSettings(
            settings,
            generation: generation,
          );
          final secured = await _writeAndVerifyPayload(hash, recovery);
          if (secured) {
            await _writePlainSettings(
              hash,
              settings,
              secure: true,
              generation: generation,
            );
          }
          _cachePayload(hash, recovery);
          await _finishPreparation(
            hash,
            cleanupOldRaw: shouldCleanupOldRaw,
            cleanupMigrationClaim: migrationClaimed,
          );
          return;
        }
        _markUnavailable(hash, corruptPlain: error.corrupt);
        return;
      }

      final existingSnapshot = existingPayload?.settingsSnapshot;
      if (existingSnapshot != null &&
          (plainGeneration == null ||
              plainGeneration <= existingPayload!.generation)) {
        final authoritativePayload = existingPayload!;
        // Keychain 可能跨卸载保留，而普通偏好可能从更旧备份恢复。没有
        // generation 或不比 secure 新的 full/pending 不能反向覆盖新快照。
        await _writePlainSettings(
          hash,
          existingSnapshot,
          secure: true,
          generation: authoritativePayload.generation,
        );
        _cachePayload(hash, authoritativePayload);
        await _finishPreparation(
          hash,
          cleanupOldRaw: shouldCleanupOldRaw,
          cleanupMigrationClaim: migrationClaimed,
        );
        return;
      }

      if (!isPending && existingPayload != null && existingSnapshot == null) {
        // marker 丢失不能被当成“完整 legacy 明文”。v1 secure 是唯一可信的
        // 凭据来源，先补回它再升级，避免用 scrubbed plain 清空全部 Key。
        existingPayload.secrets.hydrate(settings);
        final upgraded = _AISecurePayload.fromSettings(
          settings,
          generation: 1,
        );
        final secured = await _writeAndVerifyPayload(hash, upgraded);
        if (secured) {
          await _writePlainSettings(
            hash,
            settings,
            secure: true,
            generation: upgraded.generation,
          );
          _cachePayload(hash, upgraded);
        } else {
          _secretsByAccount[hash] = existingPayload.secrets;
          _generationsByAccount[hash] = existingPayload.generation;
        }
        await _finishPreparation(
          hash,
          cleanupOldRaw: shouldCleanupOldRaw,
          cleanupMigrationClaim: migrationClaimed,
        );
        return;
      }

      // 仅 legacy 明文本来就已暴露，或带有更高 generation 的 pending 才
      // 能作为权威恢复副本。安全存储失败时保留原明文，不制造新的暴露。
      final generation = plainGeneration ??
          ((existingPayload?.generation ?? 0) + 1).clamp(1, 1 << 62).toInt();
      final payload = _AISecurePayload.fromSettings(
        settings,
        generation: generation,
      );
      final secured = await _writeAndVerifyPayload(hash, payload);
      if (secured) {
        await _writePlainSettings(
          hash,
          settings,
          secure: true,
          generation: generation,
        );
      } else {
        await _writePlainSettings(
          hash,
          settings,
          pending: true,
          generation: generation,
        );
      }
      _cachePayload(hash, payload);
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }

    final payload = await _readPayloadOrMarkUnavailable(hash);
    if (payload == null) {
      if (_unavailableAccounts.contains(hash)) return;

      // 系统换机恢复只带回普通 marker，不会带回 KeyStore/ThisDeviceOnly。
      // 普通区仍含完整非敏感设置；在新设备建立一个空凭据的 v2 快照。
      final generation = plainGeneration ?? 1;
      final emptyPayload = _AISecurePayload.fromSettings(
        settings,
        generation: generation,
      );
      final secured = await _writeAndVerifyPayload(hash, emptyPayload);
      if (secured) {
        await _writePlainSettings(
          hash,
          settings,
          secure: true,
          generation: generation,
        );
      } else {
        await _writePlainSettings(
          hash,
          settings,
          pending: true,
          generation: generation,
        );
      }
      _cachePayload(hash, emptyPayload);
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }

    final snapshot = payload.settingsSnapshot;
    if (snapshot != null) {
      // secure v2 是最近一次先提交并回读验证过的完整快照。若进程在随后
      // 写普通脱敏副本前退出，这里仍能恢复最新配置。
      await _writePlainSettings(
        hash,
        snapshot,
        secure: true,
        generation: payload.generation,
      );
      _cachePayload(hash, payload);
      await _finishPreparation(
        hash,
        cleanupOldRaw: shouldCleanupOldRaw,
        cleanupMigrationClaim: migrationClaimed,
      );
      return;
    }

    // 兼容已经上线的 v1 secrets-only payload：用普通配置补齐完整快照，
    // 写入 v2 并验证后再继续保持普通区脱敏。
    payload.secrets.hydrate(settings);
    final upgraded = _AISecurePayload.fromSettings(settings, generation: 1);
    final secured = await _writeAndVerifyPayload(hash, upgraded);
    if (secured) {
      await _writePlainSettings(
        hash,
        settings,
        secure: true,
        generation: upgraded.generation,
      );
      _cachePayload(hash, upgraded);
    } else {
      // v1 凭据原本只存在 secure；升级抖动时继续使用旧 bundle，绝不主动
      // 降级写入普通偏好。若 secure 实际已写入 v2，下次启动会自行恢复。
      _secretsByAccount[hash] = payload.secrets;
      _generationsByAccount[hash] = payload.generation;
    }
    await _finishPreparation(
      hash,
      cleanupOldRaw: shouldCleanupOldRaw,
      cleanupMigrationClaim: migrationClaimed,
    );
  }

  static Future<_AISecurePayload?> _readPayloadOrMarkUnavailable(
    String hash, {
    bool plainIsCorrupt = false,
  }) async {
    try {
      return await _readSecurePayload(hash);
    } on AISecretsUnavailableException catch (error) {
      _markUnavailable(
        hash,
        corruptPlain: plainIsCorrupt || error.corrupt,
      );
      return null;
    }
  }

  static void _markUnavailable(String hash, {bool corruptPlain = false}) {
    _secretsByAccount.remove(hash);
    _snapshotsByAccount.remove(hash);
    _preparedAccounts.remove(hash);
    _unavailableAccounts.add(hash);
    if (corruptPlain) _corruptPlainAccounts.add(hash);
  }

  static Future<void> _finishPreparation(
    String hash, {
    bool cleanupOldRaw = false,
    bool cleanupMigrationClaim = false,
  }) async {
    // 删除失败时不宣布迁移完成，下一次启动仍会重试；此时账号 key 已经是
    // 可恢复副本，因此不会因重试而丢设置。
    if (cleanupOldRaw) await _removeCacheKey(_kOldKey);
    if (cleanupMigrationClaim) {
      await _removeCacheKey(_legacyMigrationKeyFor(hash));
    }
    _unavailableAccounts.remove(hash);
    _corruptPlainAccounts.remove(hash);
    _plainRepairAccounts.remove(hash);
    _preparedAccounts.add(hash);
  }

  static int? _generationFrom(Map<String, dynamic> json) {
    final value = json[_generationField];
    return value is int && value > 0 ? value : null;
  }

  static void _cachePayload(String hash, _AISecurePayload payload) {
    _secretsByAccount[hash] = payload.secrets;
    final snapshot = payload.settingsSnapshot;
    if (snapshot == null) {
      _snapshotsByAccount.remove(hash);
    } else {
      _snapshotsByAccount[hash] = snapshot.clone();
    }
    _generationsByAccount[hash] = payload.generation;
  }

  static int _nextGeneration(String hash) {
    final current = _generationsByAccount[hash] ?? 0;
    return current >= (1 << 62) ? current : current + 1;
  }

  /// 指定账号是否已存过 AI 设置（用于游客迁移判断目标账号是否「空」）。
  static bool hasSettings(String hash) {
    final raw = _rawFor(hash);
    if (raw == null) return false;
    return _decodeMap(raw)?[_clearedField] != true;
  }

  /// 读取指定账号 hash 的 AI 设置（不依赖当前登录态）。无记录则返回默认。
  /// 调用安全存储版本前应先 await [prepareAccount] 或使用 [loadForAsync]。
  static AISettings loadFor(String hash) {
    final snapshot = _snapshotsByAccount[hash];
    if (snapshot != null) return snapshot.clone();
    final raw = _rawFor(hash);
    if (raw == null) return AISettings.defaults();
    final decoded = _decodeMap(raw);
    if (decoded == null) return AISettings.defaults();
    if (decoded[_clearedField] == true) return AISettings.defaults();
    final settings = _settingsFrom(decoded);
    if (settings == null) return AISettings.defaults();
    _secretsByAccount[hash]?.hydrate(settings);
    return settings;
  }

  static Future<AISettings> loadForAsync(String hash) async {
    await prepareAccount(hash);
    if (_unavailableAccounts.contains(hash)) {
      throw AISecretsUnavailableException(
        hash,
        corrupt: _corruptPlainAccounts.contains(hash),
      );
    }
    if (_plainRepairAccounts.contains(hash)) {
      final snapshot = _snapshotsByAccount[hash];
      final generation = _generationsByAccount[hash];
      if (snapshot != null && generation != null) {
        try {
          await _writePlainSettings(
            hash,
            snapshot,
            secure: true,
            generation: generation,
          );
          _plainRepairAccounts.remove(hash);
        } catch (_) {
          // secure v2 已提交；普通脱敏镜像可稍后继续修复，不把已成功保存
          // 误报为失败，也不回滚 UI。
        }
      }
    }
    return loadFor(hash);
  }

  /// 后台 isolate 的严格只读恢复：不迁移、不 scrub、不写任何状态。
  static Future<AISettings> loadForBackground(String hash) async {
    final currentAccountHash = LoginDao.getAccountHash();
    final raw = _rawFor(hash) ??
        (currentAccountHash != null && hash == currentAccountHash
            ? _cachedString(_kOldKey)
            : null);
    final store = _secretStore;
    if (raw == null) {
      if (store == null) return AISettings.defaults();
      final payload = await _readSecurePayload(hash);
      final snapshot = payload?.settingsSnapshot;
      if (snapshot != null) return snapshot.clone();
      if (payload != null) throw AISecretsUnavailableException(hash);
      return AISettings.defaults();
    }

    final decoded = _decodeMap(raw);
    if (decoded?[_clearedField] == true) return AISettings.defaults();
    final settings = decoded == null ? null : _settingsFrom(decoded);
    if (decoded == null || settings == null) {
      if (store == null) return AISettings.defaults();
      final payload = await _readSecurePayload(hash);
      final snapshot = payload?.settingsSnapshot;
      if (snapshot != null) return snapshot.clone();
      if (payload != null) {
        throw AISecretsUnavailableException(hash, corrupt: true);
      }
      return AISettings.defaults();
    }

    if (store == null) {
      return settings;
    }

    if (decoded[_pendingField] == true ||
        decoded[_secureMarkerField] != _secureMarkerValue) {
      final payload = await _readSecurePayload(hash);
      final snapshot = payload?.settingsSnapshot;
      final plainGeneration = _generationFrom(decoded);
      if (snapshot != null &&
          (plainGeneration == null || plainGeneration <= payload!.generation)) {
        return snapshot.clone();
      }
      return settings;
    }

    final payload = await _readSecurePayload(hash);
    if (payload == null) throw AISecretsUnavailableException(hash);
    final snapshot = payload.settingsSnapshot;
    if (snapshot != null) return snapshot.clone();
    payload.secrets.hydrate(settings);
    return settings;
  }

  /// 同步读取当前账号的 AI 设置（HiCache 内存读是同步的）。
  static AISettings load() {
    final accountHash = LoginDao.getAccountHash();
    final hash = accountHash ?? 'guest';
    final key = keyFor(hash);
    var raw = _cachedString(key);
    // 兼容最早的未分账号设置：只迁到当前账号，源值写成功后再删除。
    if (raw == null && accountHash != null) {
      final oldRaw = _cachedString(_kOldKey);
      if (oldRaw != null) {
        raw = oldRaw;
      }
    }
    if (raw == null) return AISettings.defaults();
    final decoded = _decodeMap(raw);
    if (decoded == null) return AISettings.defaults();
    if (decoded[_clearedField] == true) return AISettings.defaults();
    final settings = _settingsFrom(decoded);
    if (settings == null) return AISettings.defaults();
    _secretsByAccount[hash]?.hydrate(settings);
    return settings;
  }

  static Future<void> save(AISettings settings) async {
    await saveFor(LoginDao.getAccountHash() ?? 'guest', settings);
  }

  /// 返回经过持久化边界健康状态校正后，实际写入的权威快照。
  static Future<AISettings> saveFor(String hash, AISettings settings) {
    _invalidateExecution(hash, settings);
    // UI 会原地编辑 provider；必须在任何 await/排队前固定本次 host+key 快照。
    final snapshot = settings.clone();
    final previous = _saveTails[hash];
    final ready = previous?.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ) ??
        Future<void>.value();
    late final Future<AISettings> operation;
    operation = ready.then((_) => _saveForNow(hash, snapshot)).whenComplete(() {
      if (identical(_saveTails[hash], operation)) _saveTails.remove(hash);
    });
    _saveTails[hash] = operation;
    return operation;
  }

  /// 仅当账号在同一持久化队列内确认没有任何设置状态时写入 [settings]。
  ///
  /// prepare、check、write 共用 [_saveTails] 的同账号串行边界，避免游客迁移
  /// 在判断为空后覆盖用户刚保存的设置。clear tombstone 代表用户明确清除，
  /// 同样属于权威状态，不能借“缺少有效设置”把游客配置复活。
  static Future<bool> saveForIfAbsent(String hash, AISettings settings) {
    _invalidateExecution(hash, settings);
    final snapshot = settings.clone();
    final previous = _saveTails[hash];
    final ready = previous?.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ) ??
        Future<void>.value();
    late final Future<bool> operation;
    operation =
        ready.then((_) => _saveForIfAbsentNow(hash, snapshot)).whenComplete(() {
      if (identical(_saveTails[hash], operation)) _saveTails.remove(hash);
    });
    _saveTails[hash] = operation;
    return operation;
  }

  static Future<bool> _saveForIfAbsentNow(
    String hash,
    AISettings settings,
  ) async {
    // 已在账号队列中，直接准备，避免调用 prepareAccount 再次入队自锁。
    // 即使未配置 secure store 也要先认领旧版全局设置，再判断是否为空。
    if (!_preparedAccounts.contains(hash)) {
      await _prepareAccount(hash);
    }
    // 普通区的任意账号记录（包括 tombstone/损坏记录）都不是“从未设置”；
    // secure 已提交但普通区待修复时，内存权威快照也必须阻止条件导入。
    if (_rawFor(hash) != null || _snapshotsByAccount.containsKey(hash)) {
      return false;
    }
    await _saveForNow(hash, settings);
    return true;
  }

  static Future<AISettings> _saveForNow(
      String hash, AISettings settings) async {
    final store = _secretStore;
    final existingPlain = _rawFor(hash);
    final hadClearTombstone = existingPlain != null &&
        _decodeMap(existingPlain)?[_clearedField] == true;
    if (store != null && _clearPendingAccounts.contains(hash)) {
      if (!await _deleteSecureSlots(hash)) {
        throw AISecretsUnavailableException(hash);
      }
      _clearPendingAccounts.remove(hash);
      _activeSecretKeysByAccount.remove(hash);
    }
    if (_corruptPlainAccounts.contains(hash)) {
      throw AISecretsUnavailableException(hash, corrupt: true);
    }
    final needsSecretRecovery = _unavailableAccounts.contains(hash);
    AISettings? recoveredHealthBaseline;
    if (store != null && !_preparedAccounts.contains(hash)) {
      // 当前 save 已经位于账号队列中，直接执行内部准备，避免再次入队自锁。
      await _prepareAccount(hash);
    }
    if (_corruptPlainAccounts.contains(hash)) {
      throw AISecretsUnavailableException(hash, corrupt: true);
    }
    if (needsSecretRecovery || _unavailableAccounts.contains(hash)) {
      final existingPayload = await _readSecurePayload(hash);
      final existingSecrets =
          _secretsByAccount[hash] ?? existingPayload?.secrets;
      if (existingSecrets == null) {
        throw AISecretsUnavailableException(hash);
      }
      existingSecrets.hydrateMissing(settings);
      _secretsByAccount[hash] = existingSecrets;
      if (existingPayload != null) {
        _generationsByAccount[hash] = existingPayload.generation;
        recoveredHealthBaseline = existingPayload.settingsSnapshot?.clone();
      }
      _unavailableAccounts.remove(hash);
      _preparedAccounts.add(hash);
    }

    // Provider、备份恢复、游客迁移及未来同步最终都经过这里。用当前已持久化
    // 配置作为基线，页面外的直接 saveFor 也不能携带过期 success。
    final previousSettings =
        recoveredHealthBaseline ?? _existingSettingsForHealthComparison(hash);
    final settingsToSave = reconcileAIHealthState(
      previous: previousSettings,
      next: settings,
    );
    final changedProviderIds = changedProbeProviderIds(
      previousSettings,
      settingsToSave,
    );
    if (changedProviderIds.isNotEmpty) {
      await TranslationModelProbeCache.shared.invalidateProviders(
        accountHash: hash,
        providerIds: changedProviderIds,
      );
    }

    if (store == null) {
      await _writePlainSettings(hash, settingsToSave);
      _secretsByAccount[hash] = _AISecretBundle.fromSettings(settingsToSave);
      _preparedAccounts.add(hash);
      return settingsToSave.clone();
    }

    final payload = _AISecurePayload.fromSettings(
      settingsToSave,
      generation: _nextGeneration(hash),
    );

    // 正常路径绝不先把凭据写入普通存储。secure v2 包含完整快照；进程即使
    // 在随后写脱敏副本前退出，重启也能从 secure 恢复全部配置。
    final secured = await _writeAndVerifyPayload(hash, payload);
    if (!secured) {
      _secretsByAccount.remove(hash);
      _snapshotsByAccount.remove(hash);
      _generationsByAccount.remove(hash);
      _plainRepairAccounts.remove(hash);
      _preparedAccounts.remove(hash);
      throw AISecretsUnavailableException(hash);
    }
    try {
      await _writePlainSettings(
        hash,
        settingsToSave,
        secure: true,
        generation: payload.generation,
      );
    } catch (_) {
      if (hadClearTombstone) {
        // tombstone 在重启时会删除 secure；若无法持久替换它，就不能把新
        // secure 快照报告为成功，否则进程退出会永久丢掉这次设置。
        final deleted = await _deleteSecureSlots(hash);
        if (deleted) {
          _clearPendingAccounts.remove(hash);
          _activeSecretKeysByAccount.remove(hash);
        } else {
          _clearPendingAccounts.add(hash);
        }
        _secretsByAccount.remove(hash);
        _snapshotsByAccount.remove(hash);
        _generationsByAccount.remove(hash);
        _plainRepairAccounts.remove(hash);
        _preparedAccounts.add(hash);
        throw StateError('AI 设置写入失败: ${keyFor(hash)}');
      }
      // secure 已是不可回滚的权威新快照。保留完整内存快照并把普通区标记
      // 为待修复，调用方仍视为保存成功。
      _cachePayload(hash, payload);
      _plainRepairAccounts.add(hash);
      _unavailableAccounts.remove(hash);
      _corruptPlainAccounts.remove(hash);
      _preparedAccounts.add(hash);
      return settingsToSave.clone();
    }
    _cachePayload(hash, payload);
    _plainRepairAccounts.remove(hash);
    _unavailableAccounts.remove(hash);
    _corruptPlainAccounts.remove(hash);
    _preparedAccounts.add(hash);
    return settingsToSave.clone();
  }

  static AISettings? _existingSettingsForHealthComparison(String hash) {
    final snapshot = _snapshotsByAccount[hash];
    if (snapshot != null) return snapshot.clone();
    final raw = _rawFor(hash);
    if (raw == null) return null;
    final decoded = _decodeMap(raw);
    if (decoded == null || decoded[_clearedField] == true) return null;
    final settings = _settingsFrom(decoded);
    if (settings == null) return null;
    _secretsByAccount[hash]?.hydrate(settings);
    return settings;
  }

  /// 清除当前账号的 AI 设置。先写持久 tombstone，再清 secure；即使安全存储
  /// 删除暂时失败，后续启动也绝不会从残留 v2 快照复活旧凭据。
  static Future<void> clear() => clearFor(LoginDao.getAccountHash() ?? 'guest');

  /// 自助修复安全凭据：普通设置仍可解析时保留 provider/host/model、搜索参数
  /// 与 MCP URL，仅清空 Key/headers；普通设置也损坏时退化为完整 reset。
  static Future<bool> resetCredentialsFor(String hash) async {
    final raw = _rawFor(hash);
    final decoded = raw == null ? null : _decodeMap(raw);
    final current = decoded == null || decoded[_clearedField] == true
        ? null
        : _settingsFrom(decoded);
    final preserved = current == null ? null : _scrubbed(current);
    await clearFor(hash);
    if (preserved == null) return false;
    await saveFor(hash, preserved);
    return true;
  }

  static Future<void> clearFor(String hash) {
    _invalidateExecution(hash);
    final previous = _saveTails[hash];
    final ready = previous?.then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ) ??
        Future<void>.value();
    late final Future<void> operation;
    operation = ready.then((_) => _clearForNow(hash)).whenComplete(() {
      if (identical(_saveTails[hash], operation)) _saveTails.remove(hash);
    });
    _saveTails[hash] = operation;
    return operation;
  }

  static Future<void> _clearForNow(String hash) async {
    final store = _secretStore;
    var generation = _generationsByAccount[hash];
    if (generation == null && store != null) {
      try {
        generation = (await _readSecurePayload(hash))?.generation;
      } catch (_) {
        // tombstone 仍优先落盘；若后续删除也失败，clearPending 会阻止在
        // generation 未知时直接重配覆盖残留槽。
      }
    }
    await TranslationModelProbeCache.shared.clearAccount(hash);
    await _setCacheString(
      keyFor(hash),
      jsonEncode(<String, dynamic>{
        _clearedField: true,
        if (generation != null && generation > 0) _generationField: generation,
      }),
    );
    _secretsByAccount.remove(hash);
    _snapshotsByAccount.remove(hash);
    if (generation == null) {
      _generationsByAccount.remove(hash);
    } else {
      _generationsByAccount[hash] = generation;
    }
    _plainRepairAccounts.remove(hash);
    _preparedAccounts.add(hash);
    _unavailableAccounts.remove(hash);
    _corruptPlainAccounts.remove(hash);
    if (store != null) {
      final deleted = await _deleteSecureSlots(hash);
      if (deleted) {
        _clearPendingAccounts.remove(hash);
        _activeSecretKeysByAccount.remove(hash);
      } else {
        _clearPendingAccounts.add(hash);
      }
    }
  }

  static String? _rawFor(String hash) => _cachedString(keyFor(hash));

  static Object? _cachedValue(String key) =>
      HiCache.getInstance().prefs?.get(key);

  static String? _cachedString(String key) {
    final value = _cachedValue(key);
    return value is String ? value : null;
  }

  static Map<String, dynamic>? _decodeMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static AISettings? _settingsFrom(Map<String, dynamic> decoded) {
    try {
      final settings = AISettings.fromJson(decoded);
      return _hasUniqueCredentialIds(settings) ? settings : null;
    } catch (_) {
      return null;
    }
  }

  static Future<_AISecurePayload?> _readSecurePayload(String hash) async {
    final store = _secretStore;
    if (store == null) return null;
    final primary = secretKeyFor(hash);
    final secondary = secondarySecretKeyFor(hash);
    final quarantineValue = _cachedValue(
      _verificationQuarantineKeyFor(hash),
    );
    final String? quarantinedKey;
    if (quarantineValue == null) {
      quarantinedKey = null;
    } else if (quarantineValue == primary || quarantineValue == secondary) {
      quarantinedKey = quarantineValue as String;
    } else {
      throw AISecretsUnavailableException(
        hash,
        corrupt: true,
        cause: const FormatException('Invalid secure verification quarantine'),
      );
    }
    final candidates = <({String key, _AISecurePayload payload})>[];
    Object? readError;
    Object? corruptError;
    for (final key in [primary, secondary]) {
      if (key == quarantinedKey) continue;
      final String? raw;
      try {
        raw = await store.read(key);
      } catch (error) {
        readError ??= error;
        continue;
      }
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = _decodeMap(raw);
        if (decoded == null) {
          throw const FormatException('Invalid AI secure JSON');
        }
        candidates.add((key: key, payload: _AISecurePayload.fromJson(decoded)));
      } catch (error) {
        corruptError ??= error;
      }
    }
    if (readError != null) {
      // 任一槽读取异常时不能回退到较旧可读槽，否则会把 plain generation
      // 一并降级，后续保存可能永久覆盖暂时不可读的新快照。
      throw AISecretsUnavailableException(hash, cause: readError);
    }
    if (candidates.isEmpty) {
      _activeSecretKeysByAccount.remove(hash);
      if (corruptError != null) {
        throw AISecretsUnavailableException(
          hash,
          corrupt: true,
          cause: corruptError,
        );
      }
      return null;
    }
    candidates.sort(
      (left, right) => left.payload.generation.compareTo(
        right.payload.generation,
      ),
    );
    final selected = candidates.last;
    _activeSecretKeysByAccount[hash] = selected.key;
    return selected.payload;
  }

  static Future<bool> _writeAndVerifyPayload(
    String hash,
    _AISecurePayload payload,
  ) async {
    final store = _secretStore;
    if (store == null) return false;
    final raw = jsonEncode(payload.toJson());
    final primary = secretKeyFor(hash);
    final secondary = secondarySecretKeyFor(hash);
    final active = _activeSecretKeysByAccount[hash];
    final target = active == primary ? secondary : primary;
    final quarantineKey = _verificationQuarantineKeyFor(hash);
    try {
      await _setCacheString(
        quarantineKey,
        target,
        applyTestOverride: false,
      );
      if (_cachedString(quarantineKey) != target) return false;
    } catch (_) {
      return false;
    }
    try {
      await store.write(target, raw);
    } catch (_) {
      return false;
    }
    String? readBack;
    try {
      readBack = await store.read(target);
    } catch (_) {
      // 首次回读可能只是平台安全存储的瞬时故障，立即有界重试一次。
      // 不能因 write Future 完成就盲目切换活动槽：底层可能静默丢写。
      try {
        readBack = await store.read(target);
      } catch (_) {
        return false;
      }
    }
    if (readBack != raw) return false;
    try {
      final decoded = _decodeMap(readBack!);
      final verified =
          decoded == null ? null : _AISecurePayload.fromJson(decoded);
      if (verified == null || verified.generation != payload.generation) {
        return false;
      }
    } catch (_) {
      return false;
    }
    var quarantineStateConfirmed = false;
    try {
      await _removeCacheKey(quarantineKey);
      quarantineStateConfirmed = true;
    } catch (_) {
      // legacy SharedPreferences.remove 会先清内存 cache，再调用平台层。
      // 平台删除失败时必须 reload 磁盘态，不能把 cache null 当作成功确认。
      final prefs = HiCache.getInstance().prefs;
      if (prefs != null) {
        try {
          await prefs.reload();
          quarantineStateConfirmed = true;
        } catch (_) {
          // 无法确认平台态时重新持久化隔离标记，并按提交失败处理。
          try {
            await _setCacheString(
              quarantineKey,
              target,
              applyTestOverride: false,
            );
          } catch (_) {}
          return false;
        }
      }
    }
    if (!quarantineStateConfirmed || _cachedValue(quarantineKey) != null) {
      return false;
    }
    _activeSecretKeysByAccount[hash] = target;
    return true;
  }

  static Future<void> _writePlainSettings(
    String hash,
    AISettings settings, {
    bool secure = false,
    bool pending = false,
    int? generation,
  }) async {
    if ((secure || pending) && (generation == null || generation < 1)) {
      throw ArgumentError.value(generation, 'generation');
    }
    final value = secure ? _scrubbed(settings) : settings.clone();
    final json = value.toJson();
    if (secure) json[_secureMarkerField] = _secureMarkerValue;
    if (pending) json[_pendingField] = true;
    if (generation != null) json[_generationField] = generation;
    await _setCacheString(keyFor(hash), jsonEncode(json));
  }

  static Future<void> _setCacheString(
    String key,
    String value, {
    bool applyTestOverride = true,
  }) async {
    if (applyTestOverride) {
      final override = plainWriteOverrideForTest;
      if (override != null) {
        if (!await override(key, value)) {
          throw StateError('AI 设置写入失败: $key');
        }
        return;
      }
    }
    final prefs = HiCache.getInstance().prefs;
    if (prefs == null || !await prefs.setString(key, value)) {
      throw StateError('AI 设置写入失败: $key');
    }
  }

  static Future<void> _removeCacheKey(String key) async {
    final prefs = HiCache.getInstance().prefs;
    if (prefs == null || !await prefs.remove(key)) {
      throw StateError('AI 设置删除失败: $key');
    }
  }

  static AISettings _scrubbed(AISettings settings) {
    final copy = settings.clone();
    for (final provider in copy.providers) {
      provider.apiKey = '';
    }
    copy
      ..tavilyApiKey = ''
      ..exaApiKey = ''
      ..bochaApiKey = ''
      ..zhipuApiKey = ''
      ..mcpServers = [
        for (final server in copy.mcpServers)
          server.copyWith(headers: const <String, String>{}),
      ];
    return copy;
  }

  static Future<bool> _deleteSecureSlots(String hash) async {
    final store = _secretStore;
    if (store == null) return true;
    var deleted = true;
    for (final key in [secretKeyFor(hash), secondarySecretKeyFor(hash)]) {
      try {
        await store.delete(key);
      } catch (_) {
        deleted = false;
      }
    }
    if (deleted) {
      final quarantineKey = _verificationQuarantineKeyFor(hash);
      if (_cachedValue(quarantineKey) != null) {
        try {
          await _removeCacheKey(quarantineKey);
        } catch (_) {
          // 两个 secure 槽均已删除；marker 清理失败只留下无害的隔离状态。
        }
      }
    }
    return deleted;
  }

  /// 测试隔离；生产代码不调用。
  static void resetSecureStateForTest() {
    _executionConfigurations.clear();
    _executionRevisions.clear();
    _secretStore = null;
    _secretsByAccount.clear();
    _snapshotsByAccount.clear();
    _generationsByAccount.clear();
    _activeSecretKeysByAccount.clear();
    _plainRepairAccounts.clear();
    _clearPendingAccounts.clear();
    _preparedAccounts.clear();
    _unavailableAccounts.clear();
    _corruptPlainAccounts.clear();
    _preparingAccounts.clear();
    _saveTails.clear();
    plainWriteOverrideForTest = null;
  }
}

Set<String> changedProbeProviderIds(
  AISettings? previous,
  AISettings next,
) {
  final beforeById = <String, AiProvider>{
    if (previous != null)
      for (final provider in previous.providers) provider.id: provider,
  };
  final afterById = <String, AiProvider>{
    for (final provider in next.providers) provider.id: provider,
  };
  final changed = <String>{};
  for (final id in {...beforeById.keys, ...afterById.keys}) {
    final before = beforeById[id];
    final after = afterById[id];
    if (before == null ||
        after == null ||
        !AIProviderHealthConfiguration.capture(before).matches(after)) {
      changed.add(id);
    }
  }
  return changed;
}

bool _hasUniqueCredentialIds(AISettings settings) {
  final providerIds = <String>{};
  for (final provider in settings.providers) {
    if (provider.id.isEmpty || !providerIds.add(provider.id)) return false;
  }
  final mcpIds = <String>{};
  for (final server in settings.mcpServers) {
    if (server.id.isEmpty || !mcpIds.add(server.id)) return false;
  }
  return true;
}

class _AISecurePayload {
  static const _schemaVersion = 2;

  final _AISecretBundle secrets;
  final AISettings? settingsSnapshot;
  final int generation;

  const _AISecurePayload({
    required this.secrets,
    required this.settingsSnapshot,
    required this.generation,
  });

  factory _AISecurePayload.fromSettings(
    AISettings settings, {
    required int generation,
  }) {
    if (!_hasUniqueCredentialIds(settings)) {
      throw const FormatException('Duplicate provider or MCP id');
    }
    final snapshot = settings.clone();
    return _AISecurePayload(
      secrets: _AISecretBundle.fromSettings(snapshot),
      settingsSnapshot: snapshot,
      generation: generation,
    );
  }

  factory _AISecurePayload.fromJson(Map<String, dynamic> json) {
    final schema = json['_schema'];
    if (schema == null) {
      // v1：历史版本只保存 secret bundle，没有完整设置快照。
      return _AISecurePayload(
        secrets: _AISecretBundle.fromJson(json),
        settingsSnapshot: null,
        generation: 0,
      );
    }
    if (schema != _schemaVersion) {
      throw const FormatException('Unsupported AI secure payload schema');
    }
    final rawSettings = json['settings'];
    final rawSecrets = json['secrets'];
    final generation = json['generation'];
    if (rawSettings is! Map ||
        rawSecrets is! Map ||
        generation is! int ||
        generation < 1) {
      throw const FormatException('Invalid AI secure payload');
    }
    final settings = AISettings.fromJson(
      Map<String, dynamic>.from(rawSettings),
    );
    if (!_hasUniqueCredentialIds(settings)) {
      throw const FormatException('Duplicate provider or MCP id');
    }
    final secrets = _AISecretBundle.fromJson(
      Map<String, dynamic>.from(rawSecrets),
    );
    if (!secrets.matches(settings)) {
      throw const FormatException('AI secure payload secrets mismatch');
    }
    return _AISecurePayload(
      secrets: secrets,
      settingsSnapshot: settings,
      generation: generation,
    );
  }

  Map<String, dynamic> toJson() => {
        '_schema': _schemaVersion,
        'generation': generation,
        'settings': settingsSnapshot?.toJson(),
        'secrets': secrets.toJson(),
      };
}

class _AISecretBundle {
  final Map<String, String> providerApiKeys;
  final String tavilyApiKey;
  final String exaApiKey;
  final String bochaApiKey;
  final String zhipuApiKey;
  final Map<String, Map<String, String>> mcpHeaders;

  const _AISecretBundle({
    required this.providerApiKeys,
    required this.tavilyApiKey,
    required this.exaApiKey,
    required this.bochaApiKey,
    required this.zhipuApiKey,
    required this.mcpHeaders,
  });

  factory _AISecretBundle.fromSettings(AISettings settings) => _AISecretBundle(
        providerApiKeys: {
          for (final provider in settings.providers)
            provider.id: provider.apiKey,
        },
        tavilyApiKey: settings.tavilyApiKey,
        exaApiKey: settings.exaApiKey,
        bochaApiKey: settings.bochaApiKey,
        zhipuApiKey: settings.zhipuApiKey,
        mcpHeaders: {
          for (final server in settings.mcpServers)
            server.id: Map<String, String>.from(server.headers),
        },
      );

  factory _AISecretBundle.fromJson(Map<String, dynamic> json) {
    final rawProviderKeys = json['providerApiKeys'];
    final rawMcpHeaders = json['mcpHeaders'];
    final tavily = json['tavilyApiKey'];
    final exa = json['exaApiKey'];
    final bocha = json['bochaApiKey'];
    final zhipu = json['zhipuApiKey'];
    if (rawProviderKeys is! Map ||
        rawMcpHeaders is! Map ||
        tavily is! String ||
        exa is! String ||
        bocha is! String ||
        zhipu is! String) {
      throw const FormatException('Invalid AI secret bundle');
    }
    return _AISecretBundle(
      providerApiKeys: _strictStringMap(rawProviderKeys),
      tavilyApiKey: tavily,
      exaApiKey: exa,
      bochaApiKey: bocha,
      zhipuApiKey: zhipu,
      mcpHeaders: _strictMcpHeaders(rawMcpHeaders),
    );
  }

  Map<String, dynamic> toJson() => {
        'providerApiKeys': providerApiKeys,
        'tavilyApiKey': tavilyApiKey,
        'exaApiKey': exaApiKey,
        'bochaApiKey': bochaApiKey,
        'zhipuApiKey': zhipuApiKey,
        'mcpHeaders': mcpHeaders,
      };

  void hydrate(AISettings settings) {
    for (final provider in settings.providers) {
      provider.apiKey = providerApiKeys[provider.id] ?? '';
    }
    settings
      ..tavilyApiKey = tavilyApiKey
      ..exaApiKey = exaApiKey
      ..bochaApiKey = bochaApiKey
      ..zhipuApiKey = zhipuApiKey
      ..mcpServers = [
        for (final server in settings.mcpServers)
          server.copyWith(
            headers: mcpHeaders[server.id] ?? const <String, String>{},
          ),
      ];
  }

  /// secure storage 曾短暂不可用时，只补回加载结果里的空字段。
  /// 非空字段视为用户本轮主动输入的新值，不被旧 secret 覆盖。
  void hydrateMissing(AISettings settings) {
    for (final provider in settings.providers) {
      if (provider.apiKey.isEmpty) {
        provider.apiKey = providerApiKeys[provider.id] ?? '';
      }
    }
    if (settings.tavilyApiKey.isEmpty) settings.tavilyApiKey = tavilyApiKey;
    if (settings.exaApiKey.isEmpty) settings.exaApiKey = exaApiKey;
    if (settings.bochaApiKey.isEmpty) settings.bochaApiKey = bochaApiKey;
    if (settings.zhipuApiKey.isEmpty) settings.zhipuApiKey = zhipuApiKey;
    settings.mcpServers = [
      for (final server in settings.mcpServers)
        server.headers.isEmpty
            ? server.copyWith(
                headers: mcpHeaders[server.id] ?? const <String, String>{},
              )
            : server,
    ];
  }

  bool matches(AISettings settings) {
    if (tavilyApiKey != settings.tavilyApiKey ||
        exaApiKey != settings.exaApiKey ||
        bochaApiKey != settings.bochaApiKey ||
        zhipuApiKey != settings.zhipuApiKey) {
      return false;
    }
    final providersById = {
      for (final provider in settings.providers) provider.id: provider,
    };
    for (final provider in settings.providers) {
      final hasStored = providerApiKeys.containsKey(provider.id);
      if ((!hasStored && provider.apiKey.isNotEmpty) ||
          (hasStored && providerApiKeys[provider.id] != provider.apiKey)) {
        return false;
      }
    }
    if (providerApiKeys.keys.any((id) => !providersById.containsKey(id))) {
      return false;
    }

    final serversById = {
      for (final server in settings.mcpServers) server.id: server,
    };
    for (final server in settings.mcpServers) {
      final stored = mcpHeaders[server.id];
      if ((stored == null && server.headers.isNotEmpty) ||
          (stored != null && !_sameStringMap(stored, server.headers))) {
        return false;
      }
    }
    return !mcpHeaders.keys.any((id) => !serversById.containsKey(id));
  }

  static Map<String, String> _strictStringMap(Map raw) {
    final result = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Invalid string map in AI secrets');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }

  static Map<String, Map<String, String>> _strictMcpHeaders(Map raw) {
    final result = <String, Map<String, String>>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid MCP headers in AI secrets');
      }
      result[entry.key as String] = _strictStringMap(entry.value as Map);
    }
    return result;
  }

  static bool _sameStringMap(
    Map<String, String> left,
    Map<String, String> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }
}
