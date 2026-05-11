import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/util/navigator_util.dart';

///登录接口
class LoginDao {
  static const kUserInfo = 'user_info';

  static final List<VoidCallback> _onLogoutHooks = [];
  static final List<VoidCallback> _onLoginHooks = [];
  static bool hooksRegistered = false;

  ///注册登出钩子，宿主 App 在初始化时调用，用于清理账号态
  static void addLogoutHook(VoidCallback cb) {
    _onLogoutHooks.add(cb);
  }

  ///注册登录成功钩子，在 _saveUserInfo 之后触发
  static void addLoginHook(VoidCallback cb) {
    _onLoginHooks.add(cb);
  }

  ///登录
  static login({required String userName, required String password}) async {
    return _authRequest('/uapi/user/login', userName, password);
  }

  ///注册（注册成功后自动登录）
  static register({required String userName, required String password}) async {
    return _authRequest('/uapi/user/registration', userName, password);
  }

  ///发送认证请求并处理响应（login / register 共用）
  static Future<void> _authRequest(
    String path,
    String userName,
    String password,
  ) async {
    var uri = BackendConfig.buildUri(path);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({'userName': userName, 'password': password}),
    );
    Utf8Decoder utf8decoder = const Utf8Decoder(); //fix 中文乱码
    String bodyString = utf8decoder.convert(response.bodyBytes);
    debugPrint(bodyString);
    if (response.statusCode == 200) {
      var result = json.decode(bodyString);
      if (result['code'] == 0 && result['data'] != null) {
        Map<String, dynamic> extra = result['extra'];
        //保存登录信息
        _saveUserInfo(
            boardingPass: result['data'],
            userName: extra['userName'],
            avatar: extra['avatar'],
            imoocId: extra['imoocId']);
        // 触发登录成功钩子（AISettingsProvider.reload 等）
        for (final cb in _onLoginHooks) {
          try {
            cb();
          } catch (_) {}
        }
      } else {
        throw Exception(bodyString);
      }
    } else {
      throw Exception(bodyString);
    }
  }

  ///忘记密码 - 请求 reset code
  static Future<Map<String, dynamic>> requestPasswordReset(
    String userName,
  ) async {
    var uri = BackendConfig.buildUri('/uapi/user/forgot-password/request');
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({'userName': userName}),
    );
    Utf8Decoder utf8decoder = const Utf8Decoder();
    String bodyString = utf8decoder.convert(response.bodyBytes);
    if (response.statusCode == 200) {
      return json.decode(bodyString) as Map<String, dynamic>;
    }
    throw Exception(bodyString);
  }

  ///忘记密码 - 确认 reset code 并设置新密码
  static Future<void> confirmPasswordReset(
    String userName,
    String code,
    String newPassword,
  ) async {
    var uri = BackendConfig.buildUri('/uapi/user/forgot-password/confirm');
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
    Utf8Decoder utf8decoder = const Utf8Decoder();
    String bodyString = utf8decoder.convert(response.bodyBytes);
    if (response.statusCode == 200) {
      var result = json.decode(bodyString);
      if (result['code'] != 0) {
        throw Exception(result['message'] ?? '重置失败');
      }
      return;
    }
    throw Exception(bodyString);
  }

  ///保存登录用户信息
  static void _saveUserInfo(
      {required boardingPass,
      required userName,
      required avatar,
      required imoocId}) {
    var map = {
      'boardingPass': boardingPass,
      'avatar': avatar,
      'imoocId': imoocId,
      'userName': userName,
      'accountHash': userName.hashCode,
    };
    HiCache.getInstance().setString(kUserInfo, jsonEncode(map));
  }

  ///获取当前登录用户的信息
  static Map<String, dynamic>? getUserInfo() {
    var result = HiCache.getInstance().get(kUserInfo);
    if (result != null) {
      return jsonDecode(result);
    }
    return null;
  }

  ///获取登录token
  static String? getBoardingPass() {
    var result = HiCache.getInstance().get(kUserInfo);
    if (result != null) {
      var map = jsonDecode(result);
      return map['boardingPass'];
    }
    return null;
  }

  ///获取用于创建多账号数据的账号标识
  static String? getAccountHash() {
    var result = HiCache.getInstance().get(kUserInfo);
    if (result != null) {
      var map = jsonDecode(result);
      return map['accountHash'].toString();
    }
    return null;
  }

  /// 新多通道认证登录成功后保存 token（兼容 auth_kit_flutter LoginResult）
  static void saveAuthToken(String token, {String? userName, String? avatar, String? imoocId}) {
    _saveUserInfo(
      boardingPass: token,
      userName: userName ?? '',
      avatar: avatar ?? '',
      imoocId: imoocId ?? '',
    );
    for (final cb in _onLoginHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  ///登出
  static void logOut() {
    for (final cb in _onLogoutHooks) {
      try {
        cb();
      } catch (_) {}
    }
    //移除登录保存的信息
    HiCache.getInstance().remove(kUserInfo);
    NavigatorUtil.goToLogin();
  }
}
