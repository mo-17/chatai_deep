library login_sdk;

import 'package:flutter/cupertino.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

import 'config/login_sdk_config.dart';
import 'config/token_storage.dart';

export 'config/login_sdk_config.dart'
    show
        LoginSdkConfig,
        LoginRoutes,
        LoginResult,
        LoginResponseAdapter,
        ImoocResponseAdapter;
export 'config/secure_key_value_store.dart' show SecureKeyValueStore;
export 'config/token_storage.dart'
    show
        TokenStorage,
        InitializableTokenStorage,
        SecureStorageUnavailableException,
        HiCacheTokenStorage,
        MigratingTokenStorage;

class LoginConfig {
  static LoginConfig? _instance;
  Widget? homePage;

  static LoginConfig instance() {
    _instance ??= LoginConfig._();
    return _instance!;
  }

  /// 初始化登录所需的配置。
  ///
  /// - [homePage]：登录后跳转的首页。
  /// - [sdk]：可选 — 注入通用化配置（baseUrl / 路由 / 响应适配 / 存储 / 登出导航）。
  ///   不传则回退到 imooc 默认行为（与改造前一致）。
  Future<void> init({
    required Widget homePage,
    LoginSdkConfig? sdk,
    TokenStorage? tokenStorage,
  }) async {
    this.homePage = homePage;
    await HiCache.preInit();
    if (sdk != null) {
      LoginSdkConfig.install(sdk);
    }
    if (tokenStorage != null) {
      LoginSdkConfig.install(
        LoginSdkConfig.instance.copyWith(storage: tokenStorage),
      );
    }
    final storage = LoginSdkConfig.instance.storage;
    if (storage is InitializableTokenStorage) {
      await (storage as InitializableTokenStorage).initialize();
    }
  }

  LoginConfig._();
}
