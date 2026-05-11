/// Sign in with Apple 服务接口
///
/// 宿主项目需注入具体实现（如通过 sign_in_with_apple 包）。
/// 返回 Apple ID identityToken 和可选的 authorizationCode / fullName。
class AppleSignInResult {
  final String identityToken;
  final String? authorizationCode;
  final String? givenName;
  final String? familyName;
  final String? email;

  const AppleSignInResult({
    required this.identityToken,
    this.authorizationCode,
    this.givenName,
    this.familyName,
    this.email,
  });

  Map<String, String>? get fullName {
    if (givenName == null && familyName == null) return null;
    return {
      if (givenName != null) 'givenName': givenName!,
      if (familyName != null) 'familyName': familyName!,
    };
  }
}

/// Apple 登录抽象接口 —— 宿主项目实现
abstract class IAppleSignInService {
  /// 发起 Apple 登录，返回 identityToken 等信息
  Future<AppleSignInResult> signIn();

  /// 当前设备是否支持 Apple 登录
  bool get isAvailable;
}

/// 默认实现：不可用（非 Apple 平台回退）
class AppleSignInUnavailable implements IAppleSignInService {
  @override
  bool get isAvailable => false;

  @override
  Future<AppleSignInResult> signIn() {
    throw UnsupportedError('Apple Sign In is not available on this platform');
  }
}
