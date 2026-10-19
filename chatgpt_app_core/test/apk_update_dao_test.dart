import 'dart:convert';

import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/dao/apk_update_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  PackageInfo packageInfo() => PackageInfo(
        appName: '艾普',
        packageName: 'com.example.chatgpt_flutter',
        version: '1.0.4',
        buildNumber: '8',
      );

  test('sends semantic version, numeric build, channel and platform', () async {
    late Uri requestUri;
    final client = MockClient((request) async {
      requestUri = request.url;
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'id': '9',
            'cid': 'android-direct',
            'versionName': '1.0.5',
            'versionCode': '9',
            'url': 'https://example.com/app.apk',
            'description': 'Release notes',
            'forceUpdate': true,
            'updateAvailable': true,
            'downloadUrl': 'https://example.com/app.apk',
            'storeUrl': '',
            'sha256': 'abc123',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final model = await ApkUpdateDao.checkUpdate(
      packageInfo: packageInfo(),
      installationId: 'unit-installation-12345',
      client: client,
      distribution: AppDistribution.direct,
      platform: 'android',
      headersBuilder: () => const {},
    );

    // 历史 direct 客户端一直使用 cid=321；继续携带它，避免升级后的客户端
    // 在仍只有 321 版本记录的旧后台上失去更新能力。
    expect(requestUri.queryParameters, containsPair('cid', '321'));
    expect(requestUri.queryParameters, containsPair('version', '1.0.4'));
    expect(requestUri.queryParameters, containsPair('versionCode', '8'));
    expect(requestUri.queryParameters, containsPair('channel', 'direct'));
    expect(requestUri.queryParameters, containsPair('platform', 'android'));
    expect(model.updateAvailable, isTrue);
    expect(model.forceUpdate, isTrue);
    expect(model.downloadUrl, 'https://example.com/app.apk');
    expect(model.url, model.downloadUrl);
    expect(model.sha256, 'abc123');
  });

  test('derives availability from a legacy non-empty url', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'id': '9',
              'cid': 'all',
              'versionName': '1.0.5',
              'versionCode': '9',
              'url': 'https://example.com/legacy.apk',
              'description': 'Legacy response',
            },
          }),
          200,
        ));

    final model = await ApkUpdateDao.checkUpdate(
      packageInfo: packageInfo(),
      installationId: 'unit-installation-12345',
      client: client,
      distribution: AppDistribution.direct,
      platform: 'android',
      headersBuilder: () => const {},
    );

    expect(model.updateAvailable, isTrue);
    expect(model.downloadUrl, 'https://example.com/legacy.apk');
    expect(model.forceUpdate, isFalse);
  });

  test('derives no update from a legacy empty url', () async {
    final client = MockClient((_) async => http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'id': '8',
              'cid': 'all',
              'versionName': '1.0.4',
              'versionCode': '8',
              'url': '',
              'description': '当前已是最新版本',
            },
          })),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ));

    final model = await ApkUpdateDao.checkUpdate(
      packageInfo: packageInfo(),
      installationId: 'unit-installation-12345',
      client: client,
      distribution: AppDistribution.direct,
      platform: 'android',
      headersBuilder: () => const {},
    );

    expect(model.updateAvailable, isFalse);
    expect(model.downloadUrl, isEmpty);
  });
}
