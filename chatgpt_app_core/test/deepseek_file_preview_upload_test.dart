import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_preview_store.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _chat = 'https://api.deepseek.com/v1/chat/completions';
const _account = 'upload-account';
const _key = 'upload-key';

Future<Uint8List> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 40, 20),
      ui.Paint()..color = const ui.Color(0xff1122ff));
  final picture = recorder.endRecording();
  final image = await picture.toImage(40, 20);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DeepSeekFilePreviewStore store;
  late Uint8List image;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('deepseek-upload-preview-');
    store = DeepSeekFilePreviewStore(rootDirectory: () async => root);
    image = await _image();
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> remember(DeepSeekUploadedFile file, Uint8List bytes) =>
      store.save(
          accountHash: _account,
          chatCompletionsUrl: _chat,
          apiKey: _key,
          fileId: file.id,
          bytes: bytes);
  Future<Uint8List?> preview(String id) => store.read(
      accountHash: _account,
      chatCompletionsUrl: _chat,
      apiKey: _key,
      fileId: id);

  test('真实上传响应建立 ID 到准确图片的本地映射，跨轮复用不重复上传', () async {
    var requests = 0;
    final adapter = DeepSeekAttachmentAdapter(
      chatCompletionsUrl: _chat,
      apiKey: _key,
      client: MockClient((request) async {
        requests++;
        return http.Response(
            jsonEncode({'object': 'file', 'id': 'file-api-uploaded'}), 200);
      }),
      onUploaded: remember,
    );
    final messages = [
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${base64Encode(image)}'}
          }
        ]
      }
    ];
    final first = await adapter.prepareMessages(messages);
    final second = await adapter.prepareMessages(messages);
    expect(first.first['content'], [
      {'type': 'file', 'file_id': 'file-api-uploaded'}
    ]);
    expect(second, first);
    expect(requests, 1);
    final bytes = (await preview('file-api-uploaded'))!;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect([frame.image.width, frame.image.height], [40, 20]);
    final pixels = (await frame.image.toByteData())!.buffer.asUint8List();
    expect(pixels.take(4), [0x11, 0x22, 0xff, 0xff]);
    frame.image.dispose();
    codec.dispose();
  });

  test('上传失败或返回无效 ID 时不触发缓存回调', () async {
    var callbacks = 0;
    for (final response in [
      http.Response('failure', 503),
      http.Response(jsonEncode({'object': 'file', 'id': 'bad-id'}), 200),
      http.Response(jsonEncode({'object': 'other', 'id': 'file-api-bad'}), 200),
    ]) {
      final service = DeepSeekFileService(
        chatCompletionsUrl: _chat,
        apiKey: _key,
        client: MockClient((request) async => response),
        onUploaded: (file, bytes) async {
          callbacks++;
          await remember(file, bytes);
        },
      );
      await expectLater(service.uploadImageBytes(image),
          throwsA(isA<DeepSeekFileException>()));
    }
    expect(callbacks, 0);
    expect(await root.list().length, 0);
  });

  test('缓存回调失败保持上传成功，没有回调的服务不会写缓存', () async {
    final client = MockClient((request) async => http.Response(
        jsonEncode({'object': 'file', 'id': 'file-api-valid'}), 200));
    final failing = DeepSeekFileService(
      chatCompletionsUrl: _chat,
      apiKey: _key,
      client: client,
      onUploaded: (file, bytes) async {
        throw const FileSystemException('no cache permission');
      },
    );
    expect((await failing.uploadImageBytes(image)).id, 'file-api-valid');
    final noCache = DeepSeekFileService(
        chatCompletionsUrl: _chat, apiKey: _key, client: client);
    expect((await noCache.uploadImageBytes(image)).id, 'file-api-valid');
    expect(await root.list().length, 0);
  });

  test('上传响应迟到时删除 tombstone 阻止预览回调重新保存', () async {
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    var callbacks = 0;
    final adapter = DeepSeekAttachmentAdapter(
      chatCompletionsUrl: _chat,
      apiKey: _key,
      client: MockClient((request) {
        requested.complete();
        return response.future;
      }),
      onUploaded: (file, bytes) async {
        callbacks++;
        await remember(file, bytes);
      },
    );
    final preparing = adapter.prepareMessages([
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${base64Encode(image)}'}
          }
        ]
      }
    ]);
    await requested.future;
    final failed =
        expectLater(preparing, throwsA(isA<DeepSeekFileException>()));
    DeepSeekAttachmentAdapter.invalidateFile(
        chatCompletionsUrl: _chat, apiKey: _key, fileId: 'file-api-late');
    response.complete(http.Response(
        jsonEncode({'object': 'file', 'id': 'file-api-late'}), 200));
    await failed;
    expect(callbacks, 0);
    expect(await preview('file-api-late'), isNull);
  });

  test('成功上传后的缓存回调排队期间删除，不会重新落盘相同 ID', () async {
    final remembering = Completer<void>();
    final release = Completer<void>();
    late DeepSeekAttachmentAdapter adapter;
    adapter = DeepSeekAttachmentAdapter(
      chatCompletionsUrl: _chat,
      apiKey: _key,
      client: MockClient((request) async => http.Response(
          jsonEncode({'object': 'file', 'id': 'file-api-delayed-cache'}), 200)),
      onUploaded: (file, bytes) async {
        remembering.complete();
        await release.future;
        await store.save(
            accountHash: _account,
            chatCompletionsUrl: _chat,
            apiKey: _key,
            fileId: file.id,
            bytes: bytes,
            shouldSave: () => !adapter.isFileDeleted(file.id));
      },
    );
    final preparing = adapter.prepareMessages([
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${base64Encode(image)}'}
          }
        ]
      }
    ]);
    await remembering.future;
    final failed =
        expectLater(preparing, throwsA(isA<DeepSeekFileException>()));
    DeepSeekAttachmentAdapter.invalidateFile(
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: 'file-api-delayed-cache');
    await store.remove(
        accountHash: _account,
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: 'file-api-delayed-cache');
    release.complete();
    await failed;
    expect(await preview('file-api-delayed-cache'), isNull);
    expect(await root.list().length, 0);
  });
}
