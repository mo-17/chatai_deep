import 'dart:convert';

import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';

class AISettingsAccountChangedException implements Exception {
  const AISettingsAccountChangedException();

  @override
  String toString() => '账号已切换，已取消旧页面的设置保存';
}

class AISettingsProvider extends ChangeNotifier {
  static AISettingsProvider? _instance;
  static AISettingsProvider? get instance => _instance;

  AISettings _settings = AISettingsDao.load();
  late AISettings _persistedSettings = _settings.clone();
  int _revision = 0;
  int _stateEpoch = 0;
  String _accountHash = LoginDao.getAccountHash() ?? 'guest';
  AISettings get settings => _settings;
  String get accountHash => _accountHash;

  AISettingsProvider() {
    _instance = this;
  }

  ///重新加载当前账号的 AI 设置（登录后、切换账号后调用）
  Future<void> load() async {
    final epoch = ++_stateEpoch;
    final revisionAtStart = _revision;
    final accountHash = LoginDao.getAccountHash() ?? 'guest';
    final loaded = await AISettingsDao.loadForAsync(
      accountHash,
    );
    if (epoch != _stateEpoch || revisionAtStart != _revision) return;
    _settings = loaded;
    _persistedSettings = loaded.clone();
    _accountHash = accountHash;
    _revision = 0;
    notifyListeners();
  }

  ///供登出/切换账号后重新加载当前账号设置
  Future<void> reload() => load();

  Future<void> update(
    AISettings next, {
    bool notify = true,
    String? expectedAccountHash,
  }) =>
      _commit(
        next,
        notify: notify,
        expectedAccountHash: expectedAccountHash,
      );

  /// 仅落盘、不通知。供页面 dispose 时 flush 未保存的防抖编辑——此时再
  /// notifyListeners 既无意义也可能在销毁期触发不必要的重建。
  Future<void> saveQuietly({String? expectedAccountHash}) => _commit(
        _settings,
        notify: false,
        expectedAccountHash: expectedAccountHash,
      );

  Future<void> _commit(
    AISettings next, {
    bool notify = true,
    String? expectedAccountHash,
  }) async {
    final currentAccountHash = LoginDao.getAccountHash() ?? 'guest';
    if (currentAccountHash != _accountHash ||
        (expectedAccountHash != null && expectedAccountHash != _accountHash)) {
      throw const AISettingsAccountChangedException();
    }
    final epoch = _stateEpoch;
    final revision = ++_revision;
    final commitSnapshot = reconcileAIHealthState(
      previous: _settings,
      next: next,
    );
    // 乐观基线必须先前移：紧接着发生的模型/开关操作要基于本次 Key/host
    // 变更构造快照，不能在安全存储 I/O 期间从旧 settings 克隆。
    _settings = commitSnapshot.clone();
    if (notify) notifyListeners();
    try {
      final persistedSnapshot =
          await AISettingsDao.saveFor(_accountHash, commitSnapshot);
      if (epoch == _stateEpoch) {
        _persistedSettings = persistedSnapshot.clone();
        // DAO 会再次以 secure/落盘快照为权威基线执行健康状态校正。只有当前
        // revision 才能采用返回值；若 DAO 清除了过期 success，则立即纠正 UI，
        // 避免内存 readiness 与实际持久化状态分叉。
        if (revision == _revision &&
            !_sameSettings(_settings, persistedSnapshot)) {
          _settings = persistedSnapshot.clone();
          notifyListeners();
        }
      }
    } catch (_) {
      // 若已有更新的乐观操作排在后面，让它携带本次变更继续重试；只有
      // 队尾失败才回到最后一次确认落盘的快照。
      if (epoch == _stateEpoch && revision == _revision) {
        _settings = _persistedSettings.clone();
        notifyListeners();
      }
      rethrow;
    }
  }

