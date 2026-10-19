import 'dart:async';
import 'package:chatgpt_app_core/chat/application/ohos_ocr.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hzb.flutter_ai/ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('图片和 PDF 向原生请求不同类型且使用独立 ID', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return '  识别正文  ';
    });
    const ocr = OhosOcr();
    expect(await ocr.image('/cache/图片.png'), '识别正文');
    expect(await ocr.pdf('/files/扫描.pdf', maxPages: 20), '识别正文');
    expect(calls[0].arguments['kind'], 'image');
    expect(calls[0].arguments['maxPages'], 1);
    expect(calls[1].arguments['kind'], 'pdf');
    expect(calls[1].arguments['maxPages'], 20);
    expect(calls[0].arguments['id'], isNot(calls[1].arguments['id']));
  });

  test('无文字是空串，服务异常、无效返回和过大返回不会伪装为空', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => '');
    expect(await const OhosOcr().image('/cache/a.png'), '');
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(
        const OhosOcr().image('/cache/a.png'), throwsFormatException);
    messenger.setMockMethodCallHandler(channel, (call) async => 'a' * 1000001);
    await expectLater(
        const OhosOcr().image('/cache/a.png'), throwsFormatException);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'ocr_error');
    });
    await expectLater(
        const OhosOcr().pdf('/cache/a.pdf'), throwsA(isA<PlatformException>()));
  });

  test('超时取消准确的请求，迟到结果不成为识别成功', () async {
    final pending = Completer<String>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'cancel') return null;
      return pending.future;
    });
    const ocr = OhosOcr(timeout: Duration(milliseconds: 10));
    await expectLater(
        ocr.image('/cache/a.png'), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['recognize', 'cancel']);
    expect(calls.last.arguments['id'], calls.first.arguments['id']);
    pending.complete('迟到正文');
  });

  test('拒绝非本机文件路径和超出 PDF 页数预算的请求', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return '';
    });
    await expectLater(
        const OhosOcr().image('https://host/a.png'), throwsArgumentError);
    expect(() => const OhosOcr().pdf('/cache/a.pdf', maxPages: 21),
        throwsRangeError);
    expect(() => const OhosOcr().pdf('/cache/a.pdf', maxPages: 0),
        throwsRangeError);
    expect(called, false);
  });
}
