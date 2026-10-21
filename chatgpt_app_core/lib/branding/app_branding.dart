import 'package:flutter/material.dart';

/// 启动阶段不依赖账号、缓存或主题初始化。
abstract final class AppBranding {
  static const name = '艾普';
  static const mark = 'assets/images/aipu-mark.png';
  static const primary = Color(0xFF6558E8);
  static const lightBackground = Color(0xFFF8FAFC);
  static const darkBackground = Color(0xFF0C1020);
  static const lightForeground = Color(0xFF17213D);
  static const darkForeground = Color(0xFFF1F5FE);
  static const lightMuted = Color(0xFF59667E);
  static const darkMuted = Color(0xFFA8B1C8);
}
