import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hzb.flutter_ai/file_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('系统取消与原生错误分别处理', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await FilePicker.pickFiles(), isNull);
    expect(await FilePicker.saveFile(bytes: Uint8List(0)), isNull);
    messenger.setMockMethodCallHandler(channel,
        (_) async => throw PlatformException(code: 'permission_denied'));
    await expectLater(
        FilePicker.pickFiles(), throwsA(isA<PlatformException>()));
    await expectLater(FilePicker.saveFile(bytes: Uint8List(0)),
        throwsA(isA<PlatformException>()));
  });

  test('导入缓存副本支持 path 与实际 bytes，扩展名和多选传给原生', () async {
    final directory = await Directory.systemTemp.createTemp('ohos-picker-test');
    addTearDown(() => directory.delete(recursive: true));
    final file =
        await File('${directory.path}/note.txt').writeAsBytes([1, 2, 3]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickFiles');
      expect(call.arguments['allowedExtensions'], ['txt']);
      expect(call.arguments['allowMultiple'], true);
      return [
        {'path': file.path, 'name': 'note.txt', 'size': 3}
      ];
    });
    final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['TXT', 'txt'],
        allowMultiple: true,
        withData: true);
    expect(result!.files.single.bytes, [1, 2, 3]);
    expect(result.files.single.path, file.path);
    expect(result.files.single.size, 3);
    final pathsOnly = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['txt'], allowMultiple: true);
    expect(pathsOnly!.files.single.bytes, isNull);
  });

  test('保存只传一次 bytes，返回 URI 不进行 Dart 文件写入', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'saveFile');
      expect(call.arguments['bytes'], [4, 5]);
      expect(call.arguments['fileName'], 'backup.zip');
      return 'file://docs/storage/backup.zip';
    });
    expect(
        await FilePicker.saveFile(
            fileName: 'backup.zip', bytes: Uint8List.fromList([4, 5])),
        'file://docs/storage/backup.zip');
    expect(calls, 1);
  });

  test('无效扩展名和缺失 bytes 在打开选择器前拒绝', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => fail('不应访问原生'));
    expect(() => FilePicker.saveFile(), throwsArgumentError);
    expect(
        () => FilePicker.saveFile(
            type: FileType.custom,
            allowedExtensions: ['../zip'],
            bytes: Uint8List(0)),
        throwsArgumentError);
    await expectLater(
        FilePicker.pickFiles(type: FileType.custom), throwsArgumentError);
    await expectLater(
        FilePicker.pickFiles(withReadStream: true), throwsUnsupportedError);
    await expectLater(FilePicker.getDirectoryPath(), throwsUnsupportedError);
  });

  test('损坏或超限的原生元数据不能当成有效文件', () async {
    for (final row in [
      {'name': 'bad.txt', 'size': 0},
      {'path': '/cache/a', 'name': 'bad.txt', 'size': -1},
      {
        'path': '/cache/a',
        'name': 'bad.txt',
        'size': FilePicker.maxFileBytes + 1
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => [row]);
      await expectLater(FilePicker.pickFiles(), throwsFormatException);
    }
  });

  test('媒体类型有明确过滤条件，目录选择未开放', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['allowedExtensions'], containsAll(['jpg', 'png']));
      return null;
    });
    expect(await FilePicker.pickFiles(type: FileType.image), isNull);
  });
}
