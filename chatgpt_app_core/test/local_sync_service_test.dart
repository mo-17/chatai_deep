import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));

  test('导出本地核心表为同步变更，并支持 updatedAfter 增量过滤', () async {
    final storage = await newDb();
    final projectDao = await ProjectDao.create(storage);
    final oldProject = ProjectModel(name: '旧项目')
      ..updatedAt = 10
      ..createdAt = 10;
    await projectDao.saveProject(oldProject);
    await storage.db.update(
      'tb_project',
      {'updatedAt': 10},
      where: 'id = ?',
      whereArgs: [oldProject.id],
    );
    final newProject = ProjectModel(name: '新项目')
      ..updatedAt = 30
      ..createdAt = 30;
    await projectDao.saveProject(newProject);
    await storage.db.update(
      'tb_project',
      {'updatedAt': 30},
      where: 'id = ?',
      whereArgs: [newProject.id],
    );

    final changes = await LocalSyncService(storage).exportChanges(
      updatedAfter: 20,
    );

    expect(changes.map((c) => c.key), contains('project:${newProject.id}'));
    expect(
        changes.map((c) => c.key), isNot(contains('project:${oldProject.id}')));
    expect(changes.singleWhere((c) => c.entity == 'project').payload['name'],
        '新项目');
    await storage.db.close();
  });

  test('应用远端变更：较新写入、陈旧拒绝、同时间冲突、删除生效', () async {
    final storage = await newDb();
    final dao = await ConversationListDao.create(storage);
    for (final item in [
      (cid: 1, title: '本地旧标题', updateAt: 10),
      (cid: 2, title: '本地较新', updateAt: 30),
      (cid: 3, title: '本地冲突', updateAt: 40),
      (cid: 4, title: '待删除', updateAt: 10),
    ]) {
      await dao.saveConversation(ConversationModel(cid: item.cid, icon: '')
        ..title = item.title
        ..stickTime = 0
        ..updateAt = item.updateAt);
    }

    final result = await LocalSyncService(storage).applyRemoteChanges([
      const SyncChange(
        entity: 'conversation',
        id: '1',
        op: SyncOp.upsert,
        updatedAt: 20,
        payload: {
          'cid': 1,
          'title': '远端新标题',
          'icon': '',
          'stickTime': 0,
          'updateAt': 20,
        },
      ),
      const SyncChange(
        entity: 'conversation',
        id: '2',
        op: SyncOp.upsert,
        updatedAt: 20,
        payload: {
          'cid': 2,
          'title': '远端陈旧',
          'icon': '',
          'stickTime': 0,
          'updateAt': 20,
        },
      ),
      const SyncChange(
        entity: 'conversation',
        id: '3',
        op: SyncOp.upsert,
        updatedAt: 40,
        payload: {
          'cid': 3,
          'title': '远端冲突',
          'icon': '',
          'stickTime': 0,
          'updateAt': 40,
        },
      ),
      const SyncChange(
        entity: 'conversation',
        id: '4',
        op: SyncOp.delete,
        updatedAt: 20,
      ),
    ]);

    expect(result.accepted.map((c) => c.id), containsAll(['1', '4']));
    expect(result.rejectedStale.map((c) => c.id), ['2']);
    expect(result.conflicts, ['conversation:3']);

    final rows = await storage.db.query(
      'tb_conversation_list',
      columns: ['cid', 'title', 'updateAt'],
      orderBy: 'cid',
    );
    expect(rows.map((r) => r['cid']), [1, 2, 3]);
    expect(rows.firstWhere((r) => r['cid'] == 1)['title'], '远端新标题');
    expect(rows.firstWhere((r) => r['cid'] == 2)['title'], '本地较新');
    expect(rows.firstWhere((r) => r['cid'] == 3)['title'], '本地冲突');
    await storage.db.close();
  });
}
