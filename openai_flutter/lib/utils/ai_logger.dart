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
    r'''([^\s#]*)#([^\s#"'()\[\]{}<>]+)''',
    caseSensitive: false,
  );
  static final RegExp _fragmentStructuredField = RegExp(
    r'[,;][a-z_][a-z0-9_.-]*=',
    caseSensitive: false,
  );
  static final RegExp _fragmentStructuredSeparator = RegExp(r'[,;]');
  static final RegExp _diagnosticFieldName = RegExp(
    r'^[a-z_][a-z0-9_.-]*$',
    caseSensitive: false,
  );
  static final RegExp _diagnosticNumber = RegExp(
    r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$',
    caseSensitive: false,
  );
  static final RegExp _diagnosticStatus = RegExp(
    r'^(?:active|cancelled|canceled|complete|completed|disabled|done|enabled|error|failed|failure|false|healthy|idle|inactive|no|none|null|off|ok|on|pending|queued|ready|running|skipped|succeeded|success|timeout|true|unknown|unhealthy|warn|warning|yes)$',
    caseSensitive: false,
  );
  static final RegExp _fragmentTrailingPunctuation = RegExp(r'[,;.!?:]+$');
  static final RegExp _sensitiveFragmentMarker = RegExp(
    r'(?:^|[?&=:/._-])(?:authorization|x-api-key|api[_-]?key|key|(?:access|refresh|id|auth|session)[_-]?token|token|(?:client|api|private|secret)[_-]?secret|secret|password|boarding[-_]?pass|credential|signature|sig)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _sensitiveFragmentCredential = RegExp(
    r'(?:^|[?&=:/])(?:code=|(?:bearer|basic)(?:\s+|=))',
    caseSensitive: false,
  );
  static final RegExp _paddedBase64Fragment = RegExp(
    r'^[a-z0-9+/_-]+={1,2}$',
    caseSensitive: false,
  );
  static final RegExp _jwtFragment = RegExp(
    r'^[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+$',
    caseSensitive: false,
  );
  static final RegExp _longHexFragment = RegExp(
    r'^[a-f0-9]{32,}$',
    caseSensitive: false,
  );
  static final RegExp _longUrlSafeFragment = RegExp(
    r'^[a-z0-9._~-]{32,}$',
    caseSensitive: false,
  );
  static final RegExp _asciiLetter = RegExp(r'[a-z]', caseSensitive: false);
  static final RegExp _asciiDigit = RegExp(r'[0-9]');

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
      _redactUrlFragment,
    );
    return redacted.replaceAll(_bearerSecret, 'Bearer <redacted>');
  }

  static String _redactUrlFragment(Match match) {
    var fragment = match.group(2)!;
    var suffix = '';
    var unsafeStructuredSuffix = false;
    final structuredField = _fragmentStructuredField.firstMatch(fragment);
    if (structuredField != null) {
      final candidateSuffix = fragment.substring(structuredField.start);
      if (!_isSensitiveFragment(candidateSuffix) &&
          _isLowRiskStructuredSuffix(candidateSuffix)) {
        suffix = candidateSuffix;
        fragment = fragment.substring(0, structuredField.start);
      } else {
        unsafeStructuredSuffix = true;
      }
    } else {
      suffix =
          _fragmentTrailingPunctuation.firstMatch(fragment)?.group(0) ?? '';
      if (suffix.isNotEmpty) {
        fragment = fragment.substring(0, fragment.length - suffix.length);
      }
    }
    if (!unsafeStructuredSuffix && !_isSensitiveFragment(fragment)) {
      return match.group(0)!;
    }
    return '${match.group(1)}#<redacted>$suffix';
  }

  static bool _isLowRiskStructuredSuffix(String suffix) {
    if (suffix.length < 2) return false;
    final fields = suffix.substring(1).split(_fragmentStructuredSeparator);
    for (final field in fields) {
      final separator = field.indexOf('=');
      if (separator <= 0 || separator == field.length - 1) return false;

      final name = field.substring(0, separator);
      final value = field.substring(separator + 1);
      if (!_diagnosticFieldName.hasMatch(name) ||
          _isSensitiveFragment(field) ||
          value.length > 24 ||
          (!_diagnosticNumber.hasMatch(value) &&
              !_diagnosticStatus.hasMatch(value))) {
        return false;
      }
    }
    return true;
  }

  static bool _isSensitiveFragment(String fragment) {
    var candidate = fragment;
    try {
      candidate = Uri.decodeComponent(fragment);
    } on FormatException {
      // 非法 percent-encoding 仍按原文判定，不影响日志输出。
    }
    return _sensitiveFragmentMarker.hasMatch(candidate) ||
        _sensitiveFragmentCredential.hasMatch(candidate) ||
        _isCredentialShapedFragment(candidate);
  }

  static bool _isCredentialShapedFragment(String candidate) {
    if (candidate.length >= 8 &&
        candidate.length % 4 == 0 &&
        _paddedBase64Fragment.hasMatch(candidate)) {
      return true;
    }
    if (candidate.length >= 24 && _jwtFragment.hasMatch(candidate)) {
      return true;
    }
    if (_longHexFragment.hasMatch(candidate)) return true;
    return _longUrlSafeFragment.hasMatch(candidate) &&
        _asciiLetter.hasMatch(candidate) &&
        _asciiDigit.hasMatch(candidate);
  }

  /// 截断长文本，避免日志泄漏完整用户/AI 内容
  static String truncate(String text, [int maxLen = 200]) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}... (${text.length} chars)';
  }
}
