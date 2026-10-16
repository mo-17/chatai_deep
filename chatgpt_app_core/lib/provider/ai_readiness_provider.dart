import 'dart:convert';

import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_evidence_loader.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:login_sdk/dao/backend_host.dart';

typedef AIReadinessStorageOpener = Future<HiDBManager> Function(
  String accountHash,
);

typedef AIReadinessEvidenceReader = Future<AIOnboardingEvidence> Function({
  required String accountHash,
  required AISettings settings,
  HiDBManager? storage,
});

/// 账号级 AI readiness 与非打断式 onboarding 的唯一 UI 状态源。
///
/// [synchronize] 只同步 ProxyProvider 传入的内存设置，绝不打开数据库；首次
/// 旧用户识别只能由迁移流程完成后显式调用 [initialize]。所有异步结果都绑定
/// account + epoch，登录切换期间完成的旧请求不会污染新账号。
final class AIReadinessProvider extends ChangeNotifier {
  final AIOnboardingStore _onboardingStore;
  late final AIReadinessEvidenceReader _evidenceReader;

  AISettings _settings = AISettings.defaults();
  String? _settingsFingerprint;
  String? _accountHash;
  bool _isGuest = false;
  bool _initialized = false;
  bool _disposed = false;
  int _settingsVersion = 0;
  int _epoch = 0;

  AIReadyState _state = const AIReadyState.loading();
  AIOnboardingStatus _onboardingStatus = AIOnboardingStatus.unseen;

  AIReadinessProvider({
    AIOnboardingStore? onboardingStore,
    AIOnboardingEvidenceLoader? evidenceLoader,
    AIReadinessStorageOpener? storageOpener,
    AIReadinessEvidenceReader? evidenceReader,
  }) : _onboardingStore = onboardingStore ?? AIOnboardingStore() {
    ModelCatalog.executionChanges.addListener(_refreshDerived);
    AiCatalogIdentity.changes.addListener(_refreshDerived);
    BackendConfig.changes.addListener(_refreshDerived);
    final loader = evidenceLoader ?? AIOnboardingEvidenceLoader();
    final openStorage = storageOpener ?? _defaultOpenStorage;
    _evidenceReader = evidenceReader ??
        ({
          required String accountHash,
          required AISettings settings,
          HiDBManager? storage,
        }) async {
          final accountStorage = storage ?? await openStorage(accountHash);
          return loader.load(
            accountHash: accountHash,
            storage: accountStorage,
            settings: settings,
          );
        };
  }

  AIReadyState _resolve() => resolveAIReadiness(
      settings: _settings,
      isGuest: _isGuest,
      accountHash: _accountHash,
      origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);

