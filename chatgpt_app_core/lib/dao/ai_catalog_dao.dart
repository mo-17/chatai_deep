import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 响应只能属于发起时账号、登录代次、凭据和后端；缓存只供 UI 展示。
class AiCatalogIdentity {
  static int _epoch = 0;
  static bool _registered = false;
  static final changes = ValueNotifier<int>(0);
  final String? account;
  final String? _token;
  final int epoch;
  final Uri endpoint;
  AiCatalogIdentity._(this.account, this._token, this.epoch, this.endpoint);
  static AiCatalogIdentity capture() {
    if (!_registered) {
      _registered = true;
      Future<void> changed() async {
        _epoch++;
        changes.value++;
      }

      LoginDao.addLoginReadyHook(changed);
      LoginDao.addLogoutReadyHook(changed);
    }
    return AiCatalogIdentity._(
        LoginDao.getAccountHash(),
        LoginDao.getBoardingPass(),
        _epoch,
        BackendConst.buildUri('/uapi/ai/catalog'));
  }

  bool get current =>
      account == LoginDao.getAccountHash() &&
      _token == LoginDao.getBoardingPass() &&
      epoch == _epoch &&
      endpoint == BackendConst.buildUri('/uapi/ai/catalog');
  bool get authenticated =>
      account != null && _token != null && _token != LoginDao.kGuestToken;
  bool sameAs(AiCatalogIdentity other) =>
      account == other.account &&
      _token == other._token &&
      epoch == other.epoch &&
      endpoint == other.endpoint;
  String get cacheKey =>
      'ai_catalog_ui_${sha256.convert(utf8.encode('${account ?? "guest"}:$endpoint'))}';
  static void resetForTest() {
    _registered = false;
    _epoch++;
  }
}

enum CatalogFetchStatus {
  success,
  notAuthenticated,
  forbidden,
  timeout,
  failed,
  invalid,
  stale,
}

class CatalogFetchResult {
  final CatalogFetchStatus status;
  final Map<String, dynamic>? data;
  const CatalogFetchResult(this.status, [this.data]);
}

class AiCatalogDao {
  static const _kCacheKey = 'ai_catalog_v1';

  /// 同步从缓存读取
  static Map<String, dynamic>? loadFromCache({bool scopedOnly = false}) {
    final raw =
        HiCache.getInstance().get(AiCatalogIdentity.capture().cacheKey) ??
            (scopedOnly ? null : HiCache.getInstance().get(_kCacheKey));
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

  /// 保留原兼容接口；页面使用有限状态反馈，不透传服务端或网络错误原文。
  static Future<Map<String, dynamic>?> fetchRemote(
          {AiCatalogIdentity? identity, bool Function()? stillCurrent}) async =>
      (await fetchRemoteResult(identity: identity, stillCurrent: stillCurrent))
          .data;

  static Future<CatalogFetchResult> fetchRemoteResult(
      {AiCatalogIdentity? identity, bool Function()? stillCurrent}) async {
    final scope = identity ?? AiCatalogIdentity.capture();
    final token = scope._token;
    bool valid() => scope.current && (stillCurrent?.call() ?? true);
    // 游客 token 只用于本地进入 App，后端不会接受。直接使用缓存/硬编码清单，
    // 避免每次游客冷启动都制造一个必然 401 的网络请求。
    if (!valid()) return const CatalogFetchResult(CatalogFetchStatus.stale);
    if (!scope.authenticated) {
      return const CatalogFetchResult(CatalogFetchStatus.notAuthenticated);
    }

    final client = http.Client();
    try {
      final uri = scope.endpoint;
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };
      // 目录只能由原后端提供；跳转响应按失败处理，不能认作原身份快照。
      final request = http.Request('GET', uri)
        ..headers.addAll(headers)
        ..followRedirects = false;
      final response = await (() async {
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      })()
          .timeout(const Duration(seconds: 15));

      if (!valid()) return const CatalogFetchResult(CatalogFetchStatus.stale);
      if (response.statusCode == 401) {
        return const CatalogFetchResult(CatalogFetchStatus.notAuthenticated);
      }
      if (response.statusCode == 403) {
        return const CatalogFetchResult(CatalogFetchStatus.forbidden);
      }
      if (response.statusCode != 200) {
        return const CatalogFetchResult(CatalogFetchStatus.failed);
      }

      const utf8decoder = Utf8Decoder();
      final bodyString = utf8decoder.convert(response.bodyBytes);
      final result = jsonDecode(bodyString) as Map<String, dynamic>;
      if (result['code'] == 0 && result['data'] != null) {
        final data = result['data'] as Map<String, dynamic>;
        final models = data['models'];
        if (models is! List ||
            models.any((m) =>
                m is! Map ||
                m['modelId'] is! String ||
                (m['modelId'] as String).isEmpty ||
                ['displayName', 'description', 'providerCode']
                    .any((key) => m[key] != null && m[key] is! String) ||
                [
                  'supportsVision',
                  'supportsTool',
                  'supportsReasoning',
                  'supportsPdf'
                ].any((key) => m[key] != null && m[key] is! bool))) {
          return const CatalogFetchResult(CatalogFetchStatus.invalid);
        }
        await HiCache.getInstance().setString(scope.cacheKey, jsonEncode(data));
        return valid()
            ? CatalogFetchResult(CatalogFetchStatus.success, data)
            : const CatalogFetchResult(CatalogFetchStatus.stale);
      }
      return const CatalogFetchResult(CatalogFetchStatus.invalid);
    } on TimeoutException {
      AILogger.log('AiCatalogDao: catalog request timed out');
      return const CatalogFetchResult(CatalogFetchStatus.timeout);
    } on FormatException {
      return const CatalogFetchResult(CatalogFetchStatus.invalid);
    } catch (_) {
      AILogger.log('AiCatalogDao: catalog request failed');
      return const CatalogFetchResult(CatalogFetchStatus.failed);
    } finally {
      client.close();
    }
  }
}
