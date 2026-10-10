import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/chat/application/workspace_attachment_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const mib = 1024 * 1024;
  late Directory root;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment-batch-');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
  });

  Future<File> textFile(String name, String content) =>
      File('${root.path}/$name').writeAsString(content);
  Future<File> bytesFile(String name, int length) =>
      File('${root.path}/$name').writeAsBytes(Uint8List(length));

  test('图片编码与托管保存使用同一快照，回调增长原图后不重读且字节仅计一次', () async {
    final original = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8ioAAAAASUVORK5CYII=');
    final source =
        await File('${root.path}/original.png').writeAsBytes(original);
    final budget = AttachmentBatchBudget(
        limits: const AttachmentProcessingLimits(maxTotalFileBytes: mib));
    String? managedPath;
    var snapshots = 0;
    final images = await FileProcessor.encodeImages([source.path],
        batchBudget: budget, onSnapshot: (sourcePath, snapshotPath) {
      expect(sourcePath, source.path);
      managedPath = snapshotPath;
      snapshots++;
      // 真实替换原路径；若编码随后重读源图，会拿到超过整轮预算的不同字节。
      source.deleteSync();
      source.writeAsBytesSync(Uint8List(mib + 1));
    });
    expect(snapshots, 1);
    expect(managedPath, isNotNull);
    expect(managedPath, isNot(source.path));
    expect(base64Decode(images.single.split(',').last), original);
    expect(
        await ManagedAttachmentStore.readManagedBytes(managedPath!), original);
    expect(await source.length(), mib + 1);
    expect(budget.usedBytes, original.length);
    expect(budget.remainingBytes, mib - original.length);
    expect(budget.usedTextCharacters, 0);
  });

  test('只做stat预检后文件增长，读取时按实际大小拒绝且不消耗预算', () async {
    final source = await bytesFile('growing.png', 512);
    final budget = AttachmentBatchBudget(
        limits: const AttachmentProcessingLimits(maxTotalFileBytes: mib));
    await budget.preflightPaths([source.path]);
    expect(budget.usedBytes, 0);
    await source.writeAsBytes(Uint8List(mib + 1));
    await expectLater(
        budget.readFileBytes(source, maxBytes: FileProcessor.maxImageBytes),
        throwsA(isA<AttachmentBatchLimitException>()
            .having((error) => error.used, 'used', mib + 1)
            .having((error) => error.limit, 'limit', mib)));
    expect(await source.length(), mib + 1);
    expect(budget.usedBytes, 0);
    expect(budget.remainingBytes, mib);
  });

  test('故事新发送保存托管图片路径，删除源图后仍可读取同一图片', () async {
    final original = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j8ioAAAAASUVORK5CYII=');
    final source =
        await File('${root.path}/story-preview.png').writeAsBytes(original);
    final bundle = await StoryRoomAttachmentService.prepare(
        imagePaths: [source.path],
        filePaths: const [],
        capabilities: const ModelCapabilities(image: true));
    expect(bundle.imagePaths, hasLength(1));
    expect(bundle.imagePaths.single, isNot(source.path));
    expect(base64Decode(bundle.attachments.images.single.split(',').last),
        original);
    await source.delete();
    expect(
        await ManagedAttachmentStore.readManagedBytes(bundle.imagePaths.single),
        original);
  });

  test('图片与文件共用字节预算，恰好上限允许且预检不重复占用', () async {
    const limits = AttachmentProcessingLimits(
        maxTextChars: mib, maxTotalFileBytes: mib, maxTotalTextChars: mib);
    final image = await bytesFile('preview.png', mib ~/ 2);
    final text = await textFile('notes.txt', 'n' * (mib ~/ 2));
    final budget = AttachmentBatchBudget(limits: limits);
    await budget.preflightPaths([image.path, text.path]);
    expect(budget.usedBytes, 0);
    expect(budget.remainingBytes, mib);
    final images = await FileProcessor.encodeImages([image.path],
        limits: limits, batchBudget: budget);
    final files = await FileProcessor.process(
        [text.path], const ModelCapabilities.none(),
        limits: limits, batchBudget: budget);
    expect(base64Decode(images.single.split(',').last).length, mib ~/ 2);
    expect(files.metas.single.size, mib ~/ 2);
    expect(files.extraText, contains('n' * 100));
    expect(files.hasWarnings, isFalse);
    expect(budget.usedBytes, mib);
    expect(budget.remainingBytes, 0);
    expect(budget.usedTextCharacters, files.extraText.length);
  });

  test('图片与文件合计超限在预检时拒绝，不编码图片、不复制或解析文件', () async {
    const limits = AttachmentProcessingLimits(maxTotalFileBytes: mib);
    final image = await bytesFile('preview.png', mib ~/ 2);
    final office = await bytesFile('not-yet-parsed.docx', mib ~/ 2 + 1);
    final budget = AttachmentBatchBudget(limits: limits);
    await expectLater(
        budget.preflightPaths([image.path, office.path]),
        throwsA(isA<AttachmentBatchLimitException>()
            .having((error) => error.used, 'used', mib + 1)
            .having((error) => error.limit, 'limit', mib)
            .having((error) => error.message, 'message', contains('AI 服务设置'))));
    expect(budget.usedBytes, 0);
    expect(budget.usedTextCharacters, 0);
    expect(await Directory('${root.path}/managed').exists(), isFalse);
  });

  test('图片批量超限在base64之前拒绝，未发出单图处理进度', () async {
    final first = await bytesFile('first.png', mib ~/ 2);
    final second = await bytesFile('second.png', mib ~/ 2 + 1);
    final progress = <ChatSendProgress>[];
    final budget = AttachmentBatchBudget(
        limits: const AttachmentProcessingLimits(maxTotalFileBytes: mib));
    await expectLater(
        FileProcessor.encodeImages([first.path, second.path],
            batchBudget: budget, onProgress: progress.add),
        throwsA(isA<AttachmentBatchLimitException>()));
    expect(progress, isEmpty);
    expect(budget.usedBytes, 0);
  });

  test('图片已消耗的预算继续约束文件，超限DOCX在复制或解析前拒绝', () async {
    const limits = AttachmentProcessingLimits(maxTotalFileBytes: mib);
    final image = await bytesFile('preview.png', mib ~/ 2);
    final office = await bytesFile('damaged.docx', mib ~/ 2 + 1);
    final progress = <ChatSendProgress>[];
    final budget = AttachmentBatchBudget(limits: limits);
    await FileProcessor.encodeImages([image.path], batchBudget: budget);
    final managed = Directory('${root.path}/managed');
    final before = (await managed
        .list(recursive: true)
        .map((file) => file.path)
        .toList())
      ..sort();
    await expectLater(
        FileProcessor.process([office.path], const ModelCapabilities.none(),
            limits: limits, batchBudget: budget, onProgress: progress.add),
        throwsA(isA<AttachmentBatchLimitException>()));
    expect(progress, isEmpty);
    expect(budget.usedBytes, mib ~/ 2);
    expect(budget.usedTextCharacters, 0);
    final after = (await managed
        .list(recursive: true)
        .map((file) => file.path)
        .toList())
      ..sort();
    expect(after, before);
  });

  test('文字累计含附件分隔符，恰好上限通过、超出一字符明确报错', () async {
    final first = await textFile('one.txt', '甲' * 600);
    final second = await textFile('two.txt', '乙' * 600);
    final paths = [first.path, second.path];
    final original =
        await FileProcessor.process(paths, const ModelCapabilities.none());
    final exactLimit = original.extraText.length;
    final budget = AttachmentBatchBudget(
        limits: AttachmentProcessingLimits(maxTotalTextChars: exactLimit));
    final accepted = await FileProcessor.process(
        paths, const ModelCapabilities.none(),
        batchBudget: budget);
    expect(accepted.extraText, original.extraText);
    expect(accepted.hasWarnings, isFalse);
    expect(budget.usedTextCharacters, exactLimit);
    await expectLater(
        FileProcessor.process(paths, const ModelCapabilities.none(),
            batchBudget: AttachmentBatchBudget(
                limits: AttachmentProcessingLimits(
                    maxTotalTextChars: exactLimit - 1))),
        throwsA(isA<AttachmentBatchLimitException>()
            .having((error) => error.used, 'used', exactLimit)
            .having((error) => error.message, 'message', contains('总字数'))));
    expect(await first.readAsString(), '甲' * 600);
    expect(await second.readAsString(), '乙' * 600);
  });

  test('总字符预算按UTF16计数，边界拒绝不会截断或消费半个emoji', () {
    final budget = AttachmentBatchBudget(
        limits: const AttachmentProcessingLimits(maxTotalTextChars: 1024));
    final text = '😀' * 512;
    expect(text.length, 1024);
    expect(text.runes.length, 512);
    budget.consumeText(text);
    expect(budget.usedTextCharacters, 1024);
    expect(
        () => budget.consumeText('😀'),
        throwsA(isA<AttachmentBatchLimitException>()
            .having((error) => error.used, 'used', 1026)));
    expect(budget.usedTextCharacters, 1024);
    expect(text.runes.last, 0x1f600);
  });

  test('任务模式以保存的全文计字数，超限时未落库而非仅按短清单放行', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final workspace =
        await AgentWorkspaceService.create(HiDBManager.test(db), cid: 801);
    final source = await textFile('novel.txt', '章' * 2000);
    const limits =
        AttachmentProcessingLimits(maxTextChars: 1024, maxTotalTextChars: 1024);
    final budget = AttachmentBatchBudget(limits: limits);
    await expectLater(
        WorkspaceAttachmentProcessor(workspace)
            .process([source.path], limits: limits, batchBudget: budget),
        throwsA(isA<AttachmentBatchLimitException>().having(
            (error) => error.used, 'used', greaterThanOrEqualTo(2000))));
    expect(await workspace.listFiles(), isEmpty);
    expect(budget.usedTextCharacters, 0);
    expect(await source.readAsString(), '章' * 2000);
  });

  test('任务模式保留原文按需读取，共享预算包含正文和发给模型的清单', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final workspace =
        await AgentWorkspaceService.create(HiDBManager.test(db), cid: 802);
    final text = '${'章' * 2000}\n完整尾部😀';
    final source = await textFile('novel.txt', text);
    const limits = AttachmentProcessingLimits(
        maxTextChars: 1024, maxTotalTextChars: 10000);
    final budget = AttachmentBatchBudget(limits: limits);
    final result = await WorkspaceAttachmentProcessor(workspace)
        .process([source.path], limits: limits, batchBudget: budget);
    expect(result.extraText, isNot(contains('完整尾部')));
    expect(budget.usedTextCharacters, text.length + result.extraText.length);
    expect(budget.usedBytes, utf8.encode(text).length);
    final id = result.metas.single.workspaceFileId!;
    expect((await workspace.getRevision(id)).content, text);
    await source.delete();
    expect((await workspace.readFile(id, tail: true))['content'],
        contains('完整尾部😀'));
  });

  test('预检取消和文件处理取消都保留输入，且未复制文件或消耗预算', () async {
    final source = await textFile('draft.txt', '不能丢失的草稿附件');
    final paths = [source.path];
    final budget = AttachmentBatchBudget();
    await expectLater(budget.preflightPaths(paths, isCancelled: () => true),
        throwsA(isA<AttachmentProcessingCancelledException>()));
    await expectLater(
        FileProcessor.process(paths, const ModelCapabilities.none(),
            batchBudget: budget, isCancelled: () => true),
        throwsA(isA<AttachmentProcessingCancelledException>()));
    expect(paths, [source.path]);
    expect(await source.readAsString(), '不能丢失的草稿附件');
    expect(budget.usedBytes, 0);
    expect(budget.usedTextCharacters, 0);
    expect(await Directory('${root.path}/managed').exists(), isFalse);
  });

  test('故事房间数量不再截断，整批文字超限必须抛错而非空上下文发送', () async {
    final paths = <String>[];
    for (var index = 0; index < 12; index++) {
      paths.add((await textFile('note-$index.txt', '正文$index')).path);
    }
    final bundle = await StoryRoomAttachmentService.prepare(
        imagePaths: const [],
        filePaths: paths,
        capabilities: const ModelCapabilities.none());
    expect(bundle.filePaths, paths);
    expect(bundle.attachmentContext, contains('正文11'));
    final first = await textFile('first.txt', 'a' * 700);
    final second = await textFile('second.txt', 'b' * 700);
    await expectLater(
        StoryRoomAttachmentService.prepare(
            imagePaths: const [],
            filePaths: [first.path, second.path],
            capabilities: const ModelCapabilities.none(),
            limits: const AttachmentProcessingLimits(maxTotalTextChars: 1024)),
        throwsA(isA<AttachmentBatchLimitException>()));
  });
}
