import 'package:flutter/material.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/pages/login_page.dart';

class NavigatorUtil {
  ///用于在获取不到context的地方，如dao中跳转页面时使用，需要在HomePage赋值
  static BuildContext? _context;

  static updateContext(BuildContext context) {
    NavigatorUtil._context = context;
  }

  ///跳转到指定页面
  static Future<T?> push<T extends Object?>(BuildContext context, Widget page) {
    return Navigator.push(
        context, MaterialPageRoute(builder: (context) => page));
  }

  ///跳转到首页
  static goToHome(BuildContext context) {
    if (LoginConfig.instance().homePage is Widget) {
      // 清空整个账号导航栈，避免 B 登录后返回到 A 的 BottomNavigator/二级页。
      Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
              builder: (context) => LoginConfig.instance().homePage!),
          (route) => false);
    } else {
      throw Exception('please call LoginConfig init first');
    }
  }

  ///跳转到登录页
  static goToLogin() {
    // 401/登出可能发生在任意二级页；必须清空旧账号的全部路由和 State。
    Navigator.pushAndRemoveUntil(
        _context!,
        MaterialPageRoute(builder: (context) => const LoginPage()),
        (route) => false);
  }
}
