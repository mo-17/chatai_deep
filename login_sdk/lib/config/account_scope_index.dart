import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

import '../dao/backend_host.dart';

/// 记住已使用的数据库分区，重登时不再重新计算并覆盖历史 accountHash。
/// 仅保存分区引用；不保存用户名、token 或密码，也不搬动账号数据。
class AccountScopeIndex {
  static const originField = 'accountScopeOrigin';

  static String get origin => BackendConfig.buildUri('/').origin;

  static String _key(String userName) =>
      'login_account_scope_v1_${sha256.convert(
        utf8.encode(jsonEncode([origin, userName])),
      )}';

  static bool _valid(Object? value) =>
      value is int || value is String && value.isNotEmpty;

  static Object resolve(String userName, Map<String, dynamic> extras) {
    final explicit = extras['accountHash'];
    if (_valid(explicit)) return explicit!;
    final raw = HiCache.getInstance().prefs?.getString(_key(userName));
    if (raw == null) return userName.hashCode;
    try {
      final value = jsonDecode(raw);
      if (_valid(value)) return value;
    } catch (_) {}
    throw StateError('本地账号分区索引损坏，请保留数据并重试');
  }

  static Future<void> remember(Map<String, dynamic>? profile) async {
    if (profile == null || profile['guest'] == true) return;
    final userName = profile['userName'];
    final scope = profile['accountHash'];
    if (userName is! String || userName.isEmpty || !_valid(scope)) return;
    final savedOrigin = profile[originField];
    if (savedOrigin != null && savedOrigin != origin) return;
    final prefs = HiCache.getInstance().prefs;
    final key = _key(userName);
    final encoded = jsonEncode(scope);
    if (prefs?.getString(key) == encoded) return;
    if (prefs == null || !await prefs.setString(key, encoded)) {
      throw StateError('本地账号分区索引保存失败');
    }
  }
}
