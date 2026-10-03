import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3];
String _imageData(List<int> bytes, {String mime = 'image/png'}) =>
    'data:$mime;base64,${base64Encode(bytes)}';

http.Response _uploaded({String id = 'file-api-test'}) => http.Response(
      jsonEncode({'object': 'file', 'id': id, 'purpose': 'user_data'}),
      200,
    );

DeepSeekFileService _service(http.Client client,
        {String key = 'test-secret',
        Duration timeout = const Duration(seconds: 90)}) =>
    DeepSeekFileService(
      chatCompletionsUrl: 'https://api.deepseek.com/v1/chat/completions',
      apiKey: key,
      client: client,
      timeout: timeout,
    );

void main() {
  test('文件端点使用官方 root，保留自定义代理的路径前缀', () {
    for (final base in ['', '/v1', '/beta']) {
      expect(
        DeepSeekFileService.filesEndpointFor(
                'https://api.deepseek.com$base/chat/completions')
            .toString(),
        'https://api.deepseek.com/files',
      );
    }
    expect(
      DeepSeekFileService.filesEndpointFor(
              'https://proxy.example/deepseek/v1/chat/completions')
          .toString(),
      'https://proxy.example/deepseek/v1/files',
    );
    for (final url in [
      '',
      'ftp://api.deepseek.com/chat/completions',
      'https://user:password@api.deepseek.com/chat/completions',
      'https://api.deepseek.com/chat/completions?key=secret',
      'https://api.deepseek.com/chat/completions#fragment',
    ]) {
      expect(() => DeepSeekFileService.filesEndpointFor(url),
          throwsFormatException);
    }
  });

  test('按字节识别四种图片格式，拒绝 PDF 和空内容', () {
    expect(DeepSeekFileService.imageMimeForBytes(_png), 'image/png');
    expect(DeepSeekFileService.imageMimeForBytes([0xff, 0xd8, 0xff, 0xe0]),
        'image/jpeg');
    for (final gif in ['GIF87a', 'GIF89a']) {
      expect(DeepSeekFileService.imageMimeForBytes(ascii.encode(gif)),
          'image/gif');
    }
    expect(
      DeepSeekFileService.imageMimeForBytes([
        ...ascii.encode('RIFF'),
        0,
        0,
        0,
        0,
        ...ascii.encode('WEBP'),
      ]),
      'image/webp',
    );
    expect(DeepSeekFileService.imageMimeForBytes(ascii.encode('%PDF-1.7')),
        isNull);
    expect(DeepSeekFileService.imageMimeForBytes([]), isNull);
  });

  test('multipart 使用 Bearer、user_data 和 file，并关闭重定向', () async {
    final client = _CallbackClient((request) async {
      expect(request, isA<http.AbortableMultipartRequest>());
      expect(request.followRedirects, isFalse);
      expect(request.url.toString(), 'https://api.deepseek.com/files');
      expect(request.headers['Authorization'], 'Bearer test-secret');
      final multipart = request as http.MultipartRequest;
      expect(multipart.fields, {'purpose': 'user_data'});
      expect(multipart.files.single.field, 'file');
      expect(multipart.files.single.filename, 'safe.png');
      expect(await multipart.files.single.finalize().toBytes(), _png);
      return http.StreamedResponse(
          Stream.value(utf8.encode(_uploaded().body)), 200);
    });
    final result = await _service(client).uploadImageDataUri(
      _imageData(_png, mime: 'image/jpeg'),
      filename: '/private/path/safe.png',
    );
    expect(result.id, 'file-api-test');
    expect(result.mime, 'image/png');
    expect(result.filename, 'safe.png');
    expect(result.bytes, _png.length);
    expect(client.closed, isFalse, reason: '注入的 client 由调用方管理');
  });

  test('本地图片根据实际内容上传，扩展名不影响格式识别', () async {
    final directory = await Directory.systemTemp.createTemp('deepseek-image-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/misleading.pdf');
    await file.writeAsBytes(_png);
    final client = MockClient((request) async => _uploaded());
    final result = await _service(client).uploadImage(file.path);
    expect(result.mime, 'image/png');
  });

  test('64 MiB 文件上限在读取和发请求前检查', () async {
    final directory = await Directory.systemTemp.createTemp('deepseek-limit-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/huge.png');
    final opened = await file.open(mode: FileMode.write);
    await opened.truncate(DeepSeekFileService.maxImageBytes + 1);
    await opened.close();
    var sent = false;
    final client = MockClient((request) async {
      sent = true;
      return _uploaded();
    });
    await expectLater(
        _service(client).uploadImage(file.path), throwsFormatException);
    expect(sent, isFalse);
  });

  test('未配置 key、无效 base64、PDF 内容均不会发送', () async {
    var sent = false;
    final client = MockClient((request) async {
      sent = true;
      return _uploaded();
    });
    await expectLater(
      _service(client, key: '').uploadImageDataUri(_imageData(_png)),
      throwsA(isA<DeepSeekFileException>()),
    );
    for (final data in [
      'data:image/png;base64,???',
      'data:image/png,raw',
      _imageData(ascii.encode('%PDF-1.7')),
    ]) {
      await expectLater(
          _service(client).uploadImageDataUri(data), throwsFormatException);
    }
    expect(sent, isFalse);
  });

  test('错误响应正文和底层网络异常不会泄露 key 或文件正文', () async {
    for (final status in [302, 401, 413, 429, 500]) {
      final service = _service(MockClient((request) async =>
          http.Response('echo test-secret ${_imageData(_png)}', status)));
      try {
        await service.uploadImageDataUri(_imageData(_png));
        fail('应报告上传失败');
      } on DeepSeekFileException catch (error) {
        expect(error.toString(), isNot(contains('test-secret')));
        expect(error.toString(), isNot(contains('base64')));
      }
    }
    final network = _service(MockClient((request) async {
      throw http.ClientException('echo test-secret');
    }));
    await expectLater(
      network.uploadImageDataUri(_imageData(_png)),
      throwsA(isA<DeepSeekFileException>().having(
          (e) => e.message, 'sanitized', isNot(contains('test-secret')))),
    );
  });

  test('拒绝不合法的 file_id、JSON 和超预算响应', () async {
    for (final body in [
      _uploaded(id: 'file-not-deepseek').body,
      'not-json',
      jsonEncode({'object': 'chat.completion', 'id': 'file-api-test'}),
      'x' * (256 * 1024 + 1),
    ]) {
      await expectLater(
        _service(MockClient((request) async => http.Response(body, 200)))
            .uploadImageDataUri(_imageData(_png)),
        throwsA(isA<DeepSeekFileException>()),
      );
    }
  });

  test('超时会完成上传请求的 abortTrigger', () async {
    Future<void>? aborted;
    final client = _CallbackClient((request) {
      aborted = (request as http.Abortable).abortTrigger;
      return Completer<http.StreamedResponse>().future;
    });
    await expectLater(
      _service(client, timeout: const Duration(milliseconds: 10))
          .uploadImageDataUri(_imageData(_png)),
      throwsA(isA<DeepSeekFileException>()
          .having((e) => e.message, 'timeout', contains('超时'))),
    );
    await expectLater(aborted, completes);
  });

  test('调用方取消保持 RequestAbortedException，供对话识别取消', () async {
    final abort = Completer<void>();
    final client = _CallbackClient((request) async {
      await (request as http.Abortable).abortTrigger;
      throw http.RequestAbortedException(request.url);
    });
    final uploading = _service(client)
        .uploadImageDataUri(_imageData(_png), abortTrigger: abort.future);
    abort.complete();
    await expectLater(uploading, throwsA(isA<http.RequestAbortedException>()));
  });

  test('已取消的请求在读取本地文件和发送前终止', () async {
    final abort = Completer<void>()..complete();
    final service = _service(MockClient((request) async {
      fail('已取消的请求不应上传');
    }));
    await expectLater(
      service.uploadImage('/不存在的文件.png', abortTrigger: abort.future),
      throwsA(isA<http.RequestAbortedException>()),
    );
    await expectLater(
      service.uploadImageDataUri('invalid data', abortTrigger: abort.future),
      throwsA(isA<http.RequestAbortedException>()),
    );
  });
}

class _CallbackClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) callback;
  bool closed = false;

  _CallbackClient(this.callback);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      callback(request);

  @override
  void close() => closed = true;
}
