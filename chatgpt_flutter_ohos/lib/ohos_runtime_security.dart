import 'dart:io';

import 'package:chatgpt_app_core/util/public_network_address_policy.dart';
import 'package:login_sdk/dao/backend_host.dart';

typedef OhosHostResolver = Future<List<InternetAddress>> Function(String host);

/// HarmonyOS 壳的发布安全门禁：生产构建只允许显式配置的公网 HTTPS 后端。
class OhosRuntimeSecurity {
  const OhosRuntimeSecurity._();

  static Future<void> configureBackend({
    required String host,
    required bool useHttps,
    required bool releaseMode,
    OhosHostResolver resolver = InternetAddress.lookup,
  }) async {
    final normalized = host.trim();
    await validateBackend(
      host: normalized,
      useHttps: useHttps,
      releaseMode: releaseMode,
      resolver: resolver,
    );
    BackendConfig.host = normalized;
    BackendConfig.useHttps = useHttps;
  }

  static Future<void> validateBackend({
    required String host,
    required bool useHttps,
    required bool releaseMode,
    OhosHostResolver resolver = InternetAddress.lookup,
  }) async {
    final normalized = host.trim();
    if (normalized.isEmpty) {
      throw StateError(
        'HarmonyOS 后端未配置：请提供 --dart-define=BACKEND_HOST=...',
      );
    }
    if (normalized.contains('://')) {
      throw StateError('BACKEND_HOST 只能包含主机名与端口，不能包含 scheme');
    }
    final uri = Uri.tryParse('https://$normalized');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isNotEmpty) {
      throw StateError('BACKEND_HOST 格式无效');
    }
    if (!releaseMode) return;
    if (!useHttps) {
      throw StateError('HarmonyOS release 构建必须启用 BACKEND_HTTPS=true');
    }
    final hostname = PublicNetworkAddressPolicy.normalizeHostname(uri.host);
    if (PublicNetworkAddressPolicy.isLocalHostname(hostname)) {
      throw StateError('HarmonyOS release 构建不能连接本机或私有开发地址');
    }
    final literal = InternetAddress.tryParse(hostname);
    final addresses = literal == null
        ? await resolver(hostname).timeout(const Duration(seconds: 5))
        : [literal];
    if (addresses.isEmpty ||
        addresses.any(
          (address) => !PublicNetworkAddressPolicy.isPublicAddress(address),
        )) {
      throw StateError('HarmonyOS release 构建不能连接本机或私有开发地址');
    }
  }
}
