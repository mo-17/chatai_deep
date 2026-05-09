import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

///HTTP请求工具类
class AIHttp {
  static Future<T> post<T>({
    required AIConfigBuilder config,
    required String url,
    required T Function(Map<String, dynamic>) onSuccess,
    Map<String, dynamic>? body,
  }) async {
    AILogger.log('starting request to $url');

    ///借助HttpClient来发送请求
    HttpClient httpClient = HttpClient();

    ///设置代理
    var proxy = config.proxy;
    if (proxy != null && proxy.trim().isNotEmpty) {
      httpClient.findProxy = (uri) {
        return "PROXY $proxy";
      };
    }

    IOClient myClient = IOClient(httpClient);
    final http.Response response = await myClient
        .post(Uri.parse(url),
            headers: config.headers(),
            body: body != null ? jsonEncode(body) : null)
        .timeout(const Duration(seconds: 15));
    AILogger.log(
        'request to $url finished with status code ${response.statusCode}');
    AILogger.log('starting decoding response body');

    ///防止乱码
    Utf8Decoder utf8decoder = const Utf8Decoder();
    final bodyString = utf8decoder.convert(response.bodyBytes);
    Map<String, dynamic> decodedBody;
    try {
      decodedBody = jsonDecode(bodyString) as Map<String, dynamic>;
    } catch (_) {
      throw AIRequestException(
          'HTTP ${response.statusCode}: $bodyString', response.statusCode);
    }
    AILogger.log("response body decoded successfully");
    if (decodedBody['error'] != null) {
      AILogger.log("an error occurred, throwing exception");
      final Map<String, dynamic> error = decodedBody['error'];
      throw AIRequestException(error['message'], response.statusCode);
    } else {
      AILogger.log("request finished successfully");
      return onSuccess(decodedBody);
    }
  }

  /// SSE 流式 POST 请求，逐 token yield
  static Stream<String> postStream({
    required AIConfigBuilder config,
    required String url,
    Map<String, dynamic>? body,
  }) async* {
    AILogger.log('starting stream request to $url');

    HttpClient httpClient = HttpClient();
    var proxy = config.proxy;
    if (proxy != null && proxy.trim().isNotEmpty) {
      httpClient.findProxy = (uri) => "PROXY $proxy";
    }

    IOClient myClient = IOClient(httpClient);
    final request = http.Request('POST', Uri.parse(url));
    request.headers.addAll(config.headers());
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final streamedResponse = await myClient.send(request)
        .timeout(const Duration(seconds: 20));
    AILogger.log(
        'stream request to $url finished with status ${streamedResponse.statusCode}');

    if (streamedResponse.statusCode != 200) {
      final bytes = await streamedResponse.stream.toBytes();
      final errorBody = const Utf8Decoder().convert(bytes);
      Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(errorBody) as Map<String, dynamic>;
      } catch (_) {
        throw AIRequestException(
            'HTTP ${streamedResponse.statusCode}: $errorBody',
            streamedResponse.statusCode);
      }
      if (decoded['error'] != null) {
        final error = decoded['error'] as Map<String, dynamic>;
        throw AIRequestException(
            error['message'] as String? ?? errorBody,
            streamedResponse.statusCode);
      }
      throw AIRequestException(
          'HTTP ${streamedResponse.statusCode}', streamedResponse.statusCode);
    }

    final lineStream =
        streamedResponse.stream.transform(const Utf8Decoder()).transform(const LineSplitter());

    await for (final line in lineStream) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6);
      if (data == '[DONE]') break;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List<dynamic>?;
        if (choices != null && choices.isNotEmpty) {
          final choice = choices[0];
          if (choice is! Map<String, dynamic>) continue;
          final delta = choice['delta'];
          if (delta is! Map<String, dynamic>) continue;
          // 常规内容增量 (DeepSeek / OpenAI)
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            yield content;
          }
          // 推理内容增量 (DeepSeek reasoning models: deepseek-reasoner)
          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) {
            yield reasoning;
          }
        }
      } catch (_) {
        // 忽略无法解析的行
      }
    }
  }
}
