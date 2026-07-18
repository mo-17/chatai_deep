import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('重复执行集中迁移时不再尝试 ALTER 已存在的列', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await DbMigration.run(db);

    final recordingDb = _RecordingDatabase(db);
    await DbMigration.run(recordingDb);

    expect(recordingDb.alterStatements, isEmpty);
  });

  test('当前 DAO schema 初始化不再尝试 ALTER 已存在的列', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final recordingDb = _RecordingDatabase(db);
    final storage = HiDBManager.test(recordingDb);

    await MessageDao.create(storage, cid: 1);
    await ConversationListDao.create(storage);
    await ProjectDao.create(storage);
    await AssistantDao.create(storage);
    await UsageDao.create(storage);
    await StoryTemplateTranslationTaskDao.create(storage);

    expect(recordingDb.alterStatements, isEmpty);
  });

  test('旧版 schema 缺失的列仍会被集中迁移补齐', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(
      'create table tb_messages (id integer primary key autoincrement, '
      'cid integer not null, content text, createdAt integer, ownerName text, '
      'ownerType text, avatar text)',
    );
    await db.execute(
      'create table tb_conversation_list (id integer primary key autoincrement, '
      'cid integer, title text, icon text, updateAt integer, '
      'messageCount integer, lastMessage text, stickTime integer)',
    );

    await DbMigration.run(db);

    final messageColumns = await _columnNames(db, 'tb_messages');
    final conversationColumns = await _columnNames(db, 'tb_conversation_list');
    expect(messageColumns, containsAll(<String>['images', 'blocks']));
    expect(
      conversationColumns,
      containsAll(<String>[
        'assistantId',
        'projectId',
        'modelProviderId',
        'roleToneNote',
      ]),
    );
  });
}

Future<Set<String>> _columnNames(Database db, String table) async {
  final rows = await db.rawQuery('pragma table_info($table)');
  return rows.map((row) => row['name']! as String).toSet();
}

class _RecordingDatabase implements Database {
  final Database delegate;
  final List<String> executedStatements = <String>[];

  _RecordingDatabase(this.delegate);

  Iterable<String> get alterStatements => executedStatements.where(
        (sql) => sql.trimLeft().toLowerCase().startsWith('alter table'),
      );

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    executedStatements.add(sql);
    return delegate.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    return delegate.rawQuery(sql, arguments);
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) {
    return delegate.rawUpdate(sql, arguments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
        'Unexpected database call: ${invocation.memberName}');
  }
}
