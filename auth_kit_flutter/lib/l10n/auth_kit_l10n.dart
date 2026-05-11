/// 国际化基类
abstract class AuthKitL10n {
  String get loginCodeTab;
  String get loginPasswordTab;
  String get sendCode;
  String get resendCode;
  String get codeSent;
  String get enterCode;
  String get codeVerifyLogin;
  String get passwordLogin;
  String get register;
  String get forgotPassword;
  String get resetPassword;
  String get bindIdentity;
  String get bindIdentityDesc;
  String get confirm;
  String get cancel;
  String get appleSignIn;
  String get huaweiSignIn;
  String get huaweiSignInQuick;
  String get countryCodePickerTitle;
  String get identifierHint;
  String get passwordHint;
  String get emailHint;
  String get phoneHint;

  static AuthKitL10n? _instance;
  static AuthKitL10n get instance => _instance ?? _DefaultL10n();
  static set instance(AuthKitL10n v) => _instance = v;
}

class _DefaultL10n extends AuthKitL10n {
  @override String get loginCodeTab => '验证码登录';
  @override String get loginPasswordTab => '密码登录';
  @override String get sendCode => '发送验证码';
  @override String get resendCode => '重新发送';
  @override String get codeSent => '验证码已发送';
  @override String get enterCode => '请输入验证码';
  @override String get codeVerifyLogin => '验证码登录';
  @override String get passwordLogin => '密码登录';
  @override String get register => '注册';
  @override String get forgotPassword => '忘记密码';
  @override String get resetPassword => '重置密码';
  @override String get bindIdentity => '绑定账号';
  @override String get bindIdentityDesc => '首次使用第三方登录，请绑定邮箱或手机号以完成注册';
  @override String get confirm => '确认';
  @override String get cancel => '取消';
  @override String get appleSignIn => '使用 Apple 登录';
  @override String get huaweiSignIn => '华为账号登录';
  @override String get huaweiSignInQuick => '华为一键登录';
  @override String get countryCodePickerTitle => '选择国家/地区';
  @override String get identifierHint => '请输入邮箱或手机号';
  @override String get passwordHint => '请输入密码';
  @override String get emailHint => '请输入邮箱地址';
  @override String get phoneHint => '请输入手机号';
}
