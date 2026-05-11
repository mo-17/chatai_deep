import 'dart:convert';

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/auth_dao.dart';

/// 带 HiCache 持久化缓存的 PublicConfig 加载器
class PublicConfigLoader {
  static const _key = 'auth_public_config';
  static const _ttl = Duration(minutes: 30);

  static Future<PublicConfig> load() async {
    final cache = HiCache.getInstance();
    // 先从 HiCache 读取（冷启动加速）
    final cached = cache.get(_key);
    if (cached != null) {
      try {
        final map = jsonDecode(cached) as Map<String, dynamic>;
        final ts = map['_ts'] as int? ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - ts < _ttl.inMilliseconds) {
          return PublicConfig.fromJson(map);
        }
      } catch (_) {}
    }

    // 网络拉取
    final dao = PublicConfigDao(AuthDaoBridge.client);
    try {
      final config = await dao.fetch();
      // 写入 HiCache（带时间戳）
      final toCache = <String, dynamic>{
        ..._configToJson(config),
        '_ts': DateTime.now().millisecondsSinceEpoch,
      };
      cache.setString(_key, jsonEncode(toCache));
      return config;
    } catch (_) {
      // 回落：上次缓存（即使过期）或默认值
      if (cached != null) {
        try {
          return PublicConfig.fromJson(jsonDecode(cached) as Map<String, dynamic>);
        } catch (_) {}
      }
      return PublicConfig.defaults();
    }
  }

  static Map<String, dynamic> _configToJson(PublicConfig c) => {
    'huaweiGetAuthCodeEnabled': c.huaweiGetAuthCodeEnabled,
    'huaweiQuickLoginEnabled': c.huaweiQuickLoginEnabled,
    'huaweiPrimaryFlow': c.huaweiPrimaryFlow,
    'appleSignInEnabled': c.appleSignInEnabled,
    'supportedCountryCodes': c.countryCodes,
  };
}
