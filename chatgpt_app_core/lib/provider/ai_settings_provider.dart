import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
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
