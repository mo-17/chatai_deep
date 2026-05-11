import '../util/public_config_cache.dart';
import 'auth_api_client.dart';

/// 公开配置 DAO —— 从后端拉取 /uapi/auth/public-config
class PublicConfigDao {
  final AuthApiClient client;
  PublicConfig? _cached;
  DateTime? _cachedAt;
  static const _cacheTtl = Duration(minutes: 5);

  PublicConfigDao(this.client);

  /// 获取配置（带内存缓存），网络异常时回落上次缓存或默认值
  Future<PublicConfig> fetch() async {
    // 内存缓存未过期直接返回
    if (_cached != null && _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cached!;
    }
    try {
      final resp = await client.get('/uapi/auth/public-config');
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      _cached = PublicConfig.fromJson(data);
      _cachedAt = DateTime.now();
      return _cached!;
    } catch (_) {
      return _cached ?? PublicConfig.defaults();
    }
  }

  /// 清除缓存（登录/登出后调用）
  void clearCache() {
    _cached = null;
    _cachedAt = null;
  }
}
