import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('generated-image-save-');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('saveToAppAlbum 保存 data URI 到 generated_images 目录', () async {
    final bytes = [1, 2, 3, 4];
    final plan = GeneratedImageSavePlan(
      source: 'data:image/png;base64,${base64Encode(bytes)}',
      albumName: 'ChatAI Deep',
      filename: 'demo.png',
      needsPhotoPermission: false,
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      plan,
      directoryResolver: () async => tempDir,
    );

    expect(path, endsWith('/generated_images/demo.png'));
    expect(await File(path).readAsBytes(), bytes);
  });

  test('saveToAppAlbum 复制本地文件', () async {
    final source = File('${tempDir.path}/source.png');
    await source.writeAsBytes([9, 8, 7]);
    const plan = GeneratedImageSavePlan(
      source: '',
      albumName: 'ChatAI Deep',
      filename: 'copy.png',
      needsPhotoPermission: false,
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      GeneratedImageSavePlan(
        source: source.path,
        albumName: plan.albumName,
        filename: plan.filename,
        needsPhotoPermission: plan.needsPhotoPermission,
      ),
      directoryResolver: () async => tempDir,
    );

    expect(await File(path).readAsBytes(), [9, 8, 7]);
  });

  test('saveToAppAlbum 下载 http 图片', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://img.example/a.png');
      return http.Response.bytes([5, 6, 7], 200);
    });
    const plan = GeneratedImageSavePlan(
      source: 'https://img.example/a.png',
      albumName: 'ChatAI Deep',
      filename: 'remote.png',
      needsPhotoPermission: false,
    );

    final path = await GeneratedImageSaveService.saveToAppAlbum(
      plan,
      directoryResolver: () async => tempDir,
      client: client,
    );

    expect(await File(path).readAsBytes(), [5, 6, 7]);
  });

  test('listSavedImages 只列出图片并按修改时间倒序', () async {
    final dir = Directory('${tempDir.path}/generated_images');
    await dir.create();
    final oldFile = File('${dir.path}/old.png');
    final newFile = File('${dir.path}/new.jpg');
    final ignored = File('${dir.path}/note.txt');
    await oldFile.writeAsBytes([1]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await newFile.writeAsBytes([2, 3]);
    await ignored.writeAsString('not image');

    final items = await GeneratedImageSaveService.listSavedImages(
      directoryResolver: () async => tempDir,
    );

    expect(items.map((e) => e.filename), ['new.jpg', 'old.png']);
    expect(items.first.sizeBytes, 2);
    expect(items.first.path, newFile.path);
  });

  test('deleteSavedImage 只删除 generated_images 目录内文件', () async {
    final dir = Directory('${tempDir.path}/generated_images');
    await dir.create();
    final image = File('${dir.path}/delete-me.png');
    await image.writeAsBytes([1, 2]);
    final outside = File('${tempDir.path}/outside.png');
    await outside.writeAsBytes([3]);

    final deleted = await GeneratedImageSaveService.deleteSavedImage(
      image.path,
      directoryResolver: () async => tempDir,
    );

    expect(deleted, isTrue);
    expect(image.existsSync(), isFalse);

    expect(
      () => GeneratedImageSaveService.deleteSavedImage(
        outside.path,
        directoryResolver: () async => tempDir,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(outside.existsSync(), isTrue);
  });
}
