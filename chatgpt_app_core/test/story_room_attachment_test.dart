import 'dart:io';

import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('story_attachment_limits_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
  });

  test('附件路径去重和去空白，不再按图片或文件数量截断', () {
    expect(
      StoryRoomAttachmentPolicy.normalizePaths(
        ['a', '', ' a ', 'b', 'c', ' d ', 'e', 'f'],
      ),
      ['a', 'b', 'c', 'd', 'e', 'f'],
    );
    expect(
      StoryRoomAttachmentPolicy.normalizePaths(
        List.generate(24, (index) => 'file-$index'),
      ),
      List.generate(24, (index) => 'file-$index'),
    );
  });

  test('重开房间时把已落库的降级文件文本接回用户历史', () {
    final message = StoryMessageModel(
      roomId: 1,
      speakerId: null,
      speakerRole: 'user',
      speakerName: '我',
      content: '请参考这个设定',
      filePaths: const ['/tmp/world.txt'],
      attachmentContext: '[附件「world.txt」内容开始]\n角色住在海边。',
    );

    final history = StoryContextBuilder.history([message]);
    expect(history.single['content'], contains('请参考这个设定'));
    expect(history.single['content'], contains('角色住在海边。'));
  });

  test('文件路径失效时仍能使用已保存的附件上下文', () async {
    final bundle = await StoryRoomAttachmentService.prepare(
      imagePaths: const ['/missing/image.png'],
      filePaths: const ['/missing/world.txt'],
      capabilities: const ModelCapabilities(image: true),
      fallbackContext: '[附件 world.txt 的历史抽取内容]',
      reuseExtractedContext: true,
    );

    expect(bundle.imagePaths, ['/missing/image.png']);
    expect(bundle.filePaths, ['/missing/world.txt']);
    expect(bundle.attachmentContext, '[附件 world.txt 的历史抽取内容]');
    expect(bundle.attachments.extraText, contains('历史抽取内容'));
  });

  test('故事房间新附件遵循配置，旧调用默认保留超过30000字符正文', () async {
    final text = 'NOVEL_START${'n' * 35000}NOVEL_END';
    final file = await File('${root.path}/novel.txt').writeAsString(text);
    final defaultBundle = await StoryRoomAttachmentService.prepare(
        imagePaths: const [],
        filePaths: [file.path],
        capabilities: const ModelCapabilities.none());
    expect(defaultBundle.attachmentContext, contains(text));
    final limited = await StoryRoomAttachmentService.prepare(
        imagePaths: const [],
        filePaths: [file.path],
        capabilities: const ModelCapabilities.none(),
        limits: const AttachmentProcessingLimits(maxTextChars: 1024));
    expect(limited.attachmentContext, contains('NOVEL_START'));
    expect(limited.attachmentContext, isNot(contains('NOVEL_END')));
    expect(limited.attachmentContext, contains('已截断'));
    expect(limited.attachments.extraText, limited.attachmentContext);
  });

  test('故事重试以旧fallback正文为准，降低限额或改写源文件不会改变提问', () async {
    final file = await File('${root.path}/novel.txt')
        .writeAsString('CHANGED_START${'n' * 5000}CHANGED_END');
    final saved = 'SAVED_START${'s' * 6000}SAVED_END';
    final bundle = await StoryRoomAttachmentService.prepare(
        imagePaths: const [],
        filePaths: [file.path],
        capabilities: const ModelCapabilities.none(),
        limits: const AttachmentProcessingLimits(
            maxTextChars: 1024,
            maxTotalTextChars: 1024,
            maxTotalFileBytes: 1024 * 1024),
        fallbackContext: saved,
        reuseExtractedContext: true);
    expect(bundle.attachmentContext, saved);
    expect(bundle.attachments.extraText, saved);
    expect(bundle.attachmentContext, isNot(contains('CHANGED_START')));
    expect(bundle.attachmentContext, isNot(contains('已截断')));
  });
}
