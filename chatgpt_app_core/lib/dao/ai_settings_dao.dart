import 'dart:convert';

import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';

class AISettingsDao {
  static const _kOldKey = 'ai_settings_v1';

  static String _key() {
    final hash = LoginDao.getAccountHash() ?? 'guest';
    return 'ai_settings_v1_$hash';
  }

  static AISettings load() {
    final key = _key();
    var raw = HiCache.getInstance().get(key);
    // 兼容旧版数据：迁移一次
    if (raw == null) {
      final oldRaw = HiCache.getInstance().get(_kOldKey);
      if (oldRaw != null) {
        raw = oldRaw;
        // 异步迁移到新 key，不阻塞当前读取
        HiCache.getInstance().setString(key, oldRaw);
        HiCache.getInstance().remove(_kOldKey);
      }
    }
    if (raw == null) return AISettings.defaults();
    try {
      return AISettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AISettings.defaults();
    }
  }

  static Future<void> save(AISettings s) async {
    await HiCache.getInstance().setString(_key(), jsonEncode(s.toJson()));
  }

  ///清除当前账号的 AI 设置
  static void clear() {
    HiCache.getInstance().remove(_key());
  }
}
