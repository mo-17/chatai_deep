import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';

///登录接口
class LoginDao {
  /// 同步存储读取的 key。与 [HiCacheTokenStorage._kUserInfo] 保持一致，
  /// 用作仍直接读 HiCache 的老代码兜底，新增逻辑请通过 [LoginSdkConfig.instance.storage]。
  static const kUserInfo = 'user_info';

  static final List<VoidCallback> _onLogoutHooks = [];
  static final List<VoidCallback> _onLoginHooks = [];
  static bool hooksRegistered = false;

  ///注册登出钩子，宿主 App 在初始化时调用，用于清理账号态
  static void addLogoutHook(VoidCallback cb) {
    _onLogoutHooks.add(cb);
  }

  ///注册登录成功钩子，在保存登录信息之后触发
  static void addLoginHook(VoidCallback cb) {
    _onLoginHooks.add(cb);
  }

  ///登录
  static Future<void> login({
    required String userName,
    required String password,
  }) async {
    return _authRequest(LoginSdkConfig.instance.routes.login, userName, password);
  }

  ///注册（注册成功后自动登录）
  static Future<void> register({
    required String userName,
    required String password,
  }) async {
    return _authRequest(
      LoginSdkConfig.instance.routes.register,
      userName,
      password,
    );
  }

  ///发送认证请求并处理响应（login / register 共用）
  static Future<void> _authRequest(
    String path,
    String userName,
    String password,
  ) async {
    final cfg = LoginSdkConfig.instance;
    final uri = BackendConfig.buildUri(path);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({'userName': userName, 'password': password}),
    );
    final bodyString = const Utf8Decoder().convert(response.bodyBytes);
    debugPrint(bodyString);
    if (response.statusCode != 200) {
      throw Exception(bodyString);
    }
    final json = jsonDecode(bodyString) as Map<String, dynamic>;
    final result = cfg.responseAdapter.parseLogin(json);

    await cfg.storage.writeProfile(
      token: result.token,
      userName: result.userName,
      avatar: result.avatar,
      extras: result.extras,
    );

    for (final cb in _onLoginHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  ///忘记密码 - 请求 reset code
  static Future<Map<String, dynamic>> requestPasswordReset(
    String userName,
  ) async {
    final uri =
        BackendConfig.buildUri(LoginSdkConfig.instance.routes.forgotPasswordRequest);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({'userName': userName}),
    );
    final bodyString = const Utf8Decoder().convert(response.bodyBytes);
    if (response.statusCode == 200) {
      return jsonDecode(bodyString) as Map<String, dynamic>;
    }
    throw Exception(bodyString);
  }

  ///忘记密码 - 确认 reset code 并设置新密码
  static Future<void> confirmPasswordReset(
    String userName,
    String code,
    String newPassword,
  ) async {
    final cfg = LoginSdkConfig.instance;
    final uri = BackendConfig.buildUri(cfg.routes.forgotPasswordConfirm);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'userName': userName,
        'code': code,
        'newPassword': newPassword,
      }),
    );
    final bodyString = const Utf8Decoder().convert(response.bodyBytes);
    if (response.statusCode != 200) {
      throw Exception(bodyString);
    }
    cfg.responseAdapter.checkOk(jsonDecode(bodyString) as Map<String, dynamic>);
  }

  ///获取当前登录用户的信息
  static Map<String, dynamic>? getUserInfo() {
    return LoginSdkConfig.instance.storage.readProfileSync();
  }

  ///获取登录token
  static String? getBoardingPass() {
    return LoginSdkConfig.instance.storage.readTokenSync();
  }

  ///获取用于创建多账号数据的账号标识
  static String? getAccountHash() {
    final profile = LoginSdkConfig.instance.storage.readProfileSync();
    return profile?['accountHash']?.toString();
  }

  /// 多通道认证（auth_kit_flutter）登录成功后写 token。
  /// `extras` 用于扩展字段（如 imoocId、phone 等）。
  static Future<void> saveAuthToken(
    String token, {
    String? userName,
    String? avatar,
    String? imoocId,
    Map<String, dynamic> extras = const {},
  }) async {
    final merged = <String, dynamic>{
      if (imoocId != null) 'imoocId': imoocId,
      ...extras,
    };
    await LoginSdkConfig.instance.storage.writeProfile(
      token: token,
      userName: userName ?? '',
      avatar: avatar,
      extras: merged,
    );
    for (final cb in _onLoginHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  /// 游客模式的哨兵 token。纯本地、不会被后端接受 —— 游客的后端调用
  /// 会得到 401/失败，相关功能（后端代理等）应由宿主在 UI 层屏蔽。
  static const kGuestToken = 'guest-mode';

  ///游客模式登录：**不访问后端**，写入本地哨兵 token + 游客资料即可进入主界面。
  ///accountHash 固定为 'guest'（extras 覆盖默认的 userName.hashCode），
  ///游客的本地数据（会话库 / AI 设置）独立于任何正式账号。
  static Future<void> loginAsGuest() async {
    await LoginSdkConfig.instance.storage.writeProfile(
      token: kGuestToken,
      userName: '游客',
      extras: const {'accountHash': 'guest', 'guest': true},
    );
    for (final cb in _onLoginHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  ///当前是否处于游客模式
  static bool isGuest() => getUserInfo()?['guest'] == true;

  ///登出
  static Future<void> logOut() async {
    for (final cb in _onLogoutHooks) {
      try {
        cb();
      } catch (_) {}
    }
    await LoginSdkConfig.instance.storage.clear();
    LoginSdkConfig.instance.onLogoutNavigate();
  }
}
