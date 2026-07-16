import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';
import 'package:chatgpt_app_core/update/apk_update_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = ApkUpdatePolicy();

  test('no update never opens a download or store action', () {
    final model = ApkModel(updateAvailable: false);

    expect(
      policy.decide(model, AppDistribution.direct),
      UpdateAction.none,
    );
    expect(
      policy.decide(model, AppDistribution.store),
      UpdateAction.none,
    );
  });

  test('direct and development download a verified APK', () {
    final model = ApkModel(
      updateAvailable: true,
      downloadUrl: 'https://example.com/app.apk',
    );

    expect(
      policy.decide(model, AppDistribution.direct),
      UpdateAction.downloadApk,
    );
    expect(
      policy.decide(model, AppDistribution.development),
      UpdateAction.downloadApk,
    );
    expect(
      policy.urlFor(model, AppDistribution.direct),
      'https://example.com/app.apk',
    );
  });

  test('store opens the store URL and never chooses APK download', () {
    final model = ApkModel(
      updateAvailable: true,
      downloadUrl: 'https://example.com/app.apk',
      storeUrl: 'https://store.example.com/app',
    );

    expect(
      policy.decide(model, AppDistribution.store),
      UpdateAction.openStore,
    );
    expect(
      policy.urlFor(model, AppDistribution.store),
      'https://store.example.com/app',
    );
  });

  test('store never treats a legacy generic APK URL as a store URL', () {
    final model = ApkModel(
      updateAvailable: true,
      url: 'https://example.com/app.apk',
    );

    expect(
      () => policy.decide(model, AppDistribution.store),
      throwsFormatException,
    );
  });

  test('store requires an HTTPS store URL', () {
    final model = ApkModel(
      updateAvailable: true,
      storeUrl: 'http://store.example.com/app',
    );

    expect(
      () => policy.decide(model, AppDistribution.store),
      throwsFormatException,
    );
  });

  test('direct keeps legacy HTTP APK URLs compatible', () {
    final model = ApkModel(
      updateAvailable: true,
      downloadUrl: 'http://downloads.example.com/app.apk',
    );

    expect(
      policy.decide(model, AppDistribution.direct),
      UpdateAction.downloadApk,
    );
  });

  test('an available direct update without a URL fails closed', () {
    final model = ApkModel(updateAvailable: true);

    expect(
      () => policy.decide(model, AppDistribution.direct),
      throwsFormatException,
    );
  });
}
