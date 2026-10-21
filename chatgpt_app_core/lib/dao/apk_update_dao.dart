import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'update_abi.dart';
import 'dart:math';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ApkUpdateDao {
  static String _currentAbi() => currentUpdateAbi();
  static String _installationId() {
    final cache = HiCache.getInstance();
    final existing = cache.get('update_installation_id_v1')?.toString();
    if (existing != null && existing.length >= 16) return existing;
    final random = Random.secure();
    final value = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    cache.setString('update_installation_id_v1', value);
    return value;
  }

  static Future<ApkModel> checkUpdate({
    PackageInfo? packageInfo,
    http.Client? client,
    AppDistribution? distribution,
    String? platform,
    Map<String, String> Function()? headersBuilder,
    String? installationId,
    String? abi,
  }) async {
    final info = packageInfo ?? await PackageInfo.fromPlatform();
    final resolvedDistribution = distribution ?? DistributionConfig.current;
    final resolvedClient = client ?? http.Client();
    final ownClient = client == null;
    try {
      final uri = BackendConst.buildUri('uapi/checkUpdate', {
        // 保留历史 direct 渠道标识。新后台会继续按
        // platform-channel -> channel -> 321 -> all 的顺序回退；旧后台也
        // 仍能命中原有 321 记录。
        'cid': '321',
        'installationId': installationId ?? _installationId(),
        'version': info.version,
        'versionCode': info.buildNumber,
        'channel': resolvedDistribution.updateChannel,
        'platform': platform ?? Platform.operatingSystem,
        'abi': abi ?? _currentAbi(),
      });
      final response = await resolvedClient
          .get(uri, headers: (headersBuilder ?? hiHeaders)())
          .timeout(const Duration(seconds: 15));
      final bodyString = const Utf8Decoder().convert(response.bodyBytes);
      if (response.statusCode != 200) throw Exception(bodyString);

      final decoded = json.decode(bodyString);
      if (decoded is! Map || decoded['code'] != 0 || decoded['data'] is! Map) {
        throw Exception(bodyString);
      }
      return ApkModel.fromJson(
        Map<String, dynamic>.from(decoded['data'] as Map),
      );
    } finally {
      if (ownClient) resolvedClient.close();
    }
  }
}
