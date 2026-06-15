import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter/material.dart';

class AISettingsProvider extends ChangeNotifier {
  static AISettingsProvider? _instance;
  static AISettingsProvider? get instance => _instance;

  AISettings _settings = AISettingsDao.load();
  AISettings get settings => _settings;

  AISettingsProvider() {
    _instance = this;
  }

  ///重新加载当前账号的 AI 设置（登录后、切换账号后调用）
  Future<void> load() async {
    _settings = AISettingsDao.load();
    notifyListeners();
  }

  ///供登出/切换账号后重新加载当前账号设置
  Future<void> reload() => load();

  Future<void> update(AISettings next) async {
    _settings = next;
    await AISettingsDao.save(next);
    notifyListeners();
  }

  /// 落盘当前 _settings 并通知（服务商增删改的统一出口）。
  Future<void> _persist() async {
    await AISettingsDao.save(_settings);
    notifyListeners();
  }

  /// 仅落盘、不通知。供页面 dispose 时 flush 未保存的防抖编辑——此时再
  /// notifyListeners 既无意义也可能在销毁期触发不必要的重建。
  Future<void> saveQuietly() => AISettingsDao.save(_settings);

  // ───────── 服务商（多 provider）便捷操作 ─────────

  /// 设为当前激活服务商。
  Future<void> setActiveProvider(String id) async {
    _settings.activeProviderId = id;
    await _persist();
  }

  /// 启用/禁用某服务商。禁用的若恰是当前激活项，则自动切到另一启用项。
  Future<void> toggleProvider(String id, bool enabled) async {
    final idx = _settings.providers.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    _settings.providers[idx].enabled = enabled;
    if (!enabled && _settings.activeProviderId == id) {
      final fallback = _settings.providers.where((p) => p.enabled).toList();
      if (fallback.isNotEmpty) _settings.activeProviderId = fallback.first.id;
    }
    await _persist();
  }

  /// 用编辑后的实例整体替换同 id 服务商（详情页保存用）。
  Future<void> updateProvider(AiProvider provider) async {
    final idx = _settings.providers.indexWhere((p) => p.id == provider.id);
    if (idx < 0) {
      _settings.providers.add(provider);
    } else {
      _settings.providers[idx] = provider;
    }
    await _persist();
  }

  /// 新增自定义服务商（默认启用并设为当前）。
  Future<void> addProvider(AiProvider provider) async {
    _settings.providers.add(provider);
    _settings.activeProviderId = provider.id;
    await _persist();
  }

  /// 删除服务商（仅自定义可删）。若删的是当前激活项则回退。
  Future<void> removeProvider(String id) async {
    final target = _settings.providers.where((p) => p.id == id);
    if (target.isEmpty || target.first.isSystem) return;
    _settings.providers.removeWhere((p) => p.id == id);
    if (_settings.activeProviderId == id) {
      final fallback = _settings.providers.where((p) => p.enabled).toList();
      _settings.activeProviderId = fallback.isNotEmpty
          ? fallback.first.id
          : (_settings.providers.isNotEmpty ? _settings.providers.first.id : '');
    }
    await _persist();
  }

  ///登出时根据用户设置决定是否重置 AI 配置
  static void resetToDefaults() {
    if (_instance != null) {
      if (_instance!._settings.resetOnLogout) {
        _instance!._settings = AISettings.defaults();
        _instance!.notifyListeners();
      }
    }
  }

  ///登录后重新加载实例设置（供 login hook 调用）
  static void reloadInstance() {
    if (_instance != null) {
      _instance!._settings = AISettingsDao.load();
      _instance!.notifyListeners();
    }
  }
}
