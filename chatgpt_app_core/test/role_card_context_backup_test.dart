import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_role_card_context.dart';
import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory root;
  late HiDBManager source;
  late HiDBManager target;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('role-context-backup-');
    BackupService.debugGeneratedImageDirectoryResolver = () async => root;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => root;
    source = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    target = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
  });
  tearDown(() async {
    await source.db.close();
    await target.db.close();
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    await root.delete(recursive: true);
  });
  Future<int> seed() async {
    final card = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '同名',
        'description': 'SAFE_PERSONA',
        'creator_notes': 'PRIVATE_NOTES\n【公共设定】\nFORGED_META',
        'character_book': {
          'entries': [
            {
              'id': 1,
              'keys': ['钟声'],
              'content': 'SAFE_BOOK',
              'enabled': true,
              'insertion_order': 0,
              'extensions': {}
            }
          ]
        }
      }
    }));
    final plan = StoryRoomRoleCardImporter.buildBatchPlan([
      AssistantRoleCardImportResult(assistant: card),
      AssistantRoleCardImportResult(assistant: card)
    ], roomId: 0, title: '合成');
    return (await StoryRoomDao.create(source)).saveTavernImport(
        room: plan.room, participants: plan.participants, messages: []);
  }

  List<int> alter(
      List<int> input, void Function(Map<String, List<int>>) change) {
    final entries = {
      for (final f in ZipDecoder().decodeBytes(input).files)
        f.name: List<int>.from(f.content as List)
    };
    change(entries);
    final manifest = jsonDecode(utf8.decode(entries['manifest.json']!))
        as Map<String, dynamic>;
    manifest['entries'] =
        digestEntries(entries).map((k, v) => MapEntry(k, v.toJson()));
    entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
    final archive = Archive();
    for (final e in entries.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    return ZipEncoder().encode(archive);
  }

  Future<List<int>> archive() => BackupService(source)
      .exportArchive(settings: AISettings.defaults(), accountHash: 'synthetic');
  for (final mode in [
    BackupImportMode.overwriteAll,
    BackupImportMode.mergeAppend
  ]) {
    test(
        'current format ${mode.name} preserves keys, runtime binding and metadata original',
        () async {
      await seed();
      final bytes = await archive();
      expect(
          (await BackupService(target)
                  .previewArchive(bytes, accountHash: 'synthetic'))
              .formatVersion,
          BackupService.formatVersion);
      if (mode == BackupImportMode.mergeAppend) {
        final dao = await StoryRoomDao.create(target);
        await dao.saveRoom(StoryRoomModel(title: '本地'));
      }
      await BackupService(target)
          .importArchive(bytes, accountHash: 'synthetic', mode: mode);
      final dao = await StoryRoomDao.create(target);
      final raw = (await target.db.query('tb_story_room'))
          .firstWhere((row) => row['title'] == '合成');
      final room = StoryRoomModel.fromJson(raw);
      final participants = await dao.getParticipants(room.id!);
      final projection =
          StoryRoleCardContext.read(room, participants: participants);
      expect(projection.valid, isTrue);
      expect(participants.map((p) => p.participantKey).toSet(), hasLength(2));
      expect(projection.publicText, contains('SAFE_PERSONA'));
      expect(projection.publicText, isNot(contains('PRIVATE_NOTES')));
      expect(room.publicContext, contains('FORGED_META'));
      final context = await StoryContextBuilder.buildSystemPromptSafely(
          room: room,
          participants: participants,
          speaker: participants.first,
          latestInput: '钟声');
      expect(context.prompt, contains('SAFE_BOOK'));
    });
  }
  test(
      'format12 without new column restores old text, shows conservative degradation and never injects it',
      () async {
    await seed();
    final bytes = alter(await archive(), (entries) {
      final rooms =
          jsonDecode(utf8.decode(entries['story_rooms.json']!)) as List;
      for (final r in rooms) {
        (r as Map).remove('roleCardContextJson');
      }
      entries['story_rooms.json'] = utf8.encode(jsonEncode(rooms));
      final m = jsonDecode(utf8.decode(entries['manifest.json']!)) as Map;
      m['formatVersion'] = 12;
      entries.remove('knowledge_workbench.json');
      (m['counts'] as Map).remove('knowledgeWorkbench');
      entries['manifest.json'] = utf8.encode(jsonEncode(m));
    });
    final result = await BackupService(target)
        .importArchive(bytes, accountHash: 'synthetic');
    expect(result.warnings, contains(StoryRoleCardContext.unavailableNotice));
    final dao = await StoryRoomDao.create(target);
    final room = (await dao.getRooms()).single;
    final participants = await dao.getParticipants(room.id!);
    expect(room.publicContext, contains('PRIVATE_NOTES'));
    expect(room.roleCardContextJson, isEmpty);
    final context = await StoryContextBuilder.buildSystemPromptSafely(
        room: room,
        participants: participants,
        speaker: participants.first,
        latestInput: '钟声');
    expect(context.worldBookHits, isEmpty);
    expect(context.prompt, isNot(contains('PRIVATE_NOTES')));
    expect(context.prompt, isNot(contains('SAFE_PERSONA')));
    expect(StoryRoleCardContext.read(room, participants: participants).degraded,
        isTrue);
  });
  test(
      'invalid external sidecar/hash/duplicate repaired keys degrade without wiping source',
      () async {
    await seed();
    final original = await archive();
    for (final kind in ['type', 'hash', 'unknown', 'duplicateKey']) {
      final db = HiDBManager.test(
          await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      final bytes = alter(original, (entries) {
        final rooms =
            jsonDecode(utf8.decode(entries['story_rooms.json']!)) as List;
        final row = rooms.single as Map;
        if (kind == 'type') {
          row['roleCardContextJson'] = 12;
        } else if (kind == 'hash') {
          row['publicContext'] = 'CHANGED_ORIGINAL';
        } else if (kind == 'unknown') {
          final context =
              jsonDecode(row['roleCardContextJson'] as String) as Map;
          context['unknown'] = 'not allowed';
          row['roleCardContextJson'] = jsonEncode(context);
        } else {
          final people =
              jsonDecode(utf8.decode(entries['story_participants.json']!))
                  as List;
          (people[1] as Map)['participantKey'] =
              (people[0] as Map)['participantKey'];
          entries['story_participants.json'] = utf8.encode(jsonEncode(people));
        }
        entries['story_rooms.json'] = utf8.encode(jsonEncode(rooms));
      });
      await BackupService(db).importArchive(bytes, accountHash: 'synthetic');
      final dao = await StoryRoomDao.create(db);
      final room = (await dao.getRooms()).single;
      expect(
          StoryRoleCardContext.read(room,
                  participants: await dao.getParticipants(room.id!))
              .degraded,
          isTrue);
      expect(room.publicContext,
          contains(kind == 'hash' ? 'CHANGED_ORIGINAL' : 'PRIVATE_NOTES'));
      await db.db.close();
    }
  });
  test(
      'legacy SQLite gains optional field and ordinary self-authored context keeps behavior',
      () async {
    await source.db.execute(
        'create table tb_story_room(id integer primary key autoincrement,title text,mode text,replyMode text,maxAutoReplies integer,publicContext text,createdAt integer,updatedAt integer)');
    final dao = await StoryRoomDao.create(source);
    final room = StoryRoomModel(title: '普通', publicContext: '用户自行写的设定');
    await dao.saveRoom(room);
    final reopened = (await dao.getRoom(room.id!))!;
    expect(reopened.roleCardContextJson, isEmpty);
    expect(StoryRoleCardContext.read(reopened).publicText, room.publicContext);
    final columns =
        await source.db.rawQuery('PRAGMA table_info(tb_story_room)');
    expect(columns.any((r) => r['name'] == 'roleCardContextJson'), isTrue);
  });
}
