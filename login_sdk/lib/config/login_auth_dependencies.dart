import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/foundation.dart';

/// 登录页所需的可选认证实现，由宿主按平台能力注入。
///
/// 未提供的依赖会由页面逐项回退到 SDK 配置或现有默认实现。
@immutable
class LoginAuthDependencies {
  final AuthDao? authDao;
  final IAppleSignInService? appleSignInService;
  final IHuaweiLoginService? huaweiLoginService;

  const LoginAuthDependencies({
    this.authDao,
    this.appleSignInService,
    this.huaweiLoginService,
  });
}
