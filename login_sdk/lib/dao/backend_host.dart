import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:login_sdk/config/login_sdk_config.dart';

/// 后端 host / scheme 配置。
///
/// **取值优先级（高 → 低）**：
///   1. 显式 setter `BackendConfig.host = ...` / `useHttps = ...`
///   2. 编译期 `--dart-define=BACKEND_HOST=...` / `BACKEND_HTTPS=true`
///   3. [LoginSdkConfig.install] 注入的 `baseUrl` / `useHttps`
///   4. 自动检测（Android emulator → 10.0.2.2，其余 → localhost）
///
/// 切换生产（示例）：
///   `flutter run --dart-define=BACKEND_HOST=api.example.com --dart-define=BACKEND_HTTPS=true`
/// 真机连本机后端：
///   `flutter run --dart-define=BACKEND_HOST=192.168.x.x:3000`
class BackendConfig {
  BackendConfig._();

  /// 地址改变必须通知应用级运行；没有设置页订阅者也能撤销旧客户端。
  static final changes = ValueNotifier<int>(0);

  static const String _hostOverride =
      String.fromEnvironment('BACKEND_HOST', defaultValue: '');
  static const bool _httpsOverride =
      bool.fromEnvironment('BACKEND_HTTPS', defaultValue: false);

  static String? _hostExplicit;
  static bool? _useHttpsExplicit;

  /// 当前生效的 host（含端口）。读取按 §1-4 优先级。
  static String get host {
    if (_hostExplicit != null) return _hostExplicit!;
    if (_hostOverride.isNotEmpty) return _hostOverride;
    if (LoginSdkConfig.isInstalled) return LoginSdkConfig.instance.baseUrl;
    return autoDetect();
  }

  static set host(String value) {
    final changed = host != value;
    _hostExplicit = value;
    if (changed) changes.value++;
  }

  /// 是否使用 https。
  static bool get useHttps {
    if (_useHttpsExplicit != null) return _useHttpsExplicit!;
    if (_httpsOverride) return true;
    if (LoginSdkConfig.isInstalled) return LoginSdkConfig.instance.useHttps;
    return false;
  }

  static set useHttps(bool value) {
    final changed = useHttps != value;
    _useHttpsExplicit = value;
    if (changed) changes.value++;
  }

  /// 统一构造请求 URI。所有 DAO 都该走这个方法，避免散落 `Uri.http/https`
  /// 造成线上无法切换。
  static Uri buildUri(String path, [Map<String, dynamic>? queryParameters]) {
    return useHttps
        ? Uri.https(host, path, queryParameters)
        : Uri.http(host, path, queryParameters);
  }

  /// 平台敏感的自动检测；可作 `LoginSdkConfig(baseUrl: BackendConfig.autoDetect())` 使用。
  ///
  /// - Web / iOS Simulator / macOS / Windows / Linux → `localhost:<port>`
  /// - Android emulator → `10.0.2.2:<port>`（Android 真机请显式覆盖为局域网 IP）
  static String autoDetect({int port = 3000}) {
    if (kIsWeb) return 'localhost:$port';
    if (Platform.isAndroid) return '10.0.2.2:$port';
    return 'localhost:$port';
  }
}
