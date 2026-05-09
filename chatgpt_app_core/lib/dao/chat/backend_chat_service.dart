import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

class BackendChatService implements ChatService {
  final AISettings _settings;

  BackendChatService(this._settings);

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, String>> history,
  }) async {
    final uri = BackendConst.buildUri('/uapi/chat/completions');
    final messages = [
      ...history,
      {'role': 'user', 'content': prompt},
    ];
    final body = {
      'model': _settings.effectiveModel,
      'messages': messages,
      'max_tokens': 1000,
    };
    final token = LoginDao.getBoardingPass();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    };
    final response = await http.post(uri, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    AILogger.log('backend response: ${response.statusCode}');

    if (response.statusCode == 401) {
      LoginDao.logOut();
      throw Exception('登录已过期，请重新登录');
    }

    const utf8decoder = Utf8Decoder();
    final bodyString = utf8decoder.convert(response.bodyBytes);
    AILogger.log('backend response body: ${AILogger.truncate(bodyString)}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      final result = json.decode(bodyString) as Map<String, dynamic>;
      if (result['code'] == 0 && result['data'] != null) {
        final data = result['data'] as Map<String, dynamic>;
        final content = data['content'] as String?;
        if (content != null && content.isNotEmpty) return content;
        final reasoning = data['reasoningContent'] as String?;
        if (reasoning != null && reasoning.isNotEmpty) return reasoning;
        // 后端返回了 data 但没有可展示的文本内容
        throw Exception('AI 未返回有效内容');
      }
      // code != 0：后端业务错误
      final msg = result['message'] as String?;
      throw Exception(msg ?? '请求失败');
    }
    // HTTP 错误
    throw Exception('服务异常(${response.statusCode})');
  }

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, String>> history,
  }) async* {
    final uri = BackendConst.buildUri('/uapi/chat/completions/stream');
    final messages = [
      ...history,
      {'role': 'user', 'content': prompt},
    ];
    final body = {
      'model': _settings.effectiveModel,
      'messages': messages,
      'max_tokens': 1000,
    };
    final token = LoginDao.getBoardingPass();

    final request = http.Request('POST', uri);
    request.headers.addAll({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${token ?? ''}',
    });
    request.body = jsonEncode(body);

    final httpClient = http.Client();
    try {
      final streamedResponse = await httpClient.send(request)
          .timeout(const Duration(seconds: 20));
      AILogger.log('backend stream status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode == 401) {
        LoginDao.logOut();
        throw Exception('登录已过期，请重新登录');
      }

      if (streamedResponse.statusCode != 200 && streamedResponse.statusCode != 201) {
        final bytes = await streamedResponse.stream.toBytes();
        final errorBody = const Utf8Decoder().convert(bytes);
        throw Exception('服务异常(${streamedResponse.statusCode}): $errorBody');
      }

      final lineStream = streamedResponse.stream
          .transform(const Utf8Decoder())
          .transform(const LineSplitter());

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
            // 常规内容增量
            final content = delta['content'];
            if (content is String && content.isNotEmpty) {
              yield content;
            }
            // 推理内容增量 (DeepSeek reasoning models)
            final reasoning = delta['reasoning_content'];
            if (reasoning is String && reasoning.isNotEmpty) {
              yield reasoning;
            }
          }
        } catch (_) {
          // 忽略无法解析的行
        }
      }
    } finally {
      httpClient.close();
    }
  }
}
