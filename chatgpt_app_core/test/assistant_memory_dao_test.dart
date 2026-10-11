import 'dart:async';

import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
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
    expect(list, everyElement(predicate<AssistantMemoryModel>((memory) {
      return memory.memoryId.isNotEmpty &&
          memory.assistantSyncId == 'legacy:${memory.assistantId}' &&
          memory.status == AssistantMemoryStatus.active &&
          memory.confirmedByUser &&
          memory.revision == 1;
    })));
  });

  test('旧六列表会被加法迁移且旧记忆继续保持 active', () async {
    // setUp 已在本用例的隔离库中建了新表；原地重建旧表才能
    // 真实模拟升级。另开 `:memory:` 会因 sqflite singleInstance 复用连接。
    await db.execute('drop table tb_assistant_memory');
    await db.execute(
      'create table tb_assistant_memory ('
      'id integer primary key autoincrement, assistantId integer, '
      'content text, source text, createdAt integer, updatedAt integer)',
    );
    await db.insert('tb_assistant_memory', {
      'assistantId': 7,
      'content': '旧用户的重要记忆',
      'source': 'manual',
      'createdAt': 100,
      'updatedAt': 200,
    });

    final legacyDao = await AssistantMemoryDao.create(HiDBManager.test(db));
    final memories = await legacyDao.getMemories(7);

    expect(memories, hasLength(1));
    final memory = memories.single;
    expect(memory.id, 1);
    expect(memory.assistantId, 7);
    expect(memory.content, '旧用户的重要记忆');
    expect(memory.source, 'manual');
    expect(memory.createdAt, 100);
    expect(memory.updatedAt, 200);
    expect(memory.memoryId, 'legacy:7:1');
    expect(memory.assistantSyncId, 'legacy:7');
    expect(memory.sourceType, 'legacy');
    expect(memory.sourceConversationId, isEmpty);
    expect(memory.sourceMessageId, isEmpty);
    expect(memory.status, AssistantMemoryStatus.active);
    expect(memory.confirmedByUser, isTrue);
    expect(memory.revision, 1);
    expect(
      AssistantMemoryDao.buildSystemContext(memories),
      contains('旧用户的重要记忆'),
    );
  });

  test('迁移只把 null status 回填 active，空值保持非 active', () async {
    await db.insert('tb_assistant_memory', {
      'assistantId': 7,
      'content': '缺失状态的旧记忆',
      'source': 'manual',
      'createdAt': 100,
      'updatedAt': 100,
      'memoryId': 'status-null',
      'confirmedByUser': 1,
      'revision': 1,
    });
    await db.insert('tb_assistant_memory', {
      'assistantId': 7,
      'content': '空状态的损坏记忆',
      'source': 'manual',
      'createdAt': 200,
      'updatedAt': 200,
      'memoryId': 'status-empty',
      'status': '',
      'confirmedByUser': 1,
      'revision': 1,
    });

    final migratedDao = await AssistantMemoryDao.create(HiDBManager.test(db));
    final rows = await db.query(
      'tb_assistant_memory',
      columns: ['memoryId', 'status'],
      orderBy: 'id',
    );
    final memories = await migratedDao.getMemories(7);

    expect(rows[0]['status'], 'active');
    expect(rows[1]['status'], '');
    expect(
      memories.singleWhere((memory) => memory.memoryId == 'status-null').status,
      AssistantMemoryStatus.active,
    );
    expect(
      memories
          .singleWhere((memory) => memory.memoryId == 'status-empty')
          .status,
      AssistantMemoryStatus.archived,
    );
    expect(
      (await migratedDao.getActiveMemories(7)).map((memory) => memory.memoryId),
      ['status-null'],
    );
  });

  test('迁移修复历史重复 memoryId，并建立唯一索引阻止新重复', () async {
    await db.execute('drop table tb_assistant_memory');
    await db.execute(
      'create table tb_assistant_memory ('
      'id integer primary key autoincrement, assistantId integer, '
      'content text, source text, createdAt integer, updatedAt integer, '
      'memoryId text, assistantSyncId text, sourceType text, '
      'sourceConversationId text, sourceMessageId text, status text, '
      'confirmedByUser integer, revision integer)',
    );
    for (final content in ['先写入的记忆', '后写入的重复记忆']) {
      await db.insert('tb_assistant_memory', {
        'assistantId': 7,
        'content': content,
        'source': 'manual',
        'createdAt': 100,
        'updatedAt': 100,
        'memoryId': 'duplicate-memory-id',
        'assistantSyncId': 'assistant-stable-id',
        'sourceType': 'manual',
        'sourceConversationId': '',
        'sourceMessageId': '',
        'status': 'active',
        'confirmedByUser': 1,
        'revision': 1,
      });
    }

    final migratedDao = await AssistantMemoryDao.create(HiDBManager.test(db));
    final rows = await db.query('tb_assistant_memory', orderBy: 'id');
    final indexes =
        await db.rawQuery("pragma index_list('tb_assistant_memory')");

    expect(rows[0]['memoryId'], 'duplicate-memory-id');
    expect(
      rows[1]['memoryId'],
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      )),
    );
    expect(rows[1]['memoryId'], isNot(rows[0]['memoryId']));
    expect(
      indexes,
      contains(predicate<Map<String, Object?>>(
        (index) =>
            index['name'] == 'idx_assistant_memory_memory_id_uq' &&
            index['unique'] == 1,
      )),
    );

    final duplicate = AssistantMemoryModel(
      assistantId: 7,
      content: '不应写入的新重复记忆',
      memoryId: 'duplicate-memory-id',
    );
    expect(await migratedDao.saveMemory(duplicate), isNull);
    expect(duplicate.id, isNull);
    expect(await migratedDao.getMemories(7), hasLength(2));
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

  test('用户确认的会话记忆保留规范化来源与消息身份', () {
    final memory = AssistantMemoryModel.confirmedFromConversation(
      assistantId: 9,
      content: '用户喜欢简短回答',
      source: 'suggestion',
      sourceType: 'ai_suggestion',
      conversationId: '12345',
      messageId: '1700000000000',
    );

    expect(memory.source, 'suggestion');
    expect(memory.sourceType, 'ai_suggestion');
    expect(memory.sourceConversationId, '12345');
    expect(memory.sourceMessageId, '1700000000000');
    expect(memory.status, AssistantMemoryStatus.active);
    expect(memory.confirmedByUser, isTrue);
  });

  test('JSON 仅在 status 键缺失时兼容 active，显式损坏值全部归档', () {
    final legacy = AssistantMemoryModel.fromJson({
      'assistantId': 1,
      'content': '旧格式仍应进入上下文',
    });
    expect(legacy.status, AssistantMemoryStatus.active);

    for (final raw in <Object?>[null, '', 'unknown_status']) {
      final memory = AssistantMemoryModel.fromJson({
        'assistantId': 1,
        'content': '不应进入上下文',
        'status': raw,
      });
      expect(memory.status, AssistantMemoryStatus.archived, reason: 'raw=$raw');
      expect(AssistantMemoryDao.buildSystemContext([memory]), isEmpty);
    }

    final invalidConfirmation = AssistantMemoryModel.fromJson({
      'assistantId': 1,
      'content': '非法确认值也不应进入上下文',
      'status': 'active',
      'confirmedByUser': 2,
    });
    expect(invalidConfirmation.confirmedByUser, isFalse);
    expect(
      AssistantMemoryDao.buildSystemContext([invalidConfirmation]),
      isEmpty,
    );
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

  test('只有 active 记忆进入 system context，管理读取仍返回全部状态', () async {
    for (final status in AssistantMemoryStatus.values) {
      await dao.saveMemory(AssistantMemoryModel(
        assistantId: 1,
        content: '状态 ${status.name}',
        status: status,
        confirmedByUser: status == AssistantMemoryStatus.active,
      ));
    }

    final all = await dao.getMemories(1);
    final active = await dao.getActiveMemories(1);

    expect(all, hasLength(4));
    expect(
        active.map((memory) => memory.status), [AssistantMemoryStatus.active]);
    final context = AssistantMemoryDao.buildSystemContext(all);
    expect(context, contains('状态 active'));
    expect(context, isNot(contains('状态 pending')));
    expect(context, isNot(contains('状态 rejected')));
    expect(context, isNot(contains('状态 archived')));
  });

  test('active 但未经用户确认的记忆不会进入查询或 system context', () async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '已确认',
      confirmedByUser: true,
    ));
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '未确认',
      confirmedByUser: false,
    ));

    final active = await dao.getActiveMemories(1);
    final all = await dao.getMemories(1);

    expect(active.map((memory) => memory.content), ['已确认']);
    final context = AssistantMemoryDao.buildSystemContext(all);
    expect(context, contains('已确认'));
    expect(context, isNot(contains('未确认')));
  });

  test('删除助手会事务性清理长期记忆，但保留会话的历史引用', () async {
    final storage = HiDBManager.test(db);
    final assistantDao = await AssistantDao.create(storage);
    final assistantId = (await assistantDao.saveAssistant(
      AssistantModel(name: '待删除助手', prompt: '测试'),
    ))!;
    final conversationDao = await ConversationListDao.create(storage);
    await conversationDao.saveConversation(
      ConversationModel(
        cid: 88,
        icon: '',
        assistantId: assistantId,
      )
        ..title = '历史会话'
        ..updateAt = 1,
    );
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: assistantId,
      content: '应跟随助手删除',
    ));

    await assistantDao.deleteAssistant(assistantId);

    expect(await dao.getMemories(assistantId), isEmpty);
    final conversation = await db.query(
      'tb_conversation_list',
      where: 'cid = ?',
      whereArgs: [88],
    );
    expect(conversation.single['assistantId'], assistantId);
  });

  test('编辑只更新可变字段，并以数据库 revision 递增', () async {
    final memory = AssistantMemoryModel(
      assistantId: 1,
      content: '初始内容',
      memoryId: 'memory-stable-id',
      assistantSyncId: 'assistant-stable-id',
      sourceType: 'manual',
    );
    await dao.saveMemory(memory);
    final createdAt = memory.createdAt;

    memory
      ..assistantId = 2
      ..content = '更新内容'
      ..memoryId = 'attacker-memory-id'
      ..assistantSyncId = 'attacker-assistant-id'
      ..createdAt = 0
      ..sourceType = 'edited'
      ..revision = 999;
    await dao.saveMemory(memory);

    final saved = (await dao.getMemories(1)).single;
    expect(saved.content, '更新内容');
    expect(saved.assistantId, 1);
    expect(saved.memoryId, 'memory-stable-id');
    expect(saved.assistantSyncId, 'assistant-stable-id');
    expect(saved.createdAt, createdAt);
    expect(saved.sourceType, 'edited');
    expect(saved.revision, 2);
    expect(await dao.getMemories(2), isEmpty);
    expect(memory.assistantId, 1);
    expect(memory.memoryId, 'memory-stable-id');
    expect(memory.assistantSyncId, 'assistant-stable-id');
    expect(memory.createdAt, createdAt);
    expect(memory.revision, 2);
  });

  test('并发 stale snapshot 更新在同一事务中连续递增 revision', () async {
    final memory = AssistantMemoryModel(
      assistantId: 1,
      content: '初始内容',
      memoryId: 'concurrent-memory-id',
    );
    await dao.saveMemory(memory);
    final first = AssistantMemoryModel.fromJson(memory.toJson())
      ..content = '并发更新 A';
    final second = AssistantMemoryModel.fromJson(memory.toJson())
      ..content = '并发更新 B';
    final barrierDb = _ReadBarrierDatabase(db);
    final concurrentDao =
        await AssistantMemoryDao.create(HiDBManager.test(barrierDb));

    final ids = await Future.wait([
      concurrentDao.saveMemory(first),
      concurrentDao.saveMemory(second),
    ]);
    final saved = (await concurrentDao.getMemories(1)).single;

    expect(ids, everyElement(memory.id));
    expect(saved.revision, 3);
    expect({first.revision, second.revision}, {2, 3});
    expect(saved.content, anyOf('并发更新 A', '并发更新 B'));
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

  test('管理写入CAS拒绝旧revision/错误助手/已删除行，不复活', () async {
    final original = AssistantMemoryModel(assistantId: 1, content: '合成原文');
    await dao.saveMemory(original);
    final stale = AssistantMemoryModel.fromJson(original.toJson());
    original.content = '合成更新';
    expect(await dao.saveMemoryChecked(original), isNotNull);
    stale.content = '过期覆盖';
    expect(await dao.saveMemoryChecked(stale), isNull);
    expect(await dao.deleteMemoryChecked(stale), 0);
    final wrongAssistant = AssistantMemoryModel.fromJson(original.toJson())
      ..assistantId = 2;
    expect(await dao.saveMemoryChecked(wrongAssistant), isNull);
    expect(await dao.deleteMemoryChecked(original), 1);
    expect(await dao.saveMemoryChecked(original), isNull);
    expect(await dao.getMemories(1), isEmpty);
  });

  test('删除记忆', () async {
    final memory = AssistantMemoryModel(assistantId: 1, content: '待删除');
    final id = await dao.saveMemory(memory);
    expect(await dao.getMemories(1), hasLength(1));

    await dao.deleteMemory(id!);
    expect(await dao.getMemories(1), isEmpty);
  });
}

class _ReadBarrierDatabase implements Database {
  _ReadBarrierDatabase(this._delegate);

  final Database _delegate;
  final Completer<void> _bothReadsComplete = Completer<void>();
  int _identityReads = 0;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _delegate.execute(sql, arguments);

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _delegate.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      );

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final rows = await _delegate.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    if (table == 'tb_assistant_memory' &&
        where == 'id = ?' &&
        _identityReads < 2) {
      _identityReads += 1;
      if (_identityReads == 2) _bothReadsComplete.complete();
      await _bothReadsComplete.future;
    }
    return rows;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _delegate.update(
        table,
        values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm,
      );

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) =>
      _delegate.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) =>
      _delegate.transaction(action, exclusive: exclusive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
