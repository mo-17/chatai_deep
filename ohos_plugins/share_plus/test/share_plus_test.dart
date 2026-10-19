import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hzb.flutter_ai/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('文本分享按原生结果区分完成、取消和未知状态', () async {
    for (final pair in {
      'success': ShareResultStatus.success,
      'dismissed': ShareResultStatus.dismissed,
      'unknown': ShareResultStatus.unavailable,
    }.entries) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.arguments['text'], '分享正文');
        return pair.key;
      });
      expect(
        (await SharePlus.instance.share(
          const ShareParams(text: '分享正文'),
        )).status,
        pair.value,
      );
    }
  });
  test('文件分享传本机路径和文件名，不经通道复制整个文件', () async {
    final dir = await Directory.systemTemp.createTemp('ohos-share-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/报告.txt').writeAsString('hello');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['files'], [
        {'path': file.path, 'name': '报告.txt'},
      ]);
      return 'success';
    });
    expect(
      (await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)]),
      )).status,
      ShareResultStatus.success,
    );
  });
  test('无内容和超大内容在打开面板前拒绝，系统错误不能返回成功', () async {
    await expectLater(
      SharePlus.instance.share(const ShareParams()),
      throwsArgumentError,
    );
    await expectLater(
      SharePlus.instance.share(ShareParams(text: 'a' * 100001)),
      throwsArgumentError,
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'not_available'),
    );
    await expectLater(
      SharePlus.instance.share(const ShareParams(text: 'a')),
      throwsA(isA<PlatformException>()),
    );
  });
}
