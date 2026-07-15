import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

///log工具，仅在 debug 模式下输出
class AILogger {
  static bool _isEnable = true;
  static final RegExp _namedSecret = RegExp(
    r'''\b(authorization|x-api-key|[a-z0-9_-]*api[_-]?key|(?:access|refresh|id|auth|session)[_-]?token|token|(?:client|api|private|secret)[_-]?secret|secret|password|boarding[-_]?pass)\b(["']?\s*[:=]\s*)(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|((?:bearer|basic)\s+)?([^"'\s,;&}\]]+))''',
    caseSensitive: false,
  );
  static final RegExp _bearerSecret = RegExp(
    r'\bbearer\s+[a-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _urlUserInfo = RegExp(
    r'\b([a-z][a-z0-9+.-]*://)[^/?#\s@]+@',
    caseSensitive: false,
  );
  static final RegExp _querySecret = RegExp(
    r'''([?&]key\s*=\s*)(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|([^&#\s]+))''',
    caseSensitive: false,
  );
  static final RegExp _urlFragment = RegExp(
    r'((?:\b[a-z][a-z0-9+.-]*://|//|(?:\.\.?/|/))[^\s#]*)#([^\s]*)',
    caseSensitive: false,
  );
  static final RegExp _sensitiveFragmentMarker = RegExp(
    r'(?:^|[?&=:/._-])(?:authorization|x-api-key|api[_-]?key|key|(?:access|refresh|id|auth|session)[_-]?token|token|(?:client|api|private|secret)[_-]?secret|secret|password|boarding[-_]?pass|credential|signature|sig|bearer|basic|code)(?:$|[?&=:/._-])',
    caseSensitive: false,
  );

  static set isEnable(bool value) {
    _isEnable = value;
  }

  static void log(String message) {
    if (!_isEnable || kReleaseMode) {
      return;
    }
    dev.log(redactSensitive(message), name: 'AILogger');
  }

  /// 清除常见 header、JSON、query 参数与裸 Bearer 凭据。
  static String redactSensitive(String message) {
    var redacted = message.replaceAllMapped(_namedSecret, (match) {
      final prefix = '${match.group(1)}${match.group(2)}';
      if (match.group(3) != null) return '$prefix"<redacted>"';
      if (match.group(4) != null) return "$prefix'<redacted>'";
      return '$prefix${match.group(5) ?? ''}<redacted>';
    });
    redacted = redacted.replaceAllMapped(
      _urlUserInfo,
      (match) => '${match.group(1)}<redacted>@',
    );
    redacted = redacted.replaceAllMapped(_querySecret, (match) {
      final prefix = match.group(1)!;
      if (match.group(2) != null) return '$prefix"<redacted>"';
      if (match.group(3) != null) return "$prefix'<redacted>'";
      return '$prefix<redacted>';
    });
    redacted = redacted.replaceAllMapped(
      _urlFragment,
      (match) => _isSensitiveFragment(match.group(2)!)
          ? '${match.group(1)}#<redacted>'
          : match.group(0)!,
    );
    return redacted.replaceAll(_bearerSecret, 'Bearer <redacted>');
  }

  static bool _isSensitiveFragment(String fragment) {
    var candidate = fragment;
    try {
      candidate = Uri.decodeComponent(fragment);
    } on FormatException {
      // 非法 percent-encoding 仍按原文判定，不影响日志输出。
    }
    return _sensitiveFragmentMarker.hasMatch(candidate);
  }

  /// 截断长文本，避免日志泄漏完整用户/AI 内容
  static String truncate(String text, [int maxLen = 200]) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}... (${text.length} chars)';
  }
}
