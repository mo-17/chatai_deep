import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';

class AISettingsDao {
  static const _kOldKey = 'ai_settings_v1';

  /// 指定账号 hash 的 HiCache key。游客固定为 'guest'。
  static String keyFor(String hash) => 'ai_settings_v1_$hash';

  static String _key() => keyFor(LoginDao.getAccountHash() ?? 'guest');

  /// 指定账号是否已存过 AI 设置（用于游客迁移判断目标账号是否「空」）。
  static bool hasSettings(String hash) =>
      HiCache.getInstance().get(keyFor(hash)) != null;

  /// 读取指定账号 hash 的 AI 设置（不依赖当前登录态）。无记录则返回默认。
  static AISettings loadFor(String hash) {
    final raw = HiCache.getInstance().get(keyFor(hash));
    if (raw == null) return AISettings.defaults();
    try {
      return AISettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AISettings.defaults();
    }
  }

  ///同步读取当前账号的 AI 设置（HiCache 内存读是同步的）
  static AISettings load() {
    final key = _key();
    var raw = HiCache.getInstance().get(key);
    // 兼容旧版数据：迁移一次
    if (raw == null) {
      final oldRaw = HiCache.getInstance().get(_kOldKey);
      if (oldRaw != null) {
        raw = oldRaw;
        // 异步迁移到新 key，不阻塞当前读取
        unawaited(HiCache.getInstance().setString(key, oldRaw));
        unawaited(HiCache.getInstance().remove(_kOldKey));
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

  ///清除当前账号的 AI 设置（异步落盘，不阻塞调用方）
  static void clear() {
    unawaited(HiCache.getInstance().remove(_key()));
  }
}
