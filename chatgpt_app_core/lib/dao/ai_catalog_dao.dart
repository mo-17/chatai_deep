import 'dart:convert';

import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

class AiCatalogDao {
  static const _kCacheKey = 'ai_catalog_v1';

  /// 同步从缓存读取
  static Map<String, dynamic>? loadFromCache() {
    final raw = HiCache.getInstance().get(_kCacheKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 获取 AI 头像完整 URL（http://host/uploads/avatars/xxx），无头像时返回空串
  static String avatarUrl() {
    final catalog = loadFromCache();
    final path = catalog?['avatarUrl'] as String?;
    if (path == null || path.isEmpty) return '';
    return BackendConst.buildUri(path).toString();
  }

  /// 从后端异步拉取，写入缓存。失败/未登录/403 均静默返回 null
  static Future<Map<String, dynamic>?> fetchRemote() async {
    final token = LoginDao.getBoardingPass();
    // 游客 token 只用于本地进入 App，后端不会接受。直接使用缓存/硬编码清单，
    // 避免每次游客冷启动都制造一个必然 401 的网络请求。
    if (token == null || token == LoginDao.kGuestToken) return null;

    try {
      final uri = BackendConst.buildUri('/uapi/ai/catalog');
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };
      final response = await http.get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 403) return null; // catalog 关闭
      if (response.statusCode != 200) return null;

      const utf8decoder = Utf8Decoder();
      final bodyString = utf8decoder.convert(response.bodyBytes);
      final result = jsonDecode(bodyString) as Map<String, dynamic>;
      if (result['code'] == 0 && result['data'] != null) {
        final data = result['data'] as Map<String, dynamic>;
        await HiCache.getInstance()
            .setString(_kCacheKey, jsonEncode(data));
        return data;
      }
      return null;
    } catch (e) {
      AILogger.log('AiCatalogDao.fetchRemote error: $e');
      return null;
    }
  }
}
