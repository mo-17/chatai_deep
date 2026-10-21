@TestOn('browser')
library;

import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/chat/application/import_operation.dart';
import 'package:chatgpt_app_core/chat/application/server_ocr_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final base = Uri.parse(const String.fromEnvironment('OCR_TEST_BASE',
      defaultValue: 'http://127.0.0.1:48353/'));
  setUp(() async {
    expect((await http.delete(base.resolve('events'))).statusCode, 200);
  });
  Future<List<dynamic>> events() async =>
      ((jsonDecode((await http.get(base.resolve('events'))).body)
          as Map)['data'] as Map)['events'] as List;
  ServerOcrClient client() => ServerOcrClient(
      base: base.resolve('uapi/ocr/'),
      headers: {'Authorization': 'Bearer browser-test'},
      isCurrent: () => true,
      pollInterval: const Duration(milliseconds: 10));

  test('真实 Chrome HTTP 上传不可变快照、轮询 UTF8 结果并删除任务', () async {
    final source = Uint8List.fromList([1, 2, 3]);
    final result = client().recognizeBytes(source, pdf: false);
    source[0] = 9;
    expect((await result).text, '浏览器 OCR 合同验证');
    final recorded = await events();
    expect(recorded.map((e) => e['method']), ['POST', 'GET', 'DELETE']);
    expect(recorded.first['sha256'], sha256.convert([1, 2, 3]).toString());
    expect(recorded.first['size'], 3);
  });

  test('真实 Chrome 排队等待可取消并发送 DELETE', () async {
    final operation = ImportCancellation();
    await expectLater(
        client().recognizeBytes(Uint8List.fromList(utf8.encode('hold')),
            pdf: false, cancellation: operation, onProgress: (stage, _, __) {
          if (stage == '服务器排队中') operation.cancel();
        }),
        throwsA(isA<ImportCancelled>()));
    final recorded = await events();
    expect(recorded.first['method'], 'POST');
    expect(recorded.last['method'], 'DELETE');
  });
  test('校对请求按需取回坐标、置信度与缩略图字节', () async {
    final result = await client().recognizeBytes(Uint8List.fromList([1, 2, 3]),
        pdf: false, includePreview: true);
    expect(result.detailFor(1)!.lines.single.needsReview, true);
    expect(result.detailFor(1)!.lines.single.box.last, [1, 20]);
    expect(result.detailFor(1)!.preview, [255, 216, 255, 0]);
    expect((await events()).first['preview'], true);
  });

  test('真实 Chrome 上传响应等待中可中断，取消标记阻止迟到任务', () async {
    final operation = ImportCancellation();
    Timer? timer;
    try {
      await expectLater(
          client().recognizeBytes(Uint8List.fromList(utf8.encode('delayed')),
              pdf: false, cancellation: operation, onProgress: (stage, _, __) {
            if (stage == '正在上传至服务器') {
              timer =
                  Timer(const Duration(milliseconds: 100), operation.cancel);
            }
          }),
          throwsA(isA<ImportCancelled>()));
      // 等待服务端模拟的迟到上传结算，再检查取消标记未被覆盖。
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final recorded = await events();
      expect(recorded.first['method'], 'DELETE');
      expect(recorded.last['method'], 'POST');
      expect(recorded.last['rejected'], true);
      expect(recorded.first['id'], recorded.last['id']);
    } finally {
      timer?.cancel();
    }
  });
}
