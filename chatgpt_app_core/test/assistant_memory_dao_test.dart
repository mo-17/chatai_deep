import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Database db;
  late AssistantMemoryDao dao;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    dao = await AssistantMemoryDao.create(HiDBManager.test(db));
  });

  tearDown(() async {
    await db.close();
  });

  test('保存后按助手隔离并按更新时间倒序读取', () async {
    final first = AssistantMemoryModel(
      assistantId: 1,
      content: '用户喜欢简短回答',
      source: 'user_message',
    );
    final second = AssistantMemoryModel(
      assistantId: 1,
      content: '角色关系：信任度较高',
      source: 'manual',
    );
    final other = AssistantMemoryModel(
      assistantId: 2,
      content: '另一个助手的记忆',
    );

    final id1 = await dao.saveMemory(first);
    await Future.delayed(const Duration(milliseconds: 2));
    final id2 = await dao.saveMemory(second);
    await dao.saveMemory(other);

    expect(id1, isNotNull);
    expect(id2, isNotNull);
    final list = await dao.getMemories(1);
    expect(list.map((e) => e.content).toList(), [
      '角色关系：信任度较高',
      '用户喜欢简短回答',
    ]);
    expect(list.map((e) => e.source).toList(), ['manual', 'user_message']);
  });

  test('空内容或无效 assistantId 不写入', () async {
    expect(
      await dao.saveMemory(AssistantMemoryModel(assistantId: 1, content: ' ')),
      isNull,
    );
    expect(
      await dao.saveMemory(AssistantMemoryModel(assistantId: 0, content: 'x')),
      isNull,
    );
    expect(await dao.getMemories(1), isEmpty);
  });

  test('buildSystemContext 生成长期记忆 system 片段并限量', () {
    final context = AssistantMemoryDao.buildSystemContext([
      AssistantMemoryModel(assistantId: 1, content: '用户喜欢简短回答'),
      AssistantMemoryModel(assistantId: 1, content: '角色关系：信任度较高'),
      AssistantMemoryModel(assistantId: 1, content: '  '),
    ], limit: 1);

    expect(context, '[长期记忆]\n- 用户喜欢简短回答');
    expect(AssistantMemoryDao.buildSystemContext(const []), isEmpty);
  });

  test('hasDuplicateContent 会忽略首尾、连续和中间空白差异', () {
    final memories = [
      AssistantMemoryModel(assistantId: 1, content: '用户喜欢简短回答'),
      AssistantMemoryModel(assistantId: 1, content: '角色关系：信任度较高'),
    ];

    expect(AssistantMemoryDao.hasDuplicateContent(memories, ' 用户喜欢\n简短回答 '),
        isTrue);
    expect(AssistantMemoryDao.hasDuplicateContent(memories, '用户喜欢   简短回答'),
        isTrue);
    expect(
        AssistantMemoryDao.hasDuplicateContent(memories, '用户喜欢详细解释'), isFalse);
    expect(AssistantMemoryDao.hasDuplicateContent(memories, ' '), isFalse);
  });

  test('删除记忆', () async {
    final memory = AssistantMemoryModel(assistantId: 1, content: '待删除');
    final id = await dao.saveMemory(memory);
    expect(await dao.getMemories(1), hasLength(1));

    await dao.deleteMemory(id!);
    expect(await dao.getMemories(1), isEmpty);
  });
}
