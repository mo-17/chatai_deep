@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/http/ai_exception.dart';
import 'package:openai_flutter/http/ai_http.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

// 配合 chatgpt_flutter/tool/web/smoke_server.py，仅连接本机假服务，无真实密钥。
void main() {
  const endpoint = String.fromEnvironment('WEB_SMOKE_URL',
      defaultValue: 'http://127.0.0.1:48352/v1/chat/completions');
  final config = AIConfigBuilder(apiKey: 'browser-test', chatUrl: endpoint);

  test('BrowserClient 跨域流式解析中文、推理、工具和 usage', () async {
    final events = await AIHttp.postStreamEvents(
        config: config,
        url: endpoint,
        body: {'model': 'web-stream', 'stream': true}).toList();
    expect(
        events
            .where((e) => e.kind == AIStreamKind.content)
            .map((e) => e.text)
            .join(),
        '浏览器流式成功');
    expect(events.first.kind, AIStreamKind.reasoning);
    final tool = events.singleWhere((e) => e.kind == AIStreamKind.toolCall);
    expect(tool.toolName, 'calculator');
    expect(tool.toolArgsDelta, '{"expression":"1+1"}');
    expect(events.last.promptTokens, 9);
    expect(events.last.completionTokens, 5);
  });

  test('BrowserClient 在服务端结束前交付首段，取消会中止读取', () async {
    final abort = Completer<void>();
    final first = Completer<void>();
    final result = AIHttp.postStreamEvents(
            config: config,
            url: endpoint,
            body: {'model': 'web-hold', 'stream': true},
            abortTrigger: abort.future)
        .map((event) {
      if (!first.isCompleted) first.complete();
      return event;
    }).toList();
    final failure =
        expectLater(result, throwsA(isA<AIRequestCancelledException>()));
    try {
      await first.future.timeout(const Duration(seconds: 4));
    } finally {
      abort.complete();
    }
    await failure;
  });

  test('BrowserClient 连接超时和非 2xx 保持异常契约', () async {
    await expectLater(
        AIHttp.postStreamEvents(
                config: config,
                url: endpoint,
                body: {'model': 'web-delay'},
                connectTimeout: const Duration(milliseconds: 150))
            .toList(),
        throwsA(isA<TimeoutException>()));
    await expectLater(
        AIHttp.postStreamEvents(
            config: config,
            url: endpoint,
            body: {'model': 'web-error'}).toList(),
        throwsA(isA<AIRequestException>()
            .having((e) => e.statusCode, 'HTTP status', 429)));
  });
}
