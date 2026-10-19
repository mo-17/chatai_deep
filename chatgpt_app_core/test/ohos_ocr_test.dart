import 'dart:async';
import 'package:chatgpt_app_core/chat/application/ohos_ocr.dart';
import 'package:chatgpt_app_core/chat/application/import_operation.dart';
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

  test('分页结果保留空白位置并传递指定页码，全文接口标注截断', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['kind'], 'pdfPages');
      expect(call.arguments['pageNumbers'], [2, 4]);
      return {
        'totalPages': 5,
        'pages': ['', ' 第二页 ', '', '第四页']
      };
    });
    final result = await const OhosOcr()
        .pdfPages('/cache/mixed.pdf', maxPages: 4, pageNumbers: [2, 4]);
    expect(result.totalPages, 5);
    expect(result.pages, ['', '第二页', '', '第四页']);
    expect(result.text, contains('原文共 5 页，仅 OCR 前 4 页'));
  });

  test('分页协议拒绝少页、类型错误、超限和未请求的内容', () async {
    for (final value in [
      null,
      {
        'totalPages': 2,
        'pages': ['一页']
      },
      {'totalPages': 0, 'pages': []},
      {
        'totalPages': 2,
        'pages': ['', 2]
      },
      {
        'totalPages': 2,
        'pages': ['未请求的页', '第二页']
      },
      {
        'totalPages': 2,
        'pages': ['', 'x' * 1000001]
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => value);
      await expectLater(
          const OhosOcr().pdfPages('/cache/a.pdf', pageNumbers: [2]),
          throwsFormatException);
    }
    for (final pages in [
      <int>[],
      [0],
      [21],
      [1, 1]
    ]) {
      await expectLater(
          const OhosOcr().pdfPages('/cache/a.pdf', pageNumbers: pages),
          throwsArgumentError);
    }
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
  test('主动取消按 ID 通知原生，迟到分页结果不能作为成功', () async {
    final pending = Completer<Object?>();
    final started = Completer<void>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'cancel') return null;
      started.complete();
      return pending.future;
    });
    final cancellation = ImportCancellation();
    final result =
        const OhosOcr().pdfPages('/cache/scan.pdf', cancellation: cancellation);
    final expectation = expectLater(result, throwsA(isA<ImportCancelled>()));
    await started.future;
    cancellation.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['recognize', 'cancel']);
    expect(calls.last.arguments['id'], calls.first.arguments['id']);
    pending.complete({
      'totalPages': 1,
      'pages': ['late']
    });
    await expectation;
  });

  test('分页进度只派发给当前请求，丢弃无效和结束后的事件', () async {
    final pending = Completer<Object?>();
    final started = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['reportProgress'], true);
      started.complete(call.arguments['id'] as String);
      return pending.future;
    });
    final progress = <List<int>>[];
    final result = const OhosOcr().pdfPages('/cache/scan.pdf',
        onProgress: (page, total) => progress.add([page, total]));
    final id = await started.future;
    Future<void> send(Object args) async {
      final reply = Completer<void>();
      ServicesBinding.instance.channelBuffers.push(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall('progress', args)),
          (_) => reply.complete());
      await reply.future;
    }

    await send({'id': 'other', 'page': 1, 'total': 2});
    await send({'id': id, 'page': 0, 'total': 2});
    await send({'id': id, 'page': 3, 'total': 2});
    await send({'id': id, 'page': 1, 'total': 21});
    await send({'id': id, 'page': '1', 'total': 2});
    await send({'id': id, 'page': 1, 'total': 2});
    expect(progress, [
      [1, 2]
    ]);
    pending.complete({
      'totalPages': 2,
      'pages': ['第一页', '第二页']
    });
    await result;
    await send({'id': id, 'page': 2, 'total': 2});
    expect(progress, [
      [1, 2]
    ]);
  });
}
