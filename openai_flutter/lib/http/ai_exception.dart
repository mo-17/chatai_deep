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
  static const _safeResponseHeaders = {
    'retry-after',
    'x-request-id',
  };
  static final _delaySeconds = RegExp(r'^\d+$');

  final String message;
  final int statusCode;
  final Map<String, String> headers;

  AIRequestException(
    this.message,
    this.statusCode, {
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable({
          for (final entry in headers.entries)
            if (_safeResponseHeaders.contains(entry.key.toLowerCase()))
              entry.key.toLowerCase(): entry.value,
        });

  Duration? get retryAfter {
    final value = headers['retry-after'];
    if (value == null || !_delaySeconds.hasMatch(value)) return null;
    final seconds = int.tryParse(value);
    return seconds == null ? null : Duration(seconds: seconds);
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
