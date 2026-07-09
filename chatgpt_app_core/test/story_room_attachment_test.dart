import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('附件路径去重并限制图片和文件数量', () {
    expect(
      StoryRoomAttachmentPolicy.normalizePaths(
        ['a', '', 'a', 'b', 'c'],
        limit: StoryRoomAttachmentPolicy.maxImages,
      ),
      ['a', 'b', 'c'],
    );
    expect(
      StoryRoomAttachmentPolicy.normalizePaths(
        List.generate(12, (index) => 'file-$index'),
        limit: StoryRoomAttachmentPolicy.maxFiles,
      ),
      List.generate(10, (index) => 'file-$index'),
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
    );

    expect(bundle.imagePaths, ['/missing/image.png']);
    expect(bundle.filePaths, ['/missing/world.txt']);
    expect(bundle.attachmentContext, '[附件 world.txt 的历史抽取内容]');
    expect(bundle.attachments.extraText, contains('历史抽取内容'));
  });
}
