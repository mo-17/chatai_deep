import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/deepseek_file_preview_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _chat = 'https://api.deepseek.com/chat/completions';
const _key = 'private-api-key';
const _account = 'private-account';
const _id = 'file-api-preview-a';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xff1769aa));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _save(DeepSeekFilePreviewStore store, Uint8List bytes,
        {String id = _id,
        String account = _account,
        String key = _key,
        String chat = _chat}) =>
    store.save(
        accountHash: account,
        chatCompletionsUrl: chat,
        apiKey: key,
        fileId: id,
        bytes: bytes);

Future<Uint8List?> _read(DeepSeekFilePreviewStore store,
        {String id = _id,
        String account = _account,
        String key = _key,
        String chat = _chat}) =>
    store.read(
        accountHash: account,
        chatCompletionsUrl: chat,
        apiKey: key,
        fileId: id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DeepSeekFilePreviewStore store;
  late Uint8List image;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('deepseek-previews-');
    store = DeepSeekFilePreviewStore(rootDirectory: () async => root);
    image = await _png(100, 50);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('保存真实 PNG，重建缓存实例后仍按精确 file_id 读取', () async {
    await _save(store, image);
    final persisted = DeepSeekFilePreviewStore(rootDirectory: () async => root);
    expect(await _read(persisted), isNotNull);
    expect(await _read(persisted, id: 'file-api-other'), isNull);
    final filenames = (await root.list().toList())
        .map((file) => file.uri.pathSegments.last)
        .toList();
    expect(filenames, hasLength(1));
    expect(filenames.single, matches(r'^[a-f0-9]{64}_[a-f0-9]{64}\.png$'));
    expect(filenames.single, isNot(contains(_key)));
    expect(filenames.single, isNot(contains(_account)));
    expect(filenames.single, isNot(contains(_id)));
  });

  test('账号、凭据和服务地址隔离，官方 root/v1/beta 共用规范作用域', () async {
    await _save(store, image);
    expect(await _read(store, account: 'other-account'), isNull);
    expect(await _read(store, key: 'other-key'), isNull);
    expect(await _read(store, chat: 'https://proxy.test/chat/completions'),
        isNull);
    expect(
        await _read(store,
            chat: 'https://api.deepseek.com/v1/chat/completions'),
        isNotNull);
    expect(
        await _read(store,
            chat: 'https://api.deepseek.com/beta/chat/completions'),
        isNotNull);
    expect(await _read(store, key: ' $_key '), isNotNull);
  });

  test('缩略图最长边受限、宽高比保留且不放大小图', () async {
    store = DeepSeekFilePreviewStore(
        rootDirectory: () async => root, maxThumbnailEdge: 64);
    await _save(store, await _png(600, 300));
    var bytes = (await _read(store))!;
    var codec = await ui.instantiateImageCodec(bytes);
    var frame = await codec.getNextFrame();
    expect([frame.image.width, frame.image.height], [64, 32]);
    frame.image.dispose();
    codec.dispose();
    await _save(store, await _png(20, 10));
    bytes = (await _read(store))!;
    codec = await ui.instantiateImageCodec(bytes);
    frame = await codec.getNextFrame();
    expect([frame.image.width, frame.image.height], [20, 10]);
    frame.image.dispose();
    codec.dispose();
  });

  test('缓存总数量跨账号共用预算，读取更新 LRU', () async {
    store =
        DeepSeekFilePreviewStore(rootDirectory: () async => root, maxFiles: 2);
    await _save(store, image);
    final first = (await root.list().toList()).single as File;
    await first.setLastModified(DateTime(2000));
    await _save(store, image, id: 'file-api-b', account: 'account-b');
    final second = (await root.list().toList())
        .whereType<File>()
        .firstWhere((file) => file.path != first.path);
    await second.setLastModified(DateTime(2001));
    expect(await _read(store), isNotNull);
    await _save(store, image, id: 'file-api-c');
    expect(await _read(store), isNotNull);
    expect(await _read(store, id: 'file-api-b', account: 'account-b'), isNull);
    expect(await _read(store, id: 'file-api-c'), isNotNull);
    expect(await root.list().length, 2);
  });

  test('总字节预算驱逐旧文件，单张预算不足时不写缓存', () async {
    await _save(store, image);
    final thumbnailSize = (await _read(store))!.length;
    store = DeepSeekFilePreviewStore(
        rootDirectory: () async => root, maxCacheBytes: thumbnailSize);
    final file = (await root.list().toList()).single as File;
    await file.setLastModified(DateTime(2000));
    await _save(store, image, id: 'file-api-b');
    expect(await _read(store), isNull);
    expect(await _read(store, id: 'file-api-b'), isNotNull);
    final tinyBudget = DeepSeekFilePreviewStore(
        rootDirectory: () async => root, maxThumbnailBytes: 1);
    await _save(tinyBudget, image, id: 'file-api-c');
    expect(await _read(store, id: 'file-api-c'), isNull);
  });

  test('损坏的源图、超过 64 MiB 的源图和非法作用域不写盘', () async {
    await _save(store, Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]));
    await _save(store, Uint8List(64 * 1024 * 1024 + 1));
    await _save(store, image, id: '../../file-api-a');
    await _save(store, image, account: ' ');
    await _save(store, image, key: ' ');
    await _save(store, image, chat: 'https://api.deepseek.com/not-chat');
    expect(await root.list().length, 0);
  });

  test('损坏的磁盘缩略图被移除并返回 null', () async {
    await _save(store, image);
    final file = (await root.list().toList()).single as File;
    await file.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
    expect(await _read(store), isNull);
    expect(await file.exists(), isFalse);
  });

  test('删除只清理当前作用域，同一 ID 的其他账号保留', () async {
    await _save(store, image);
    await _save(store, image, account: 'other-account');
    await store.remove(
        accountHash: _account,
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: _id);
    expect(await _read(store), isNull);
    expect(await _read(store, account: 'other-account'), isNotNull);
    await store.remove(
        accountHash: _account,
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: '../unsafe');
    expect(await root.list().length, 1);
  });

  test('缺失插件或磁盘故障保持 best effort，不阻断其他缓存操作', () async {
    final failing = DeepSeekFilePreviewStore(rootDirectory: () async {
      throw const FileSystemException('unavailable');
    });
    await _save(failing, image);
    expect(await _read(failing), isNull);
    await failing.remove(
        accountHash: _account,
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: _id);
    await _save(store, image);
    expect(await _read(store), isNotNull);
  });

  test('不同缓存实例的写、读、删串行执行，不遗留 part 文件', () async {
    final second = DeepSeekFilePreviewStore(rootDirectory: () async => root);
    final saving = _save(store, image);
    final reading = _read(second);
    final removing = second.remove(
        accountHash: _account,
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: _id);
    await saving;
    expect(await reading, isNotNull);
    await removing;
    expect(await _read(store), isNull);
    expect(await root.list().length, 0);
  });

  test('异步缓存准备期间取消保存，不会创建迟到的缩略图', () async {
    final resolving = Completer<void>();
    final release = Completer<void>();
    var current = true;
    final delayed = DeepSeekFilePreviewStore(rootDirectory: () async {
      resolving.complete();
      await release.future;
      return root;
    });
    final saving = delayed.save(
        accountHash: _account,
        chatCompletionsUrl: _chat,
        apiKey: _key,
        fileId: _id,
        bytes: image,
        shouldSave: () => current);
    await resolving.future;
    current = false;
    release.complete();
    await saving;
    expect(await _read(store), isNull);
    expect(await root.list().length, 0);
  });

  test('符号链接不能读取或覆盖缓存目录外的图片', () async {
    await _save(store, image);
    final file = (await root.list().toList()).single as File;
    final outside = await Directory.systemTemp.createTemp('preview-outside-');
    addTearDown(() => outside.delete(recursive: true));
    final external = File('${outside.path}/original.png');
    await external.writeAsBytes(image);
    await file.delete();
    await Link(file.path).create(external.path);
    expect(await _read(store), isNull);
    await _save(store, image);
    expect(await external.readAsBytes(), image);
    expect(await FileSystemEntity.type(file.path, followLinks: false),
        FileSystemEntityType.link);
  });

  test('缓存预算参数不允许超过缩略图安全上限', () {
    expect(() => DeepSeekFilePreviewStore(maxFiles: 0), throwsArgumentError);
    expect(() => DeepSeekFilePreviewStore(maxThumbnailEdge: 1281),
        throwsArgumentError);
    expect(
        () => DeepSeekFilePreviewStore(maxThumbnailBytes: 8 * 1024 * 1024 + 1),
        throwsArgumentError);
  });
}
