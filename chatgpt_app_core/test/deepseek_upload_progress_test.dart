import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final class _UploadClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;
  _UploadClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  Uint8List image([int suffix = 0]) => Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        suffix,
        ...List<int>.filled(150000, 0),
      ]);
  http.StreamedResponse success(String id) => http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'object': 'file', 'id': id}))), 200);

  test('字节被消费后切换等待确认，服务确认前不报告成功', () async {
    final consumed = Completer<void>();
    final acknowledge = Completer<void>();
    final progress = <ChatSendProgress>[];
    var saved = false;
    final bytes = image();
    final service = DeepSeekFileService(
      chatCompletionsUrl: 'https://api.deepseek.com/v1/chat/completions',
      apiKey: 'key',
      client: _UploadClient((request) async {
        await request.finalize().drain<void>();
        consumed.complete();
        await acknowledge.future;
        return success('file-api-confirmed');
      }),
      onUploaded: (_, __) async => saved = true,
    );
    final uploaded = service.uploadImageBytes(bytes, onProgress: progress.add);
    await consumed.future;
    expect(progress.first.completedBytes, 0);
    expect(progress.where((p) => p.completedBytes != null).last.completedBytes,
        bytes.length);
    expect(progress.last.label, '等待图片上传确认');
    expect(progress.last.fraction, isNull);
    expect(saved, isFalse);
    acknowledge.complete();
    expect((await uploaded).id, 'file-api-confirmed');
    expect(saved, isTrue);
  });

  test('多图进度包含历史附件序号，重试复用成功上传缓存且不改历史', () async {
    var uploads = 0;
    final adapter = DeepSeekAttachmentAdapter(
      chatCompletionsUrl: 'https://api.deepseek.com/chat/completions',
      apiKey: 'key',
      client: _UploadClient((request) async {
        await request.finalize().drain<void>();
        uploads++;
        return success('file-api-$uploads');
      }),
    );
    final messages = [
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/png;base64,${base64Encode(image(1))}'
            }
          }
        ]
      },
      {'role': 'assistant', 'content': 'old answer'},
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/png;base64,${base64Encode(image(2))}'
            }
          }
        ]
      },
    ];
    final original = jsonEncode(messages);
    final progress = <ChatSendProgress>[];
    final first =
        await adapter.prepareMessages(messages, onProgress: progress.add);
    expect(uploads, 2);
    expect(progress.map((p) => p.total), everyElement(2));
    expect(progress.map((p) => p.index).toSet(), {1, 2});
    progress.clear();
    final second =
        await adapter.prepareMessages(messages, onProgress: progress.add);
    expect(uploads, 2);
    expect(progress, isEmpty);
    expect(second, first);
    expect(jsonEncode(messages), original);
  });

  test('上传失败仍等待服务确认，不建立预览缓存且展示异常不掩盖上传结果', () async {
    var saved = false;
    final service = DeepSeekFileService(
      chatCompletionsUrl: 'https://api.deepseek.com/chat/completions',
      apiKey: 'key',
      client: _UploadClient((request) async {
        await request.finalize().drain<void>();
        return http.StreamedResponse(
            Stream.value(utf8.encode('secret-key')), 401);
      }),
      onUploaded: (_, __) async => saved = true,
    );
    await expectLater(
        service.uploadImageBytes(image(),
            onProgress: (_) => throw StateError('disposed')),
        throwsA(isA<DeepSeekFileException>()
            .having((e) => e.message, 'message', contains('鉴权失败'))));
    expect(saved, isFalse);
  });
}
