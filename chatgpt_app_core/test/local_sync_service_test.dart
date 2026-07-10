import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
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

  test('Story Room 三表导出使用 updatedAt，并由同步服务初始化表', () async {
    final storage = await newDb();
    final sync = LocalSyncService(storage);

    expect(await sync.exportChanges(), isEmpty);
    await storage.db.insert('tb_story_room', {
      'id': 1,
      'title': '旧房间',
      'mode': 'creation',
      'replyMode': 'autoSingle',
      'maxAutoReplies': 1,
      'publicContext': '',
      'createdAt': 10,
      'updatedAt': 10,
    });
    await storage.db.insert('tb_story_room', {
      'id': 2,
      'title': '新房间',
      'mode': 'tavern',
      'replyMode': 'autoMulti',
      'maxAutoReplies': 3,
      'publicContext': '海边酒馆',
      'createdAt': 20,
      'updatedAt': 30,
    });
    await storage.db.insert('tb_story_participant', {
      'id': 3,
      'roomId': 2,
      'assistantId': null,
      'role': 'assistant',
      'name': '角色',
      'prompt': '',
      'avatarType': null,
      'avatarValue': null,
      'sortOrder': 0,
      'enabled': 1,
      'createdAt': 20,
      'updatedAt': 31,
    });
    await storage.db.insert('tb_story_message', {
      'id': 4,
      'roomId': 2,
      'speakerId': 3,
      'speakerRole': 'assistant',
      'speakerName': '角色',
      'speakerAvatarType': null,
      'speakerAvatarValue': null,
      'content': '欢迎来到酒馆。',
      'nodeKey': 'welcome-node',
      'parentNodeKey': null,
      'candidateGroupKey': 'welcome-node',
      'contextStateAfter': '{"scene":"tavern"}',
      'createdAt': 20,
      'updatedAt': 32,
    });

    final changes = await sync.exportChanges(updatedAfter: 20);

    expect(
      changes.map((change) => change.key),
      containsAll([
        'story_room:2',
        'story_participant:3',
        'story_message:welcome-node',
      ]),
    );
    expect(
        changes.map((change) => change.key), isNot(contains('story_room:1')));
    expect(
      changes
          .singleWhere((change) => change.key == 'story_message:welcome-node')
          .updatedAt,
      32,
    );
    await storage.db.close();
  });

  test('Story Room 远端变更支持三表关联、删除和同时间戳冲突', () async {
    final storage = await newDb();
    final sync = LocalSyncService(storage);

    final result = await sync.applyRemoteChanges([
      const SyncChange(
        entity: 'story_room',
        id: '10',
        op: SyncOp.upsert,
        updatedAt: 100,
        payload: {
          'id': 10,
          'title': '远端房间',
          'mode': 'tavern',
          'replyMode': 'autoMulti',
          'maxAutoReplies': 2,
          'publicContext': '远端场景',
          'createdAt': 90,
          'updatedAt': 100,
        },
      ),
      const SyncChange(
        entity: 'story_participant',
        id: '20',
        op: SyncOp.upsert,
        updatedAt: 110,
        payload: {
          'id': 20,
          'roomId': 10,
          'assistantId': null,
          'role': 'assistant',
          'name': '远端角色',
          'prompt': '保持角色设定',
          'avatarType': 'emoji',
          'avatarValue': 'R',
          'sortOrder': 0,
          'enabled': 1,
          'createdAt': 100,
          'updatedAt': 110,
        },
      ),
      const SyncChange(
        entity: 'story_message',
        id: 'remote-message',
        op: SyncOp.upsert,
        updatedAt: 120,
        payload: {
          'id': 999,
          'roomId': 10,
          'speakerId': 20,
          'speakerRole': 'assistant',
          'speakerName': '远端角色',
          'speakerAvatarType': 'emoji',
          'speakerAvatarValue': 'R',
          'content': '远端消息',
          'nodeKey': 'remote-message',
          'parentNodeKey': null,
          'candidateGroupKey': 'remote-message',
          'contextStateAfter': '{"chapter":1}',
          'createdAt': 110,
          'updatedAt': 120,
        },
      ),
    ]);

    expect(result.accepted, hasLength(3));
    final participant = await storage.db.query(
      'tb_story_participant',
      where: 'id = ?',
      whereArgs: [20],
    );
    final message = await storage.db.query(
      'tb_story_message',
      where: 'nodeKey = ?',
      whereArgs: ['remote-message'],
    );
    expect(participant.single['roomId'], 10);
    expect(message.single['roomId'], 10);
    expect(message.single['speakerId'], 20);
    expect(message.single['id'], isNot(999));

    await storage.db.insert('tb_story_participant', {
      'id': 21,
      'roomId': 10,
      'assistantId': null,
      'role': 'narrator',
      'name': '待删除',
      'prompt': '',
      'avatarType': null,
      'avatarValue': null,
      'sortOrder': 1,
      'enabled': 1,
      'createdAt': 121,
      'updatedAt': 121,
    });
    await storage.db.insert('tb_story_room', {
      'id': 11,
      'title': '本地标题',
      'mode': 'creation',
      'replyMode': 'autoSingle',
      'maxAutoReplies': 1,
      'publicContext': '',
      'createdAt': 130,
      'updatedAt': 130,
    });

    final merge = await sync.applyRemoteChanges([
      const SyncChange(
        entity: 'story_participant',
        id: '21',
        op: SyncOp.delete,
        updatedAt: 122,
      ),
      const SyncChange(
        entity: 'story_room',
        id: '11',
        op: SyncOp.upsert,
        updatedAt: 130,
        payload: {
          'id': 11,
          'title': '远端冲突标题',
          'mode': 'creation',
          'replyMode': 'autoSingle',
          'maxAutoReplies': 1,
          'publicContext': '',
          'createdAt': 130,
          'updatedAt': 130,
        },
      ),
    ]);

    expect(
        merge.accepted.map((change) => change.key), ['story_participant:21']);
    expect(merge.conflicts, ['story_room:11']);
    expect(
      await storage.db
          .query('tb_story_participant', where: 'id = ?', whereArgs: [21]),
      isEmpty,
    );
    final localRoom = await storage.db.query(
      'tb_story_room',
      where: 'id = ?',
      whereArgs: [11],
    );
    expect(localRoom.single['title'], '本地标题');
    await storage.db.close();
  });

  test('Story Artifact 同步注册 updatedAt/createdAt，并支持远端 upsert/delete', () async {
    final storage = await newDb();
    final sync = LocalSyncService(storage);

    expect(await sync.exportChanges(), isEmpty);
    await storage.db.insert('tb_story_artifact', {
      'id': 1,
      'roomId': 7,
      'type': StoryArtifactType.outline,
      'title': '本地大纲',
      'content': '本地内容',
      'status': 'draft',
      'sortOrder': 0,
      'createdAt': 10,
      'updatedAt': 20,
    });
    await storage.db.insert('tb_story_artifact_revision', {
      'id': 2,
      'artifactId': 1,
      'title': '旧大纲',
      'content': '旧内容',
      'status': 'draft',
      'createdAt': 30,
    });

    final localChanges = await sync.exportChanges(updatedAfter: 15);
    expect(
      localChanges.map((change) => change.key),
      containsAll(['story_artifact:1', 'story_artifact_revision:2']),
    );
    expect(
      localChanges
          .singleWhere((change) => change.entity == 'story_artifact')
          .updatedAt,
      20,
    );
    expect(
      localChanges
          .singleWhere((change) => change.entity == 'story_artifact_revision')
          .updatedAt,
      30,
    );

    final upsert = await sync.applyRemoteChanges([
      const SyncChange(
        entity: 'story_artifact',
        id: '10',
        op: SyncOp.upsert,
        updatedAt: 100,
        payload: {
          'id': 10,
          'roomId': 8,
          'type': 'chapter',
          'title': '远端章节',
          'content': '远端内容',
          'status': 'final',
          'sortOrder': 1,
          'createdAt': 90,
          'updatedAt': 100,
        },
      ),
      const SyncChange(
        entity: 'story_artifact_revision',
        id: '20',
        op: SyncOp.upsert,
        updatedAt: 110,
        payload: {
          'id': 20,
          'artifactId': 10,
          'title': '远端章节旧稿',
          'content': '远端旧内容',
          'status': 'draft',
          'createdAt': 110,
        },
      ),
    ]);
    expect(upsert.accepted.map((change) => change.key), [
      'story_artifact:10',
      'story_artifact_revision:20',
    ]);
    expect(
        (await storage.db
                .query('tb_story_artifact', where: 'id = ?', whereArgs: [10]))
            .single['roomId'],
        8);
    expect(
        (await storage.db.query('tb_story_artifact_revision',
                where: 'id = ?', whereArgs: [20]))
            .single['artifactId'],
        10);

    final deletion = await sync.applyRemoteChanges([
      const SyncChange(
        entity: 'story_artifact',
        id: '10',
        op: SyncOp.delete,
        updatedAt: 120,
      ),
      const SyncChange(
        entity: 'story_artifact_revision',
        id: '20',
        op: SyncOp.delete,
        updatedAt: 121,
      ),
    ]);
    expect(deletion.accepted.map((change) => change.key), [
      'story_artifact:10',
      'story_artifact_revision:20',
    ]);
    expect(
        await storage.db
            .query('tb_story_artifact', where: 'id = ?', whereArgs: [10]),
        isEmpty);
    expect(
        await storage.db.query('tb_story_artifact_revision',
            where: 'id = ?', whereArgs: [20]),
        isEmpty);
    await storage.db.close();
  });

  test('翻译任务按 updatedAt 同步，远端 upsert/delete 只写任务记录', () async {
    final storage = await newDb();
    final taskDao = await StoryTemplateTranslationTaskDao.create(storage);
    final localTask = StoryTemplateTranslationTaskModel(
      templateId: 7,
      sourceTitle: '本地英文酒馆',
      sourcePayload: '{}',
      status: StoryTemplateTranslationTaskStatus.running,
    );
    await taskDao.saveTask(localTask);
    await storage.db.update(
      'tb_story_template_translation_task',
      {'updatedAt': 30},
      where: 'id = ?',
      whereArgs: [localTask.id],
    );

    final sync = LocalSyncService(storage);
    final localChanges = await sync.exportChanges(updatedAfter: 20);
    final localChange = localChanges.singleWhere(
      (change) => change.entity == 'story_template_translation_task',
    );
    expect(localChange.updatedAt, 30);
    expect(localChange.payload['status'],
        StoryTemplateTranslationTaskStatus.running);

    final upsert = await sync.applyRemoteChanges([
      const SyncChange(
        entity: 'story_template_translation_task',
        id: '99',
        op: SyncOp.upsert,
        updatedAt: 100,
        payload: {
          'id': 99,
          'templateId': 8,
          'sourceTitle': '远端英文酒馆',
          'sourcePayload': '{}',
          'outputTitle': '',
          'outputTemplateId': null,
          'status': 'running',
          'progress': 0.5,
          'stage': '翻译中',
          'detail': '',
          'log': '',
          'error': '',
          'roleIndex': 1,
          'roleTotal': 2,
          'roleName': '',
          'fieldIndex': 0,
          'fieldTotal': 0,
          'fieldLabel': '',
          'fieldProgress': 0.0,
          'partialPayload': '{}',
          'createdAt': 90,
          'updatedAt': 100,
        },
      ),
    ]);
    expect(upsert.accepted.map((change) => change.key), [
      'story_template_translation_task:99',
    ]);
    final remoteTask = (await storage.db.query(
      'tb_story_template_translation_task',
      where: 'id = ?',
      whereArgs: [99],
    ))
        .single;
    expect(remoteTask['status'], StoryTemplateTranslationTaskStatus.running);
    expect(remoteTask['stage'], '翻译中');

    final deletion = await sync.applyRemoteChanges([
      const SyncChange(
        entity: 'story_template_translation_task',
        id: '99',
        op: SyncOp.delete,
        updatedAt: 110,
      ),
    ]);
    expect(deletion.accepted.map((change) => change.key), [
      'story_template_translation_task:99',
    ]);
    expect(
      await storage.db.query(
        'tb_story_template_translation_task',
        where: 'id = ?',
        whereArgs: [99],
      ),
      isEmpty,
    );
    await storage.db.close();
  });

  test('Story Room 本地删除导出墓碑并在远端确认后清理', () async {
    final storage = await newDb();
    final dao = await StoryRoomDao.create(storage);
    final sync = LocalSyncService(storage);
    await sync.exportChanges();
    final room = StoryRoomModel(title: '待同步删除');
    final roomId = await dao.saveRoom(room);
    final participant = StoryParticipantModel(
      roomId: roomId,
      role: StoryParticipantRole.assistant,
      name: '角色',
    );
    await dao.saveParticipant(participant);
    final message = StoryMessageModel(
      roomId: roomId,
      speakerId: participant.id,
      speakerRole: StoryParticipantRole.assistant,
      speakerName: participant.name,
      content: '即将删除',
    );
    await dao.saveMessage(message);

    await dao.deleteRoom(roomId);
    final changes = await sync.exportChanges();
    final deletes = changes.where((change) => change.op == SyncOp.delete);
    expect(
      deletes.map((change) => change.key),
      containsAll([
        'story_room:$roomId',
        'story_participant:${participant.id}',
        'story_message:${message.nodeKey}',
      ]),
    );

    await sync.applyRemoteChanges(deletes);
    final afterAck = await sync.exportChanges();
    expect(
      afterAck.where((change) => change.op == SyncOp.delete),
      isEmpty,
    );
    await storage.db.close();
  });

  test('story_message 以 nodeKey 合并，保留本机 id 并往返分支状态', () async {
    final sourceDir =
        await Directory.systemTemp.createTemp('sync-node-source-');
    final targetDir =
        await Directory.systemTemp.createTemp('sync-node-target-');
    final source = HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${sourceDir.path}/sync.db'),
    );
    final target = HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${targetDir.path}/sync.db'),
    );
    try {
      final sourceSync = LocalSyncService(source);
      final targetSync = LocalSyncService(target);
      await sourceSync.exportChanges();
      await targetSync.exportChanges();
      await source.db.insert('tb_story_room', {
        'id': 7,
        'title': '源房间',
        'mode': 'creation',
        'replyMode': 'autoSingle',
        'maxAutoReplies': 1,
        'publicContext': '',
        'worldBookState': '{"chapter":2}',
        'activeMessageKey': 'shared-node',
        'createdAt': 1,
        'updatedAt': 200,
      });
      await source.db.insert('tb_story_message', {
        'id': 41,
        'roomId': 7,
        'speakerId': null,
        'speakerRole': 'assistant',
        'speakerName': '源设备',
        'speakerAvatarType': null,
        'speakerAvatarValue': null,
        'content': '稳定节点',
        'nodeKey': 'shared-node',
        'parentNodeKey': 'parent-node',
        'candidateGroupKey': 'candidate-group',
        'contextStateAfter': '{"chapter":2}',
        'createdAt': 100,
        'updatedAt': 200,
      });
      await target.db.insert('tb_story_message', {
        'id': 7,
        'roomId': 7,
        'speakerId': null,
        'speakerRole': 'assistant',
        'speakerName': '目标设备',
        'speakerAvatarType': null,
        'speakerAvatarValue': null,
        'content': '旧内容',
        'nodeKey': 'shared-node',
        'parentNodeKey': null,
        'candidateGroupKey': 'old-group',
        'contextStateAfter': '',
        'createdAt': 100,
        'updatedAt': 100,
      });

      final change = (await sourceSync.exportChanges()).singleWhere(
        (item) => item.entity == 'story_message',
      );
      expect(change.id, 'shared-node');
      expect(change.payload['id'], 41);
      expect(change.payload['parentNodeKey'], 'parent-node');
      expect(change.payload['candidateGroupKey'], 'candidate-group');
      expect(change.payload['contextStateAfter'], '{"chapter":2}');

      await targetSync.applyRemoteChanges([change]);
      final rows = await target.db.query(
        'tb_story_message',
        where: 'nodeKey = ?',
        whereArgs: ['shared-node'],
      );
      expect(rows, hasLength(1));
      expect(rows.single['id'], 7);
      expect(rows.single['content'], '稳定节点');
      expect(rows.single['parentNodeKey'], 'parent-node');
      expect(rows.single['candidateGroupKey'], 'candidate-group');
      expect(rows.single['contextStateAfter'], '{"chapter":2}');

      final sameTimestamp = await targetSync.applyRemoteChanges([change]);
      expect(sameTimestamp.conflicts, isEmpty);
      expect(sameTimestamp.accepted.single.key, 'story_message:shared-node');
    } finally {
      await source.db.close();
      await target.db.close();
      await sourceDir.delete(recursive: true);
      await targetDir.delete(recursive: true);
    }
  });

  test('活动节点缺失时回退最新节点，删除新 tombstone 后恢复快照并清空房间', () async {
    final storage = await newDb();
    try {
      final sync = LocalSyncService(storage);
      await sync.applyRemoteChanges([
        const SyncChange(
          entity: 'story_room',
          id: '10',
          op: SyncOp.upsert,
          updatedAt: 300,
          payload: {
            'id': 10,
            'title': '分支房间',
            'mode': 'creation',
            'replyMode': 'autoSingle',
            'maxAutoReplies': 1,
            'publicContext': '',
            'worldBookState': '错误快照',
            'activeMessageKey': 'missing-node',
            'createdAt': 1,
            'updatedAt': 300,
          },
        ),
        const SyncChange(
          entity: 'story_message',
          id: 'node-b',
          op: SyncOp.upsert,
          updatedAt: 200,
          payload: {
            'id': 900,
            'roomId': 10,
            'speakerRole': 'assistant',
            'speakerName': '乙',
            'content': '后续',
            'nodeKey': 'node-b',
            'parentNodeKey': 'node-a',
            'candidateGroupKey': 'node-b',
            'contextStateAfter': 'state-b',
            'createdAt': 200,
            'updatedAt': 200,
          },
        ),
        const SyncChange(
          entity: 'story_message',
          id: 'node-a',
          op: SyncOp.upsert,
          updatedAt: 100,
          payload: {
            'id': 901,
            'roomId': 10,
            'speakerRole': 'user',
            'speakerName': '我',
            'content': '起点',
            'nodeKey': 'node-a',
            'parentNodeKey': null,
            'candidateGroupKey': 'node-a',
            'contextStateAfter': 'state-a',
            'createdAt': 100,
            'updatedAt': 100,
          },
        ),
      ]);
      var room = (await storage.db.query(
        'tb_story_room',
        where: 'id = ?',
        whereArgs: [10],
      ))
          .single;
      expect(room['activeMessageKey'], 'node-b');
      expect(room['worldBookState'], 'state-b');

      final deleted = await sync.applyRemoteChanges([
        const SyncChange(
          entity: 'story_message',
          id: 'node-b',
          op: SyncOp.delete,
          updatedAt: 400,
        ),
      ]);
      expect(deleted.accepted.single.key, 'story_message:node-b');
      room = (await storage.db.query(
        'tb_story_room',
        where: 'id = ?',
        whereArgs: [10],
      ))
          .single;
      expect(room['activeMessageKey'], 'node-a');
      expect(room['worldBookState'], 'state-a');

      await sync.applyRemoteChanges([
        const SyncChange(
          entity: 'story_message',
          id: 'node-a',
          op: SyncOp.delete,
          updatedAt: 500,
        ),
      ]);
      room = (await storage.db.query(
        'tb_story_room',
        where: 'id = ?',
        whereArgs: [10],
      ))
          .single;
      expect(room['activeMessageKey'], isNull);
      expect(room['worldBookState'], '');
    } finally {
      await storage.db.close();
    }
  });

  test('兼容旧整数 story_message 删除事件，但不把整数当 nodeKey', () async {
    final storage = await newDb();
    try {
      final sync = LocalSyncService(storage);
      await sync.exportChanges();
      await storage.db.insert('tb_story_room', {
        'id': 12,
        'title': '旧同步房间',
        'mode': 'creation',
        'replyMode': 'autoSingle',
        'maxAutoReplies': 1,
        'publicContext': '',
        'createdAt': 1,
        'updatedAt': 1,
      });
      await storage.db.insert('tb_story_message', {
        'id': 55,
        'roomId': 12,
        'speakerRole': 'user',
        'speakerName': '我',
        'content': '旧消息',
        'nodeKey': 'legacy-stable-key',
        'candidateGroupKey': 'legacy-stable-key',
        'contextStateAfter': '',
        'createdAt': 1,
        'updatedAt': 1,
      });
      final result = await sync.applyRemoteChanges([
        const SyncChange(
          entity: 'story_message',
          id: '55',
          op: SyncOp.delete,
          updatedAt: 2,
        ),
      ]);
      expect(result.accepted.single.key, 'story_message:55');
      expect(await storage.db.query('tb_story_message'), isEmpty);
    } finally {
      await storage.db.close();
    }
  });

  test('CHARX 资源按稳定块同步、完整聚合，并在空清单时清理托管文件', () async {
    final source = await newDb();
    final target = await newDb();
    final sourceDir = await Directory.systemTemp.createTemp('sync-charx-src-');
    final targetDir = await Directory.systemTemp.createTemp('sync-charx-dst-');
    try {
      final dao = await AssistantDao.create(source);
      final assistant = AssistantModel(name: 'CHARX 同步角色');
      final assistantId = (await dao.saveAssistant(assistant))!;
      final bytes = Uint8List.fromList(
        List<int>.generate(192 * 1024 + 7, (index) => index % 251),
      );
      final manifest = await AssistantRoleCardAssetStore.save(
        assistantId: assistantId,
        directoryResolver: () async => sourceDir,
        resources: [
          AssistantRoleCardResource(
            type: 'background',
            uri: 'embeded://assets/background.bin',
            name: 'background',
            ext: 'bin',
            archivePath: 'assets/background.bin',
            size: bytes.length,
            bytes: bytes,
          ),
        ],
      );
      await source.db.update(
        'tb_assistant',
        {'roleCardAssets': manifest, 'updatedAt': 100},
        where: 'id = ?',
        whereArgs: [assistantId],
      );

      final sourceSync = LocalSyncService(
        source,
        roleCardAssetDirectoryResolver: () async => sourceDir,
      );
      final changes = await sourceSync.exportChanges(updatedAfter: 99);
      final assistantChange = changes.singleWhere(
        (change) => change.entity == 'assistant',
      );
      final chunks = changes
          .where((change) =>
              change.entity == LocalSyncService.assistantRoleAssetChunkEntity)
          .toList();
      expect(assistantChange.payload['roleCardAssets'], '[]');
      expect(chunks, hasLength(2));
      expect(chunks.map((change) => change.id), [
        '$assistantId:0:0',
        '$assistantId:0:1',
      ]);
      expect(chunks.first.payload['assistantUpdatedAt'], 100);

      final targetSync = LocalSyncService(
        target,
        roleCardAssetDirectoryResolver: () async => targetDir,
      );
      final partial = await targetSync.applyRemoteChanges([
        assistantChange,
        chunks.first,
      ]);
      expect(partial.rejectedStale, isEmpty);
      expect(partial.accepted, hasLength(2));
      final beforeComplete = await target.db.query(
        'tb_assistant',
        where: 'id = ?',
        whereArgs: [assistantId],
      );
      expect(beforeComplete.single['roleCardAssets'], '[]');

      final complete = await targetSync.applyRemoteChanges([chunks.last]);
      expect(complete.accepted.single.id, '$assistantId:0:1');
      final synced = (await target.db.query(
        'tb_assistant',
        where: 'id = ?',
        whereArgs: [assistantId],
      ))
          .single;
      final restored = await AssistantRoleCardAssetStore.load(
        synced['roleCardAssets'] as String,
        directoryResolver: () async => targetDir,
      );
      expect(restored.single.bytes, bytes);

      final emptyPayload = Map<String, dynamic>.from(assistantChange.payload)
        ..['updatedAt'] = 200
        ..['roleCardAssets'] = '[]';
      final cleared = await targetSync.applyRemoteChanges([
        SyncChange(
          entity: 'assistant',
          id: '$assistantId',
          op: SyncOp.upsert,
          updatedAt: 200,
          payload: emptyPayload,
        ),
      ]);
      expect(cleared.accepted.single.key, 'assistant:$assistantId');
      expect(
        Directory(
          '${targetDir.path}/${AssistantRoleCardAssetStore.directoryName}/$assistantId',
        ).existsSync(),
        isFalse,
      );
    } finally {
      await source.db.close();
      await target.db.close();
      await sourceDir.delete(recursive: true);
      await targetDir.delete(recursive: true);
    }
  });

  test('CHARX 完整暂存包写盘失败后会在下次同步重试', () async {
    final storage = await newDb();
    final dir = await Directory.systemTemp.createTemp('sync-charx-retry-');
    var failWrite = true;
    try {
      final dao = await AssistantDao.create(storage);
      final assistantId =
          (await dao.saveAssistant(AssistantModel(name: '恢复角色')))!;
      await storage.db.update(
        'tb_assistant',
        {'updatedAt': 100, 'roleCardAssets': '[]'},
        where: 'id = ?',
        whereArgs: [assistantId],
      );
      final sync = LocalSyncService(
        storage,
        roleCardAssetDirectoryResolver: () async {
          if (failWrite) throw Exception('磁盘暂时不可用');
          return dir;
        },
      );
      final chunk = SyncChange(
        entity: LocalSyncService.assistantRoleAssetChunkEntity,
        id: '$assistantId:0:0',
        op: SyncOp.upsert,
        updatedAt: 100,
        payload: {
          'assistantId': assistantId,
          'assetIndex': 0,
          'chunkIndex': 0,
          'totalChunks': 1,
          'assetCount': 1,
          'assistantUpdatedAt': 100,
          'metadata': {
            'type': 'audio',
            'name': 'voice',
            'ext': 'ogg',
            'size': 3,
          },
          'base64': base64Encode([1, 2, 3]),
        },
      );

      final staged = await sync.applyRemoteChanges([chunk]);
      expect(staged.accepted.single.id, chunk.id);
      expect(
        (await storage.db.query(
          'tb_assistant',
          where: 'id = ?',
          whereArgs: [assistantId],
        ))
            .single['roleCardAssets'],
        '[]',
      );

      failWrite = false;
      await sync.applyRemoteChanges(const []);
      final row = (await storage.db.query(
        'tb_assistant',
        where: 'id = ?',
        whereArgs: [assistantId],
      ))
          .single;
      final restored = await AssistantRoleCardAssetStore.load(
        row['roleCardAssets'] as String,
        directoryResolver: () async => dir,
      );
      expect(restored.single.bytes, [1, 2, 3]);
    } finally {
      await storage.db.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });
}
