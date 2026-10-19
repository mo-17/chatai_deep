import 'dart:io';

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/services.dart';

/// 只把一次性授权码交给后端；华为 Token 不在客户端保存。
class OhosHuaweiLoginService implements IHuaweiLoginService {
  static const channel = MethodChannel('com.hzb.flutter_ai/huawei_login');

  @override
  bool get isAvailable => Platform.operatingSystem == 'ohos';

  @override
  Future<HuaweiLoginResult> signInWithAuthCode() async {
    try {
      final response = await channel.invokeMapMethod<String, dynamic>('signIn');
      final code = response?['authCode'];
      if (code is! String || code.trim().isEmpty || code.length > 16384) {
        throw const HuaweiLoginException('华为账号未返回有效授权，请重试');
      }
      return HuaweiLoginResult(authCode: code, mode: 'getAuthCode');
    } on PlatformException catch (error) {
      if (error.code == 'huawei_cancelled') {
        throw const HuaweiLoginCancelledException();
      }
      final message = switch (error.code) {
        'huawei_not_configured' => '华为账号登录尚未配置，请联系管理员',
        'huawei_unavailable' => '当前设备暂不支持华为账号登录',
        'huawei_busy' => '华为账号授权正在进行中，请稍候',
        'huawei_network' => '网络连接异常，请检查网络后重试',
        'huawei_timeout' => '华为账号授权超时，请重试',
        'huawei_account_required' => '请先登录设备的华为账号',
        _ => '华为账号授权失败，请重试或使用其他登录方式',
      };
      throw HuaweiLoginException(message);
    } on MissingPluginException {
      throw const HuaweiLoginException('当前设备暂不支持华为账号登录');
    }
  }

  /// 保留接口兼容性，鸿蒙统一使用服务端授权码流程。
  @override
  Future<HuaweiLoginResult> signInWithQuickLogin() => signInWithAuthCode();
}
