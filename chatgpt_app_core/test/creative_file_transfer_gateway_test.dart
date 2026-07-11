import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/creative_file_transfer_gateway.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('选择器优先使用 withData bytes，并按实际 bytes 长度限制', () async {
    var readPathCalls = 0;
    var receivedWithData = false;
    final gateway = CreativeFileTransferGateway(
      maxBytes: 3,
      pickFiles: ({
        dialogTitle,
        initialDirectory,
        allowedExtensions,
        required withData,
      }) async {
        receivedWithData = withData;
        return FilePickerResult([
          PlatformFile(
            name: 'preset.json',
            path: '/never/read/preset.json',
            bytes: Uint8List.fromList([1, 2, 3]),
            size: 999,
          ),
        ]);
      },
      readBytes: (path) async {
        readPathCalls++;
        return Uint8List.fromList([9]);
      },
    );

    final picked = await gateway.pickFile(
      dialogTitle: '导入酒馆预设',
      allowedExtensions: ['json'],
    );

    expect(receivedWithData, isTrue);
    expect(readPathCalls, 0);
    expect(picked?.name, 'preset.json');
    expect(picked?.bytes, [1, 2, 3]);
    expect(picked?.sizeBytes, 3);
  });

  test('bytes 缺失时回退 path 读取，并按实际长度而非声明 size 拒绝', () async {
    var readPath = '';
    final gateway = CreativeFileTransferGateway(
      maxBytes: 3,
      pickFiles: ({
        dialogTitle,
        initialDirectory,
        allowedExtensions,
        required withData,
      }) async {
        return FilePickerResult([
          PlatformFile(
            name: 'large.txt',
            path: '/tmp/large.txt',
            size: 1,
          ),
        ]);
      },
      readBytes: (path) async {
        readPath = path;
        return Uint8List.fromList([1, 2, 3, 4]);
      },
    );

    await expectLater(
      gateway.pickFile(),
      throwsA(
        isA<CreativeFileTransferException>().having(
          (error) => error.message,
          'message',
          contains('实际大小 4 bytes'),
        ),
      ),
    );
    expect(readPath, '/tmp/large.txt');
  });

  test('取消选择返回 null，取消保存返回未保存结果', () async {
    final gateway = CreativeFileTransferGateway(
      pickFiles: ({
        dialogTitle,
        initialDirectory,
        allowedExtensions,
        required withData,
      }) async =>
          null,
      saveFile: ({
        dialogTitle,
        fileName,
        initialDirectory,
        allowedExtensions,
        required bytes,
      }) async =>
          null,
    );

    expect(await gateway.pickFile(), isNull);
    final result = await gateway.saveBytes(Uint8List.fromList([1]));
    expect(result.saved, isFalse);
    expect(result.cancelled, isTrue);
    expect(result.path, isNull);
  });

  test('非法 UTF-8 抛出明确异常', () async {
    final gateway = CreativeFileTransferGateway(
      pickFiles: ({
        dialogTitle,
        initialDirectory,
        allowedExtensions,
        required withData,
      }) async {
        return FilePickerResult([
          PlatformFile(
            name: 'bad.txt',
            size: 2,
            bytes: Uint8List.fromList([0xc3, 0x28]),
          ),
        ]);
      },
    );

    await expectLater(
      gateway.pickUtf8Text(allowedExtensions: ['txt']),
      throwsA(
        isA<CreativeFileTransferException>().having(
          (error) => error.message,
          'message',
          contains('不是有效的 UTF-8 文本'),
        ),
      ),
    );
  });

  test('UTF-8 BOM 会统一剥离，避免 JSON 解析器分别兼容', () async {
    final gateway = CreativeFileTransferGateway(
      pickFiles: ({
        dialogTitle,
        initialDirectory,
        allowedExtensions,
        required withData,
      }) async {
        return FilePickerResult([
          PlatformFile(
            name: 'bom.json',
            size: 5,
            bytes: Uint8List.fromList([0xef, 0xbb, 0xbf, 0x7b, 0x7d]),
          ),
        ]);
      },
    );

    expect(await gateway.pickUtf8Text(), '{}');
  });

  test('保存参数和 bytes 交给 picker，返回路径只用于反馈', () async {
    String? receivedDialogTitle;
    String? receivedFileName;
    List<String>? receivedExtensions;
    Uint8List? receivedBytes;
    final gateway = CreativeFileTransferGateway(
      saveFile: ({
        dialogTitle,
        fileName,
        initialDirectory,
        allowedExtensions,
        required bytes,
      }) async {
        receivedDialogTitle = dialogTitle;
        receivedFileName = fileName;
        receivedExtensions = allowedExtensions;
        receivedBytes = bytes;
        return '/tmp/export.json';
      },
    );

    final result = await gateway.saveBytes(
      Uint8List.fromList([4, 5]),
      dialogTitle: '导出酒馆预设',
      fileName: 'preset.json',
      initialDirectory: '/tmp',
      allowedExtensions: ['json'],
    );

    expect(result.saved, isTrue);
    expect(result.path, '/tmp/export.json');
    expect(receivedDialogTitle, '导出酒馆预设');
    expect(receivedFileName, 'preset.json');
    expect(receivedExtensions, ['json']);
    expect(receivedBytes, [4, 5]);
  });

  test('picker 保存异常直接向调用方传播，不伪报成功', () async {
    final gateway = CreativeFileTransferGateway(
      saveFile: ({
        dialogTitle,
        fileName,
        initialDirectory,
        allowedExtensions,
        required bytes,
      }) async {
        throw StateError('provider failed');
      },
    );

    await expectLater(
      gateway.saveBytes(
        Uint8List.fromList([7, 8]),
        fileName: 'preset.json',
      ),
      throwsStateError,
    );
  });
}
