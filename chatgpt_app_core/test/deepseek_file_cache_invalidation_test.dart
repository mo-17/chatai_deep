import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _url = 'https://api.deepseek.com/chat/completions';

Map<String, dynamic> _image([int marker = 1]) => {
      'type': 'image_url',
      'image_url': {
        'url': 'data:image/png;base64,${base64Encode([
              0x89,
              0x50,
              0x4e,
              0x47,
              0x0d,
              0x0a,
              0x1a,
              0x0a,
              marker,
            ])}',
      },
    };

List<Map<String, dynamic>> _messages([List<int> markers = const [1]]) => [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '看图'},
          ...markers.map(_image),
        ],
      },
    ];

http.Response _uploaded(String id) =>
    http.Response(jsonEncode({'object': 'file', 'id': id}), 200);

List<String> _ids(List<Map<String, dynamic>> messages) => [
      for (final part in messages.single['content'] as List)
        if (part['type'] == 'file') part['file_id'] as String,
    ];

DeepSeekAttachmentAdapter _adapter(
  http.Client client, {
  String url = _url,
  String key = 'cache-secret',
}) =>
    DeepSeekAttachmentAdapter(
      chatCompletionsUrl: url,
      apiKey: key,
      client: client,
    );

void _invalidate({
  String url = _url,
  String key = 'cache-secret',
  String id = 'file-api-1',
}) =>
    DeepSeekAttachmentAdapter.invalidateFile(
      chatCompletionsUrl: url,
      apiKey: key,
      fileId: id,
    );

void main() {
  test('已删除 ID 下一次从原始图片重新上传，历史与输入均保持原样', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return _uploaded('file-api-$uploads');
    }));
    final messages = _messages();
    final before = jsonEncode(messages);
    expect(_ids(await adapter.prepareMessages(messages)), ['file-api-1']);
    expect(_ids(await adapter.prepareMessages(messages)), ['file-api-1']);

    _invalidate();

    expect(_ids(await adapter.prepareMessages(messages)), ['file-api-2']);
    expect(uploads, 2);
    expect(jsonEncode(messages), before);
  });

  test('官方根地址、v1 与 beta 的同 key 实例一起失效', () async {
    var uploads = 0;
    final client = MockClient((request) async {
      uploads++;
      return _uploaded(uploads <= 3 ? 'file-api-shared' : 'file-api-$uploads');
    });
    final adapters = [
      for (final url in [
        _url,
        'https://api.deepseek.com/v1/chat/completions',
        'https://api.deepseek.com/beta/chat/completions',
      ])
        _adapter(client, url: url, key: ' shared-secret '),
    ];
    for (final adapter in adapters) {
      expect(_ids(await adapter.prepareMessages(_messages())),
          ['file-api-shared']);
    }

    _invalidate(key: 'shared-secret', id: 'file-api-shared');

    for (final adapter in adapters) {
      expect(_ids(await adapter.prepareMessages(_messages())),
          isNot(['file-api-shared']));
    }
    expect(uploads, 6);
  });

  test('不同 key、主机、协议或代理前缀的缓存不受影响', () async {
    var uploads = 0;
    final client = MockClient((request) async {
      uploads++;
      return _uploaded('file-api-same-id');
    });
    final adapters = [
      _adapter(client, key: 'other-secret'),
      _adapter(client, url: 'https://proxy.example.org/chat/completions'),
      _adapter(client, url: 'http://api.deepseek.com/chat/completions'),
      _adapter(client, url: 'https://api.deepseek.com/custom/chat/completions'),
    ];
    for (final adapter in adapters) {
      await adapter.prepareMessages(_messages());
    }

    _invalidate(id: 'file-api-same-id');

    for (final adapter in adapters) {
      expect(_ids(await adapter.prepareMessages(_messages())),
          ['file-api-same-id']);
    }
    expect(uploads, adapters.length);
  });

  test('仅删除匹配 ID，其他文件缓存继续复用', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return _uploaded('file-api-$uploads');
    }), key: 'selective-secret');
    expect(_ids(await adapter.prepareMessages(_messages([1, 2]))),
        ['file-api-1', 'file-api-2']);

    _invalidate(key: 'selective-secret');

    expect(_ids(await adapter.prepareMessages(_messages([2]))), ['file-api-2']);
    expect(_ids(await adapter.prepareMessages(_messages([1]))), ['file-api-3']);
    expect(uploads, 3);
  });

  test('同 ID 对应多个图片 hash 时全部失效', () async {
    var uploads = 0;
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      return _uploaded('file-api-common');
    }), key: 'multiple-hashes');
    await adapter.prepareMessages(_messages([1, 2]));

    _invalidate(key: 'multiple-hashes', id: 'file-api-common');

    await adapter.prepareMessages(_messages([1, 2]));
    expect(uploads, 4);
  });

  test('删除与上传并发时不返回迟到的已删除 ID，结束后不保留删除记录', () async {
    var uploads = 0;
    final started = Completer<void>();
    final delayed = Completer<http.Response>();
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      if (uploads == 1) {
        started.complete();
        return delayed.future;
      }
      return _uploaded('file-api-late');
    }), key: 'delayed-secret');
    final messages = _messages();
    final before = jsonEncode(messages);
    final preparing = adapter.prepareMessages(messages);
    await started.future;
    _invalidate(key: 'delayed-secret', id: 'file-api-late');
    delayed.complete(_uploaded('file-api-late'));

    await expectLater(preparing, throwsA(isA<DeepSeekFileException>()));
    expect(jsonEncode(messages), before);
    // 假上游再次使用相同 ID，证明删除记录只活在并发准备期间。
    expect(_ids(await adapter.prepareMessages(messages)), ['file-api-late']);
    expect(_ids(await adapter.prepareMessages(messages)), ['file-api-late']);
    expect(uploads, 2);
  });

  test('等待后续图片期间删除已处理图片，请求不能继续使用被删除 ID', () async {
    var uploads = 0;
    final secondStarted = Completer<void>();
    final secondResponse = Completer<http.Response>();
    final adapter = _adapter(MockClient((request) async {
      uploads++;
      if (uploads == 2) {
        secondStarted.complete();
        return secondResponse.future;
      }
      return _uploaded('file-api-$uploads');
    }), key: 'multi-part-secret');
    final messages = _messages([1, 2]);
    final before = jsonEncode(messages);
    final preparing = adapter.prepareMessages(messages);
    await secondStarted.future;
    _invalidate(key: 'multi-part-secret');
    secondResponse.complete(_uploaded('file-api-2'));

    await expectLater(preparing, throwsA(isA<DeepSeekFileException>()));
    expect(jsonEncode(messages), before);
    expect(_ids(await adapter.prepareMessages(messages)),
        ['file-api-3', 'file-api-2']);
    expect(uploads, 3);
  });
}
