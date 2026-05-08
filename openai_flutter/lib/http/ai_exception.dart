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

  AIRequestException(this.message, this.statusCode);

  @override
  String toString() {
    return 'RequestFailedException{message: $message, statusCode: $statusCode}';
  }
}
