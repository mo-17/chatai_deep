import 'package:flutter/foundation.dart';

enum AppDistribution {
  development,
  direct,
  store;

  String get updateChannel => switch (this) {
        AppDistribution.development => 'direct',
        AppDistribution.direct => 'direct',
        AppDistribution.store => 'store',
      };
}

class DistributionConfig {
  DistributionConfig._();

  static const _raw = String.fromEnvironment('APP_DISTRIBUTION');

  static AppDistribution get current =>
      resolve(raw: _raw, releaseMode: kReleaseMode);

  static AppDistribution resolve({
    required String raw,
    required bool releaseMode,
  }) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) {
      return releaseMode
          ? AppDistribution.direct
          : AppDistribution.development;
    }
    switch (normalized) {
      case 'direct':
        return AppDistribution.direct;
      case 'store':
        return AppDistribution.store;
      case 'development':
      case 'dev':
        if (!releaseMode) return AppDistribution.development;
        throw StateError('Release 构建不能使用 development distribution');
      default:
        if (!releaseMode) return AppDistribution.development;
        throw StateError('未知的 APP_DISTRIBUTION: $raw');
    }
  }

  static void validateStore({
    required String backendHost,
    required bool useHttps,
    required String applicationId,
  }) {
    final host = backendHost.trim().toLowerCase();
    final appId = applicationId.trim().toLowerCase();
    final localHost = host == 'localhost' ||
        host.startsWith('localhost:') ||
        host == '127.0.0.1' ||
        host.startsWith('127.0.0.1:') ||
        host == '10.0.2.2' ||
        host.startsWith('10.0.2.2:') ||
        host == '[::1]' ||
        host.startsWith('[::1]:');
    if (!useHttps || host.isEmpty || host.contains('/') || localHost) {
      throw StateError('Store 构建必须使用公开的 HTTPS backend');
    }
    if (appId.isEmpty || appId.startsWith('com.example.')) {
      throw StateError('Store 构建必须配置正式 applicationId');
    }
  }
}
