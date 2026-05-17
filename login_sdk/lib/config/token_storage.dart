import 'dart:convert';

import 'package:flutter_hi_cache/flutter_hi_cache.dart';

/// 登录态持久化适配器。默认实现 [HiCacheTokenStorage] 走仓库现有的
/// flutter_hi_cache；想换 shared_preferences / flutter_secure_storage
/// 只要实现这个接口并在 [LoginSdkConfig.install] 时注入。
///
/// 注意：[readTokenSync] / [readProfileSync] 是同步访问，给 [LoginDao.getBoardingPass]
/// 等历史同步 API 兜底用。新增功能尽量走异步 [readToken] / [readProfile]。
abstract class TokenStorage {
  /// 异步读 token（推荐路径）
  Future<String?> readToken();

  /// 异步读完整 profile
  Future<Map<String, dynamic>?> readProfile();

  /// 同步读 token —— 给历史同步 API 兜底；存储后端不支持同步时返回 null。
  String? readTokenSync();

  /// 同步读 profile —— 同上。
  Map<String, dynamic>? readProfileSync();

  /// 写入 token + profile。profile 至少包含 userName，用于派生 accountHash。
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras,
  });

  /// 清空
  Future<void> clear();
}

/// 用仓库现有的 flutter_hi_cache 做持久化。kUserInfo 与原 LoginDao 保持一致，
/// 便于无缝替换（旧账号无须重新登录）。
class HiCacheTokenStorage implements TokenStorage {
  static const _kUserInfo = 'user_info';

  Map<String, dynamic>? _decode() {
    final s = HiCache.getInstance().get(_kUserInfo);
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  String? readTokenSync() => _decode()?['boardingPass'] as String?;

  @override
  Map<String, dynamic>? readProfileSync() => _decode();

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    final map = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode,
      ...extras,
    };
    HiCache.getInstance().setString(_kUserInfo, jsonEncode(map));
  }

  @override
  Future<void> clear() async => HiCache.getInstance().remove(_kUserInfo);
}