  void _refreshDerived() {
    if (_disposed || !_initialized) return;
    final next = _resolve();
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  static Future<HiDBManager> _defaultOpenStorage(String accountHash) =>
      HiDBManager.instance(dbName: accountHash);

  AIReadyState get state => _state;
  AIOnboardingStatus get onboardingStatus => _onboardingStatus;
  bool get initialized => _initialized;

  bool get showProactiveCard {
    if (!_initialized || _onboardingStatus != AIOnboardingStatus.unseen) {
      return false;
    }
    return switch (_state.status) {
      AIReadyStatus.loading || AIReadyStatus.ready => false,
      _ => true,
    };
  }

  /// 由 `ChangeNotifierProxyProvider` 调用。这里只做同步纯计算，不能读 DB。
  void synchronize({
    required AISettings settings,
    required String accountHash,
    required bool isGuest,
  }) {
    if (accountHash.trim().isEmpty) {
      throw ArgumentError.value(accountHash, 'accountHash', '不能为空');
    }
    final previousAccount = _accountHash;
    final accountChanged =
        previousAccount != null && previousAccount != accountHash;
    final fingerprint = jsonEncode(settings.toJson());
    final settingsChanged = _settingsFingerprint != fingerprint;
    final guestChanged = _isGuest != isGuest;

    _settings = settings.clone();
    _settingsFingerprint = fingerprint;
    _accountHash = accountHash;
    _isGuest = isGuest;
    if (settingsChanged) _settingsVersion++;

    if (accountChanged) {
      final hadVisibleState = _initialized ||
          _state != const AIReadyState.loading() ||
          _onboardingStatus != AIOnboardingStatus.unseen;
      _epoch++;
      _initialized = false;
      _state = const AIReadyState.loading();
      _onboardingStatus = AIOnboardingStatus.unseen;
      if (hadVisibleState) notifyListeners();
      return;
    }

    if (!_initialized || (!settingsChanged && !guestChanged)) return;
    final next = _resolve();
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  /// 在 guest migration 的决策/导入完成后初始化当前账号。
  ///
  /// [storage] 可复用迁移流程已经打开的目标账号 DB；未传时才按账号打开。
  Future<void> initialize({
    String? expectedAccountHash,
    HiDBManager? storage,
  }) async {
    final accountHash = _requireAccountHash();
    if (expectedAccountHash != null && expectedAccountHash != accountHash) {
      throw StateError(
        '账号已切换：expected=$expectedAccountHash, current=$accountHash',
      );
    }
    final epoch = ++_epoch;
    if (!_initialized && _state != const AIReadyState.loading()) {
      _state = const AIReadyState.loading();
      notifyListeners();
    }

    try {
      AIOnboardingEvidence evidence;
      // 设置可能在 DB 查询期间更新。只要账号/epoch 未变，就用最新设置重读
      // 证据，避免把刚完成配置的新用户仍分类成空白账号。
      while (true) {
        final version = _settingsVersion;
        evidence = await _evidenceReader(
          accountHash: accountHash,
          settings: _settings.clone(),
          storage: storage,
        );
        if (!_isCurrent(epoch, accountHash)) return;
        if (version == _settingsVersion) break;
      }

      final status = await _onboardingStore.classify(
        expectedAccountHash: accountHash,
        evidence: evidence,
      );
      if (!_isCurrent(epoch, accountHash)) return;

      _onboardingStatus = status;
      _state = _resolve();
      _initialized = true;
      notifyListeners();
    } catch (_) {
      // 账号切换是正常竞态，旧账号的失败不应冒泡到新页面。
      if (!_isCurrent(epoch, accountHash)) return;
      rethrow;
    }
  }

  Future<void> refresh({HiDBManager? storage}) => initialize(
        expectedAccountHash: _requireAccountHash(),
        storage: storage,
      );

  Future<void> dismiss() async {
    if (!_initialized || _onboardingStatus != AIOnboardingStatus.unseen) {
      return;
    }
    await _saveOnboardingStatus(AIOnboardingStatus.dismissed);
  }

  Future<void> markCompleted() async {
    if (!_initialized || _onboardingStatus == AIOnboardingStatus.completed) {
      return;
    }
    await _saveOnboardingStatus(AIOnboardingStatus.completed);
  }

  Future<void> _saveOnboardingStatus(AIOnboardingStatus status) async {
    final accountHash = _requireAccountHash();
    final epoch = _epoch;
    await _onboardingStore.save(
      status,
      expectedAccountHash: accountHash,
    );
    if (!_isCurrent(epoch, accountHash) || !_initialized) return;
    if (_onboardingStatus == status) return;
    _onboardingStatus = status;
    notifyListeners();
  }

  String _requireAccountHash() {
    final value = _accountHash;
    if (value == null) {
      throw StateError('AIReadinessProvider 尚未同步账号设置');
    }
    return value;
  }

  bool _isCurrent(int epoch, String accountHash) =>
      !_disposed && epoch == _epoch && _accountHash == accountHash;

  @override
  void dispose() {
    ModelCatalog.executionChanges.removeListener(_refreshDerived);
    AiCatalogIdentity.changes.removeListener(_refreshDerived);
    BackendConfig.changes.removeListener(_refreshDerived);
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
