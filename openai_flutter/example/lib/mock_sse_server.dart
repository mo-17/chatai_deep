import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 进程内 SSE mock — 模拟 OpenAI Chat Completions 流式响应。
///
/// 给定一段固定的"回答"，按字逐 token yield `data: {"choices":[{"delta":{"content":"x"}}]}\n\n`，
/// 最后发 `data: [DONE]`。让 AIHttp.postStream 不挂真实 API 也能 demo 字打字机效果。
class MockSseServer {
  HttpServer? _server;

  Future<int> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    return _server!.port;
  }

  Future<void> stop() async => _server?.close(force: true);

  void _handle(HttpRequest req) async {
    // ignore: avoid_print
    print('[mock-sse] ${req.method} ${req.uri.path}');

    if (req.method != 'POST') {
      req.response..statusCode = 405..write('method not allowed');
      await req.response.close();
      return;
    }

    // 读取请求 body，取出最后一条 user message 作为 echo seed
    final bodyBytes = <int>[];
    await for (final chunk in req) {
      bodyBytes.addAll(chunk);
    }
    String userPrompt = 'hello';
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
      final messages = (decoded['messages'] as List?) ?? const [];
      final lastUser = messages.cast<Map<String, dynamic>>().lastWhere(
        (m) => m['role'] == 'user',
        orElse: () => const {'content': 'hello'},
      );
      userPrompt = (lastUser['content'] ?? 'hello').toString();
    } catch (_) {}

    final reply =
        'I received: "$userPrompt". This is a streamed mock reply — '
        'each token arrives one at a time over SSE.';

    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream')
      ..headers.add('Cache-Control', 'no-cache')
      ..headers.add('Connection', 'keep-alive');

    // 按 token 切（这里按字符）
    for (final char in reply.split('')) {
      final chunk = jsonEncode({
        'choices': [
          {
            'delta': {'content': char},
            'index': 0,
          }
        ]
      });
      req.response.write('data: $chunk\n\n');
      await req.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    req.response.write('data: [DONE]\n\n');
    await req.response.flush();
    await req.response.close();
  }
}
