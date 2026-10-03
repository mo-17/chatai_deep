import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3];
String _data({String mime = 'image/png'}) =>
    'data:$mime;base64,${base64Encode(_png)}';

DeepSeekAttachmentAdapter _adapter(http.Client client) =>
    DeepSeekAttachmentAdapter(
      chatCompletionsUrl: 'https://api.deepseek.com/v1/chat/completions',
      apiKey: 'test-secret',
      client: client,
    );

Map<String, dynamic> _image(String url) => {
      'type': 'image_url',
      'image_url': {'url': url, 'detail': 'high'},
    };

void main() {
  test('图片和图片文件统一上传为平铺 file_id，输入与历史保持原样', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return http.Response(
          jsonEncode({'object': 'file', 'id': 'file-api-$uploads'}), 200);
    }));
    final input = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'system'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '看图'},
          _image(_data()),
          {
            'type': 'file',
            'file': {'file_data': _data(), 'filename': '附件.png'},
          },
          {'type': 'file', 'file_data': _data(), 'filename': '平铺.png'},
        ],
      },
      {'role': 'assistant', 'content': 'answer'},
      {
        'role': 'tool',
        'tool_call_id': 'tool-1',
        'content': [_image(_data())],
      },
    ];
    final before = jsonEncode(input);
    final output = await adapter.prepareMessages(input);
    expect(uploads, 1, reason: '相同图片在同一请求中复用文件 ID');
    expect(jsonEncode(input), before);
    expect(output[0], input[0]);
    expect(output[2], input[2]);
    expect(output[3], input[3]);
    final parts = output[1]['content'] as List;
    expect(parts.first, {'type': 'text', 'text': '看图'});
    for (final part in parts.skip(1)) {
      expect(part, {'type': 'file', 'file_id': 'file-api-1'});
    }
  });

  test('多轮和工具循环复用图片字节的 hash，不依赖 data URI MIME', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return http.Response(
          jsonEncode({'object': 'file', 'id': 'file-api-$uploads'}), 200);
    }));
    for (final mime in ['image/png', 'image/jpeg', 'image/webp']) {
      final output = await adapter.prepareMessages([
        {
          'role': 'user',
          'content': [_image(_data(mime: mime))],
        },
      ]);
      expect(output.single['content'], [
        {'type': 'file', 'file_id': 'file-api-1'},
      ]);
    }
    expect(uploads, 1);
  });

  test('失败上传不会写 cache，下一次发送会重试', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return uploads == 1
          ? http.Response('failed', 500)
          : http.Response(
              jsonEncode({'object': 'file', 'id': 'file-api-retry'}), 200);
    }));
    final input = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [_image(_data())],
      },
    ];
    await expectLater(adapter.prepareMessages(input), throwsException);
    final output = await adapter.prepareMessages(input);
    expect(uploads, 2);
    expect(output.single['content'], [
      {'type': 'file', 'file_id': 'file-api-retry'},
    ]);
  });

  test('远程图片 URL 和已有 file_id 保持语义，并检查 URL 上限', () async {
    final adapter = _adapter(MockClient((request) async {
      fail('远程 URL 与已上传 file_id 不需要上传');
    }));
    final remote = _image('https://example.org/photo.png');
    final output = await adapter.prepareMessages([
      {
        'role': 'user',
        'content': [
          remote,
          {
            'type': 'file',
            'file': {'file_id': 'file-api-existing'},
          },
        ],
      },
    ]);
    expect(output.single['content'], [
      remote,
      {'type': 'file', 'file_id': 'file-api-existing'},
    ]);
    for (final url in [
      'https://example.org/${'x' * 8192}',
      'file:///private/image.png',
    ]) {
      await expectLater(
        adapter.prepareMessages([
          {
            'role': 'user',
            'content': [_image(url)],
          },
        ]),
        throwsFormatException,
      );
    }
  });

  test('拒绝 PDF file_data，继续由现有正文抽取链路处理 PDF', () async {
    final adapter = _adapter(MockClient((request) async {
      fail('PDF 不应调用图片 Files API');
    }));
    await expectLater(
      adapter.prepareMessages([
        {
          'role': 'user',
          'content': [
            {
              'type': 'file',
              'file': {
                'file_data': 'data:application/pdf;base64,JVBERi0x',
                'filename': 'doc.pdf',
              },
            },
          ],
        },
      ]),
      throwsFormatException,
    );
  });

  test('服务实例的 cache 按 key / host 隔离', () async {
    var uploads = 0;
    final client = MockClient((request) async {
      uploads++;
      return http.Response(
          jsonEncode({'object': 'file', 'id': 'file-api-$uploads'}), 200);
    });
    final input = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [_image(_data())],
      },
    ];
    await _adapter(client).prepareMessages(input);
    await _adapter(client).prepareMessages(input);
    expect(uploads, 2);
  });

  test('缓存命中和纯文本路径也会在已取消时终止', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return http.Response(
          jsonEncode({'object': 'file', 'id': 'file-api-cached'}), 200);
    }));
    final messages = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [_image(_data())],
      },
    ];
    await adapter.prepareMessages(messages);
    final abort = Completer<void>()..complete();
    await expectLater(
      adapter.prepareMessages(messages, abortTrigger: abort.future),
      throwsA(isA<http.RequestAbortedException>()),
    );
    await expectLater(
      adapter.prepareMessages([
        {'role': 'user', 'content': 'text'},
      ], abortTrigger: abort.future),
      throwsA(isA<http.RequestAbortedException>()),
    );
    expect(uploads, 1);
  });
}
