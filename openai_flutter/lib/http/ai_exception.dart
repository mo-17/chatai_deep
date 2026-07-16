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
  final String message;
  final int statusCode;
  final Map<String, String> headers;

  AIRequestException(
    this.message,
    this.statusCode, {
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable({
          for (final entry in headers.entries)
            entry.key.toLowerCase(): entry.value,
        });

  Duration? get retryAfter {
    final seconds = int.tryParse(headers['retry-after'] ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  @override
  String toString() {
    return 'RequestFailedException{statusCode: $statusCode}';
  }
}
