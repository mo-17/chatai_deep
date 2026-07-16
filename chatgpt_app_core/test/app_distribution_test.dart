import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DistributionConfig.resolve', () {
    test('release defaults to the legacy direct channel', () {
      expect(
        DistributionConfig.resolve(raw: '', releaseMode: true),
        AppDistribution.direct,
      );
    });

    test('debug defaults to development', () {
      expect(
        DistributionConfig.resolve(raw: '', releaseMode: false),
        AppDistribution.development,
      );
    });

    test('explicit store is accepted for release', () {
      expect(
        DistributionConfig.resolve(raw: 'store', releaseMode: true),
        AppDistribution.store,
      );
    });

    test('unknown release distribution fails closed', () {
      expect(
        () => DistributionConfig.resolve(raw: 'unknown', releaseMode: true),
        throwsStateError,
      );
    });
  });

  group('DistributionConfig.validateStore', () {
    test('rejects cleartext and placeholder identity', () {
      expect(
        () => DistributionConfig.validateStore(
          backendHost: 'localhost:3000',
          useHttps: false,
          applicationId: 'com.example.app',
        ),
        throwsStateError,
      );
    });

    test('accepts an https production identity', () {
      expect(
        () => DistributionConfig.validateStore(
          backendHost: 'api.example.com',
          useHttps: true,
          applicationId: 'com.acme.chat',
        ),
        returnsNormally,
      );
    });

    test('rejects loopback IPv6 and host values containing a scheme', () {
      expect(
        () => DistributionConfig.validateStore(
          backendHost: '[::1]:3000',
          useHttps: true,
          applicationId: 'com.acme.chat',
        ),
        throwsStateError,
      );
      expect(
        () => DistributionConfig.validateStore(
          backendHost: 'https://api.example.com',
          useHttps: true,
          applicationId: 'com.acme.chat',
        ),
        throwsStateError,
      );
    });
  });
}
