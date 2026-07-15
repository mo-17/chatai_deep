import 'auth_api_client.dart';

/// 封装 /uapi/auth/* 全部接口
class AuthDao {
  final AuthApiClient client;

  AuthDao(this.client);

  /// 发送验证码
  Future<void> sendCode({
    required String channel, // 'email' | 'sms'
    required String identifier,
    required String purpose, // 'login' | 'register' | 'bind' | 'reset_password'
  }) async {
    await client.post('/uapi/auth/code/send', {
      'channel': channel,
      'identifier': identifier,
      'purpose': purpose,
    });
  }

  /// 验证码登录
  Future<LoginResult> loginByCode({
    required String channel,
    required String identifier,
    required String code,
  }) async {
    final resp = await client.post('/uapi/auth/login/code', {
      'channel': channel,
      'identifier': identifier,
      'code': code,
    });
    return LoginResult.fromJson(resp);
  }

  /// 密码登录
  Future<LoginResult> loginByPassword({
    required String channel,
    required String identifier,
    required String password,
  }) async {
    final resp = await client.post('/uapi/auth/login/password', {
      'channel': channel,
      'identifier': identifier,
      'password': password,
    });
    return LoginResult.fromJson(resp);
  }

  /// 注册
  Future<LoginResult> register({
    required String channel,
    required String identifier,
    required String code,
    String? password,
  }) async {
    final resp = await client.post('/uapi/auth/register', {
      'channel': channel,
      'identifier': identifier,
      'code': code,
      if (password != null) 'password': password,
    });
    return LoginResult.fromJson(resp);
  }

  /// 绑定通道
  Future<Map<String, dynamic>> bind({
    required String channel,
    required String identifier,
    required String code,
  }) async {
    return client.post('/uapi/auth/bind', {
      'channel': channel,
      'identifier': identifier,
      'code': code,
    });
  }

  /// 重置密码
  Future<void> resetPassword({
    required String channel,
    required String identifier,
    required String code,
    required String newPassword,
  }) async {
    await client.post('/uapi/auth/reset-password', {
      'channel': channel,
      'identifier': identifier,
      'code': code,
      'newPassword': newPassword,
    });
  }

  /// 华为登录
  Future<ThirdPartyLoginResult> huaweiLogin({
    required String mode, // 'getAuthCode' | 'quickLogin'
    String? authCode,
    String? accessToken,
  }) async {
    final resp = await client.post('/uapi/auth/huawei/login', {
      'mode': mode,
      if (authCode != null) 'authCode': authCode,
      if (accessToken != null) 'accessToken': accessToken,
    });
    return ThirdPartyLoginResult.fromJson(resp);
  }

  /// 华为绑定并登录
  Future<LoginResult> huaweiBindAndLogin({
    required String bindTicket,
    required String channel,
    required String identifier,
    required String code,
  }) async {
    final resp = await client.post('/uapi/auth/huawei/bind-and-login', {
      'bindTicket': bindTicket,
      'channel': channel,
      'identifier': identifier,
      'code': code,
    });
    return LoginResult.fromJson(resp);
  }

  /// Apple 登录
  Future<ThirdPartyLoginResult> appleLogin({
    required String identityToken,
    String? authorizationCode,
    Map<String, String>? fullName,
  }) async {
    final resp = await client.post('/uapi/auth/apple/login', {
      'identityToken': identityToken,
      if (authorizationCode != null) 'authorizationCode': authorizationCode,
      if (fullName != null) 'fullName': fullName,
    });
    return ThirdPartyLoginResult.fromJson(resp);
  }

  /// Apple 绑定并登录
  Future<LoginResult> appleBindAndLogin({
    required String bindTicket,
    required String channel,
    required String identifier,
    required String code,
  }) async {
    final resp = await client.post('/uapi/auth/apple/bind-and-login', {
      'bindTicket': bindTicket,
      'channel': channel,
      'identifier': identifier,
      'code': code,
    });
    return LoginResult.fromJson(resp);
  }
}

/// 登录结果
class LoginResult {
  final String token;
  final Map<String, dynamic> extra;

  const LoginResult({required this.token, required this.extra});

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    return LoginResult(
      token: json['data']?.toString() ?? '',
      extra: (json['extra'] as Map<String, dynamic>?) ?? {},
    );
  }
}

/// 第三方登录结果
class ThirdPartyLoginResult {
  final String? token; // 已绑定则直接返回 token
  final bool needBinding;
  final String? bindTicket;
  final Map<String, dynamic>? extra;

  const ThirdPartyLoginResult({
    this.token,
    required this.needBinding,
    this.bindTicket,
    this.extra,
  });

  factory ThirdPartyLoginResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    final rawExtra = json['extra'];
    final extra = rawExtra is Map<String, dynamic> ? rawExtra : null;
    if (data is String) {
      return ThirdPartyLoginResult(
        token: data,
        needBinding: false,
        extra: extra,
      );
    }
    // needBinding 为 true 时 data 内含 bindTicket；其余 Map 不应被转成 token。
    if (data is Map && data['needBinding'] == true) {
      return ThirdPartyLoginResult(
        needBinding: true,
        bindTicket: data['bindTicket']?.toString(),
      );
    }
    return ThirdPartyLoginResult(
      needBinding: false,
      extra: extra,
    );
  }
}
