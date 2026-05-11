import 'package:flutter/material.dart';

/// 主题配置 —— 宿主可通过 AuthKit.init(theme: ...) 覆盖
class AuthKitTheme {
  final Color primaryColor;
  final Color backgroundColor;
  final Color surfaceColor;
  final Color textColor;
  final Color subtitleColor;
  final Color borderColor;
  final Color errorColor;
  final double borderRadius;
  final double inputHeight;

  const AuthKitTheme({
    required this.primaryColor,
    required this.backgroundColor,
    required this.surfaceColor,
    required this.textColor,
    required this.subtitleColor,
    required this.borderColor,
    required this.errorColor,
    this.borderRadius = 12.0,
    this.inputHeight = 48.0,
  });

  factory AuthKitTheme.defaults() {
    return const AuthKitTheme(
      primaryColor: Color(0xFF0F3460),
      backgroundColor: Color(0xFFF5F5F5),
      surfaceColor: Colors.white,
      textColor: Color(0xFF333333),
      subtitleColor: Color(0xFF888888),
      borderColor: Color(0xFFE0E0E0),
      errorColor: Color(0xFFE53935),
    );
  }

  /// 暗色主题，适合深色背景的宿主页面
  factory AuthKitTheme.dark() {
    return const AuthKitTheme(
      primaryColor: Color(0xFF64B5F6),
      backgroundColor: Colors.transparent,
      surfaceColor: Color(0xFF424242),
      textColor: Colors.white,
      subtitleColor: Color(0xFFBDBDBD),
      borderColor: Color(0xFF616161),
      errorColor: Color(0xFFEF5350),
    );
  }
}
