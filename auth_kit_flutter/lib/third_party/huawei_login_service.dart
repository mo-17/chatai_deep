/// 华为账号登录服务接口
///
/// OHOS 宿主通过 MethodChannel 桥接华为账号 SDK，
/// Android/iOS 宿主回退为不可用。
/// 用户主动关闭系统授权页，不作为登录失败显示。
class HuaweiLoginCancelledException implements Exception {
  const HuaweiLoginCancelledException();
}

/// 平台适配器给 UI 的安全提示，不包含授权码或原生异常详情。
class HuaweiLoginException implements Exception {
  final String message;
  const HuaweiLoginException(this.message);
  @override
  String toString() => message;
}

class HuaweiLoginResult {
  /// getAuthCode 模式返回的授权码
  final String? authCode;

  /// quickLogin 模式返回的 accessToken
  final String? accessToken;

  /// 当前使用的登录模式
  final String mode; // 'getAuthCode' | 'quickLogin'

  const HuaweiLoginResult({
    this.authCode,
    this.accessToken,
    required this.mode,
  });
}

/// 华为登录抽象接口 —— 宿主项目实现
abstract class IHuaweiLoginService {
  /// 发起华为授权码登录
  Future<HuaweiLoginResult> signInWithAuthCode();

  /// 发起华为一键登录
  Future<HuaweiLoginResult> signInWithQuickLogin();

  /// 当前设备是否支持华为账号登录
  bool get isAvailable;
}

/// 默认实现：不可用（非 OHOS 平台回退）
class HuaweiLoginUnavailable implements IHuaweiLoginService {
  @override
  bool get isAvailable => false;

  @override
  Future<HuaweiLoginResult> signInWithAuthCode() {
    throw UnsupportedError('Huawei login is not available on this platform');
  }

  @override
  Future<HuaweiLoginResult> signInWithQuickLogin() {
    throw UnsupportedError('Huawei login is not available on this platform');
  }
}
