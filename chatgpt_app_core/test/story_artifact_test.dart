import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/chat/application/story_artifact_context_builder.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('创作资料按房间和类型保存排序', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final dao = await StoryArtifactDao.create(HiDBManager.test(db));
    await dao.saveArtifact(StoryArtifactModel(
      roomId: 1,
      type: StoryArtifactType.chapter,
      title: '第二章',
      sortOrder: 2,
    ));
    await dao.saveArtifact(StoryArtifactModel(
      roomId: 1,
      type: StoryArtifactType.chapter,
      title: '第一章',
      sortOrder: 1,
    ));
    await dao.saveArtifact(StoryArtifactModel(
      roomId: 2,
      type: StoryArtifactType.outline,
      title: '其它房间',
    ));

    final chapters = await dao.getArtifacts(1, type: StoryArtifactType.chapter);
    expect(chapters.map((item) => item.title), ['第一章', '第二章']);
    await db.close();
  });

  test('修改自动保存旧版本并可恢复', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final dao = await StoryArtifactDao.create(HiDBManager.test(db));
    final artifact = StoryArtifactModel(
      roomId: 1,
      type: StoryArtifactType.foreshadowing,
      title: '旧伏笔',
      content: '旧内容',
      status: '未回收',
    );
    await dao.saveArtifact(artifact);
    artifact
      ..title = '新伏笔'
      ..content = '新内容'
      ..status = '已回收';
    await dao.saveArtifact(artifact);

    final revisions = await dao.getRevisions(artifact.id!);
    expect(revisions, hasLength(1));
    expect(revisions.single.title, '旧伏笔');
    await dao.restoreRevision(artifact, revisions.single);
    expect(artifact.title, '旧伏笔');
    expect(artifact.content, '旧内容');
    expect(await dao.getRevisions(artifact.id!), hasLength(2));
    await db.close();
  });

  test('删除资料会同步清理版本历史', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final dao = await StoryArtifactDao.create(HiDBManager.test(db));
    final artifact = StoryArtifactModel(
      roomId: 1,
      type: StoryArtifactType.outline,
      title: '大纲',
      content: 'v1',
    );
    await dao.saveArtifact(artifact);
    artifact.content = 'v2';
    await dao.saveArtifact(artifact);
    await dao.deleteArtifact(artifact.id!);

    expect(await dao.getArtifacts(1), isEmpty);
    expect(await dao.getRevisions(artifact.id!), isEmpty);
    await db.close();
  });

  test('创作资料上下文按类型生成、替换旧快照并遵守预算', () {
    final artifacts = [
      StoryArtifactModel(
        roomId: 1,
        type: StoryArtifactType.outline,
        title: '主线',
        content: '寻找失落的城市',
      ),
      StoryArtifactModel(
        roomId: 1,
        type: StoryArtifactType.foreshadowing,
        title: '旧怀表',
        content: '第三章回收',
        status: '未回收',
      ),
    ];
    final first = StoryArtifactContextBuilder.mergeIntoPublicContext(
      '固定文风：冷峻。',
      artifacts,
    );
    expect(first, contains('固定文风：冷峻。'));
    expect(first, contains('大纲：'));
    expect(first, contains('旧怀表（未回收）'));

    artifacts.removeLast();
    final replaced = StoryArtifactContextBuilder.mergeIntoPublicContext(
      first,
      artifacts,
    );
    expect(replaced, isNot(contains('旧怀表')));
    expect(
      StoryArtifactContextBuilder.build(artifacts, maxCharacters: 24).length,
      lessThanOrEqualTo(24),
    );
  });
}
