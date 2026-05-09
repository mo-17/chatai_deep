import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

///log工具，仅在 debug 模式下输出
class AILogger {
  static bool _isEnable = true;

  static set isEnable(bool value) {
    _isEnable = value;
  }

  static void log(String message) {
    if (!_isEnable || kReleaseMode) {
      return;
    }
    dev.log(message, name: 'AILogger');
  }

  /// 截断长文本，避免日志泄漏完整用户/AI 内容
  static String truncate(String text, [int maxLen = 200]) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}... (${text.length} chars)';
  }
}