  /// 仅当测试开始时的连接配置仍是当前配置，才记录模型健康结果。
  ///
  /// 返回 false 表示测试期间配置发生变化，调用方应丢弃本次结果并提示重试。
  Future<bool> recordModelTestResult({
    required String providerId,
    required String modelId,
    required AIProviderHealthConfiguration expectedConfiguration,
    required bool success,
    String? error,
    bool vision = false,
    bool tool = false,
    bool reasoning = false,
    bool web = false,
    String? expectedAccountHash,
  }) async {
    final providers = _settings.providers.where((p) => p.id == providerId);
    if (providers.isEmpty) return false;
    final provider = providers.first;
    if (!expectedConfiguration.matches(provider)) return false;

    final nextProvider = provider.copy();
    final models = nextProvider.models.where((m) => m.id == modelId);
    if (models.isEmpty) return false;
    final model = models.first;
    model.markTestResult(success: success, error: error);
    if (success) {
      final heuristic = ModelCapabilities.heuristic(
        model.id,
        providerCode: nextProvider.providerCode,
      );
      model.applyCapabilityHints(
        vision: vision || heuristic.image,
        tool: tool || heuristic.tool,
        reasoning: reasoning || heuristic.reasoning,
        web: web,
      );
    }
    await updateProvider(
      nextProvider,
      expectedAccountHash: expectedAccountHash,
    );
    // 持久化期间可能又发生了配置编辑；此时本次结果虽曾短暂提交，也已被
    // 后续更新清除，调用方不能继续展示“测试成功”。
    final latest = _settings.providers.where((p) => p.id == providerId);
    return latest.isNotEmpty && expectedConfiguration.matches(latest.first);
  }

  static bool _sameSettings(AISettings first, AISettings second) =>
      jsonEncode(first.toJson()) == jsonEncode(second.toJson());

  // ───────── 服务商（多 provider）便捷操作 ─────────

  /// 设为当前激活服务商。
  Future<void> setActiveProvider(
    String id, {
    String? expectedAccountHash,
  }) async {
    final next = _settings.clone()..activeProviderId = id;
    await _commit(next, expectedAccountHash: expectedAccountHash);
  }

  /// 启用/禁用某服务商。禁用的若恰是当前激活项，则自动切到另一启用项。
  Future<void> toggleProvider(
    String id,
    bool enabled, {
    String? expectedAccountHash,
  }) async {
    final next = _settings.clone();
    final idx = next.providers.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    next.providers[idx].enabled = enabled;
    if (!enabled && next.activeProviderId == id) {
      final fallback = next.providers.where((p) => p.enabled).toList();
      if (fallback.isNotEmpty) next.activeProviderId = fallback.first.id;
    }
    await _commit(next, expectedAccountHash: expectedAccountHash);
  }

  /// 用编辑后的实例整体替换同 id 服务商（详情页保存用）。
  Future<void> updateProvider(
    AiProvider provider, {
    bool notify = true,
    String? expectedAccountHash,
  }) async {
    final next = _settings.clone();
    final idx = next.providers.indexWhere((p) => p.id == provider.id);
    if (idx < 0) {
      next.providers.add(provider.copy());
    } else {
      next.providers[idx] = provider.copy();
    }
    await _commit(
      next,
      notify: notify,
      expectedAccountHash: expectedAccountHash,
    );
  }

  /// 新增自定义服务商（默认启用并设为当前）。
  Future<void> addProvider(
    AiProvider provider, {
    String? expectedAccountHash,
  }) async {
    final next = _settings.clone()
      ..providers.add(provider.copy())
      ..activeProviderId = provider.id;
    await _commit(next, expectedAccountHash: expectedAccountHash);
  }

  /// 删除服务商（仅自定义可删）。若删的是当前激活项则回退。
  Future<void> removeProvider(
    String id, {
    String? expectedAccountHash,
  }) async {
    final next = _settings.clone();
    final target = next.providers.where((p) => p.id == id);
    if (target.isEmpty || target.first.isSystem) return;
    next.providers.removeWhere((p) => p.id == id);
    if (next.activeProviderId == id) {
      final fallback = next.providers.where((p) => p.enabled).toList();
      next.activeProviderId = fallback.isNotEmpty
          ? fallback.first.id
          : (next.providers.isNotEmpty ? next.providers.first.id : '');
    }
    await _commit(next, expectedAccountHash: expectedAccountHash);
  }

  ///登出时根据用户设置决定是否重置 AI 配置
  static void resetToDefaults() {
    if (_instance != null) {
      if (_instance!._settings.resetOnLogout) {
        _instance!._stateEpoch++;
        _instance!._revision = 0;
        _instance!._settings = AISettings.defaults();
        _instance!._persistedSettings = _instance!._settings.clone();
        _instance!.notifyListeners();
      }
    }
  }

  ///登录后重新加载实例设置（供 login hook 调用）
  static void reloadInstance() {
    if (_instance != null) {
      _instance!._stateEpoch++;
      _instance!._revision = 0;
      _instance!._settings = AISettingsDao.load();
      _instance!._persistedSettings = _instance!._settings.clone();
      _instance!._accountHash = LoginDao.getAccountHash() ?? 'guest';
      _instance!.notifyListeners();
    }
  }
}
