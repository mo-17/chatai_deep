import 'package:chatgpt_flutter/dao/ai_settings_dao.dart';
import 'package:chatgpt_flutter/model/ai_settings.dart';
import 'package:flutter/material.dart';

class AISettingsProvider extends ChangeNotifier {
  AISettings _settings = AISettings.defaults();
  AISettings get settings => _settings;

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
}
