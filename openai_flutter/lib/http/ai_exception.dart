import 'dart:async';

///openai_flutter 抛出的异常
class AIException implements Exception {
  final String message;

  AIException(this.message);

  @override
  String toString() {
    return message;
  }
}

class AIRequestException implements Exception {
  static final _delaySeconds = RegExp(r'^\d+$');
  static const _safeCodes = {
    'unknown_parameter',
    'unsupported_parameter',
  };

  final String message;
  final int statusCode;
  final Map<String, String> headers;
  final String? safeCode;
  final bool responseStarted;

  AIRequestException(
    this.message,
    this.statusCode, {
    Map<String, String> headers = const {},
    String? safeCode,
    this.responseStarted = false,
  })  : headers = Map.unmodifiable(_safeHeaders(headers)),
        safeCode = _safeCodes.contains(safeCode) ? safeCode : null;

  static Map<String, String> _safeHeaders(Map<String, String> headers) {
    String? normalizedRetryAfter;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'retry-after') continue;
      final seconds = _retryAfterSeconds(entry.value);
      normalizedRetryAfter = seconds?.toString();
    }
    return {
      if (normalizedRetryAfter != null) 'retry-after': normalizedRetryAfter,
    };
  }

  Duration? get retryAfter {
    final value = headers['retry-after'];
    if (value == null) return null;
    final seconds = _retryAfterSeconds(value);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  static int? _retryAfterSeconds(String value) {
    if (!_delaySeconds.hasMatch(value)) return null;
    final parsed = int.tryParse(value);
    if (parsed == null) return null;
    if (parsed < 1) return 1;
    if (parsed > 120) return 120;
    return parsed;
  }

  @override
  String toString() {
    return 'RequestFailedException{statusCode: $statusCode}';
  }
}

/// 请求被调用方主动取消时抛出的安全异常，不携带请求 URI 或响应正文。
class AIRequestCancelledException implements Exception {
  const AIRequestCancelledException();

  @override
  String toString() => 'AIRequestCancelledException: Request cancelled';
}

/// 网络传输或 endpoint 构造失败时抛出的安全异常，不携带请求 URI。
class AITransportException implements Exception {
  const AITransportException(
      {this.responseStarted = false, this.safeCode = 'network_error'})
      : message = 'Network request failed';

  final String message;
  final bool responseStarted;
  final String safeCode;

  @override
  String toString() => 'AITransportException: $message';
}

class AIResponseFormatException implements Exception {
  const AIResponseFormatException();
  @override
  String toString() => 'AIResponseFormatException: Invalid response';
}

class AIRequestTimeoutException extends TimeoutException {
  final bool responseStarted;
  AIRequestTimeoutException(Duration duration, {this.responseStarted = false})
      : super('Request timed out', duration);
}
