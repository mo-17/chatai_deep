import 'dart:io';

import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/dao/apk_update_dao.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_download/hi_download.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 显式启用的匿名生产验收；普通测试不连接公网、不创建用户。
void main() {
  test('已发布版本能被旧 Android 包发现，当前/更高版本不降级，Store 隔离', () async {
    final uri = BackendConst.buildUri('uapi/checkUpdate');
    expect(uri.scheme, 'https');
    expect(uri.host, 'kushui.shop');
    expect(uri.port, 443);

    PackageInfo info(String build) => PackageInfo(
          appName: '艾普',
          packageName: 'com.example.chatgpt_flutter',
          version: build == '14' ? '1.0.4' : '1.0.5',
          buildNumber: build,
        );
    final old = await ApkUpdateDao.checkUpdate(
      packageInfo: info('14'),
      distribution: AppDistribution.direct,
      platform: 'android',
      headersBuilder: () => const {},
      installationId: 'production-live-check-0001',
    );
    expect(old.updateAvailable, isTrue);
    expect(old.versionName, '1.0.5');
    expect(old.versionCode, '15');
    expect(old.forceUpdate, isFalse);
    expect(old.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    final download = Uri.parse(old.downloadUrl);
    expect(download.scheme, 'https');
    expect(download.path, '/downloads/aipu-1.0.5-15-android.apk');

    for (final build in ['15', '16']) {
      final current = await ApkUpdateDao.checkUpdate(
        packageInfo: info(build),
        distribution: AppDistribution.direct,
        platform: 'android',
        headersBuilder: () => const {},
        installationId: 'production-live-check-0001',
      );
      expect(current.updateAvailable, isFalse);
      expect(current.downloadUrl, isEmpty);
    }
    final store = await ApkUpdateDao.checkUpdate(
      packageInfo: info('14'),
      distribution: AppDistribution.store,
      platform: 'android',
      headersBuilder: () => const {},
      installationId: 'production-live-check-0001',
    );
    expect(store.updateAvailable, isFalse);
    expect(store.downloadUrl, isEmpty);
  }, skip: Platform.environment['CHATAI_LIVE_UPDATE'] != '1');

  test('生产 APK 完整下载并通过 SHA-256 校验', () async {
    final directory =
        await Directory.systemTemp.createTemp('chatai-update-download-');
    try {
      final model = await ApkUpdateDao.checkUpdate(
        packageInfo: PackageInfo(
            appName: '艾普',
            packageName: 'com.example.chatgpt_flutter',
            version: '1.0.4',
            buildNumber: '14'),
        distribution: AppDistribution.direct,
        platform: 'android',
        headersBuilder: () => const {},
        installationId: 'production-live-check-0001',
      );
      expect(model.updateAvailable, isTrue);
      expect(model.sha256,
          'b9cccc5802099905394e5d04ea462de71117d6f9a48f5d2dea3460878bd992a3');
      var completed = false;
      final path = await HiDownLoad().download(
        downLoadUrl: model.downloadUrl,
        fileName: 'aipu-verification.apk',
        expectedSha256: model.sha256,
        directoryProvider: () async => directory,
        listener: (_, __, done) {
          completed = done;
        },
      );
      expect(completed, isTrue);
      expect(await File(path).length(), 304711031);
      expect(await File('$path.part').exists(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  },
      skip: Platform.environment['CHATAI_LIVE_APK_DOWNLOAD'] != '1',
      timeout: const Timeout(Duration(minutes: 5)));
}
