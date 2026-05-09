import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// 后端 host / scheme 配置。
/// 切换生产环境（示例）：
///   flutter run --dart-define=BACKEND_HOST=api.example.com \
///               --dart-define=BACKEND_HTTPS=true
/// 真机连本机后端：
///   flutter run --dart-define=BACKEND_HOST=192.168.x.x:3000
/// 也可在 main() 里直接赋值 BackendConfig.host / useHttps。
class BackendConfig {
  BackendConfig._();

  static const String _port = '3000';
  static const String _hostOverride =
      String.fromEnvironment('BACKEND_HOST', defaultValue: '');
  static const bool _httpsOverride =
      bool.fromEnvironment('BACKEND_HTTPS', defaultValue: false);

  static String host =
      _hostOverride.isNotEmpty ? _hostOverride : _autoDetect();

  /// 是否使用 https。本地开发默认 false；生产环境置 true。
  static bool useHttps = _httpsOverride;

  /// 统一构造请求 URI。所有 DAO 都该走这个方法，避免散落 Uri.http/https 造成线上无法切换。
  static Uri buildUri(String path, [Map<String, dynamic>? queryParameters]) {
    return useHttps
        ? Uri.https(host, path, queryParameters)
        : Uri.http(host, path, queryParameters);
  }

  static String _autoDetect() {
    if (kIsWeb) return 'localhost:$_port';
    // Android 模拟器走 NAT 网关 10.0.2.2 映射到宿主机；
    // Android 真机请用 --dart-define 或 setter 覆盖为局域网 IP。
    if (Platform.isAndroid) return '10.0.2.2:$_port';
    // iOS Simulator / macOS / Windows / Linux 共享宿主机网络栈，localhost 即可。
    return 'localhost:$_port';
  }
}
