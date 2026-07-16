import 'package:openai_flutter/model/ai_response.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

abstract class AICreateInterface {
  Future<AIResponse> createChat(
      {String model = 'gpt-3.5-turbo',
      dynamic prompt,
      int? maxTokens,
      double? temperature,
      double? topP,
      int? n,
      String? stop,
      String? user,
      Duration timeout = const Duration(seconds: 15)});

  Stream<AIStreamChunk> createChatStreamEvents({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    int? maxTokens,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
    List<Map<String, dynamic>>? messages,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic> extraBody = const {},
    Future<void>? abortTrigger,
    Duration connectTimeout = const Duration(seconds: 20),
  });
}
