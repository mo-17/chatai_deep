import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 历史 schema2 业务表，不从新实现反推。字段值/NULL由升级前快照确认。
const oldDefinitions = {
  'tb_conversation_list':
      'id integer primary key autoincrement, cid integer, title text, icon text, updateAt integer, messageCount integer, lastMessage text, stickTime integer, assistantId integer, projectId integer, avatarType text, avatarValue text, modelProviderId text, modelId text, webSearchEnabled integer, deepSeekReasoningEffort text, toolIds text, speechInputEnabled integer, readAloudEnabled integer, voiceLocale text, voiceRate real, voiceStyle text, readAloudTriggerMode text, roleScene text, roleRelationship text, roleToneNote text',
  'tb_assistant':
      'id integer primary key autoincrement, name text, emoji text, avatarType text, avatarValue text, prompt text, description text, openingMessage text, exampleDialogs text, memoryBook text, worldBookJson text, roleCardAssets text, defaultVoiceStyle text, providerId text, model text, useTools integer, tools text, createdAt integer, updatedAt integer',
  'tb_project':
      'id integer primary key autoincrement, name text not null, icon text, color integer, sortOrder integer, defaultProviderId text, defaultModelId text, defaultAssistantId integer, defaultUseWebSearch integer, defaultToolIds text, createdAt integer, updatedAt integer',
  'tb_story_room':
      'id integer primary key autoincrement, title text, mode text, replyMode text, maxAutoReplies integer, speakerStrategy text, avoidRepeatSpeaker integer, maxAutoTotalTokens integer, publicContext text, worldBookState text, roleCardContextJson text, promptConfigJson text, quickRepliesJson text, regexScriptsJson text, tavernPresetJson text, personaKey text, webSearchEnabled integer, modelProviderId text, modelId text, temperature real, topP real, maxOutputTokens integer, activeMessageKey text, tavernChatMetadataJson text, createdAt integer, updatedAt integer',
  'tb_story_participant':
      'id integer primary key autoincrement, roomId integer not null, assistantId integer, role text, name text, prompt text, avatarType text, avatarValue text, voiceStyle text, modelProviderId text, modelId text, temperature real, topP real, maxOutputTokens integer, participantKey text not null, stateSummary text, sortOrder integer, enabled integer, createdAt integer, updatedAt integer',
};
const tables = [
  'tb_conversation_list',
  'tb_assistant',
  'tb_project',
  'tb_story_room',
  'tb_story_participant'
];
Map<String, dynamic> pair(
        [String provider = 'alpha',
        String origin = 'http://127.0.0.1:39991']) =>
    {
      'version': 1,
      'mode': 'pair',
      'providerCode': provider,
      'modelId': 'same/model',
      'scope': {'accountHash': 'account-a', 'origin': origin},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final resources = <Map<String, Object?>>[];
  final connections = <Database>[];
  late Directory owned;
  late _SecretStore secrets;
  final network = _NoNetwork();
  int next = 0;
  setUpAll(() {
    sqfliteFfiInit();
    final nonce = Platform.environment['R2B_SQLITE_NONCE']!;
    owned = Directory(Platform.environment['R2B_SQLITE_ROOT']!);
    expect(owned.path, '/tmp/chatai-r2b-sqlite-$nonce');
    expect(
        jsonDecode(
            File('${owned.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    HttpOverrides.global = network;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    AISettingsDao.resetSecureStateForTest();
    secrets = _SecretStore();
    AISettingsDao.configureSecretStore(secrets);
  });
  tearDown(() {
    AISettingsDao.resetSecureStateForTest();
  });
  tearDownAll(() async {
    for (final db in connections) {
      if (db.isOpen) await db.close();
    }
    for (final resource in resources) {
      resource['closed'] = true;
    }
    expect(network.calls, 0);
    HttpOverrides.global = null;
    File('${owned.path}/cleanup.json').writeAsStringSync(
        jsonEncode({'databases': resources, 'networkCalls': network.calls}));
    debugPrint(
        'R2b owned SQLite closed ${jsonEncode(resources)}; SUT HTTP calls=${network.calls}');
  });
  Future<HiDBManager> open({bool old = false}) async {
    final path = '${owned.path}/case-${next++}.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    connections.add(db);
    resources.add({'path': path, 'closed': false});
    await db.execute('pragma user_version=2');
    if (old) {
      for (final entry in oldDefinitions.entries) {
        await db.execute('create table ${entry.key} (${entry.value})');
      }
    }
    return HiDBManager.test(db);
  }

  Future<void> initialize(HiDBManager storage) async {
    await DbMigration.run(storage.db);
    await ConversationListDao.create(storage);
    await AssistantDao.create(storage);
    await ProjectDao.create(storage);
    await StoryRoomDao.create(storage);
  }

  Future<void> installedColumnFixture(HiDBManager storage) async {
    // 已有新列但旧代码读取的兼容路径；单独的升级用例不调用本夹具。
    for (final table in tables) {
      await SchemaGuard.ensureColumns(storage.db,
          table: table, columns: const {'backendSelection': 'text'});
    }
  }

  Future<void> seed(HiDBManager storage) async {
    await storage.db.insert(tables[0], {
      'id': 1,
      'cid': 71,
      'title': 'history',
      'icon': 'x',
      'stickTime': 0,
      'updateAt': 2,
      'modelProviderId': 'local-a',
      'modelId': 'legacy-model'
    });
    await storage.db.insert(tables[1], {
      'id': 1,
      'name': 'role',
      'emoji': 'r',
      'prompt': 'p',
      'providerId': 'local-a',
      'model': 'legacy-model',
      'useTools': 1,
      'createdAt': 1,
      'updatedAt': 2
    });
    await storage.db.insert(tables[2], {
      'id': 1,
      'name': 'project',
      'icon': 'p',
      'color': 7,
      'sortOrder': 0,
      'defaultProviderId': 'local-a',
      'defaultModelId': 'legacy-model',
      'createdAt': 1,
      'updatedAt': 2
    });
    await storage.db.insert(tables[3], {
      'id': 1,
      'title': 'room',
      'mode': StoryRoomMode.creation,
      'replyMode': StoryReplyMode.autoSingle,
      'speakerStrategy': StorySpeakerStrategy.smart,
      'modelProviderId': 'local-a',
      'modelId': 'legacy-model',
      'tavernChatMetadataJson': '{"header":"unchanged"}',
      'promptConfigJson': '{"thirdParty":"unchanged"}',
      'createdAt': 1,
      'updatedAt': 2
    });
    await storage.db.insert(tables[4], {
      'id': 1,
      'roomId': 1,
      'participantKey': 'person-1',
      'name': 'person',
      'role': 'role',
      'modelProviderId': 'local-a',
      'modelId': 'legacy-model',
      'createdAt': 1,
      'updatedAt': 2
    });
  }

  Map<String, dynamic> roundtrip(String table, Map<String, dynamic> row) =>
      switch (table) {
        'tb_conversation_list' => ConversationModel.fromJson(row).toJson(),
        'tb_assistant' => AssistantModel.fromJson(row).toJson(),
        'tb_project' => ProjectModel.fromJson(row).toJson(),
        'tb_story_room' =>
          StoryRoomModel.fromJson(row).copyWith(title: 'room').toJson(),
        'tb_story_participant' => StoryParticipantModel.fromJson(row).toJson(),
        _ => throw StateError('unexpected fixture table'),
      };
  Future<void> save(
      String table, HiDBManager storage, Map<String, dynamic> row) async {
    switch (table) {
      case 'tb_conversation_list':
        await (await ConversationListDao.create(storage))
            .saveConversation(ConversationModel.fromJson(row));
      case 'tb_assistant':
        await (await AssistantDao.create(storage))
            .saveAssistant(AssistantModel.fromJson(row));
      case 'tb_project':
        await (await ProjectDao.create(storage))
            .saveProject(ProjectModel.fromJson(row));
      case 'tb_story_room':
        await (await StoryRoomDao.create(storage))
            .saveRoom(StoryRoomModel.fromJson(row));
      case 'tb_story_participant':
        await (await StoryRoomDao.create(storage))
            .saveParticipant(StoryParticipantModel.fromJson(row));
    }
  }

  test(
      'storage old schema2 upgrade keeps every old field/NULL/time and adds only five nullable TEXT values',
      () async {
    final storage = await open(old: true);
    await seed(storage);
    final before = {
      for (final table in tables) table: await storage.db.query(table)
    };
    await initialize(storage);
    for (final table in tables) {
      final info = await storage.db.rawQuery('pragma table_info($table)');
      final selected =
          info.where((r) => r['name'] == 'backendSelection').single;
      expect(selected['type'], 'TEXT');
      expect(selected['notnull'], 0);
      expect(selected['dflt_value'], isNull);
      final after = await storage.db.query(table);
      expect(after.single['backendSelection'], isNull);
      final without = Map<String, Object?>.from(after.single)
        ..remove('backendSelection');
      expect(without, before[table]!.single);
    }
    expect(
        (await storage.db.rawQuery('pragma user_version'))
            .single['user_version'],
        2);
    final usage = await storage.db.rawQuery('pragma table_info(tb_usage)');
    expect(usage.any((r) => r['name'] == 'backendSelection'), isFalse);
  });
  test(
      'storage repeat initialization is idempotent and missing story tables stay absent until DAO creation',
      () async {
    final storage = await open();
    await DbMigration.run(storage.db);
    expect(
        await storage.db.rawQuery(
            "select name from sqlite_master where name in ('tb_story_room','tb_story_participant')"),
        isEmpty);
    await initialize(storage);
    await initialize(storage);
    for (final table in tables) {
      expect(
          (await storage.db.rawQuery('pragma table_info($table)'))
              .where((r) => r['name'] == 'backendSelection'),
          hasLength(1));
    }
  });
  for (final table in tables) {
    test(
        'storage $table preserves follow/pair/foreign scope and original local fields through real save+reopen',
        () async {
      final storage = await open(old: true);
      await seed(storage);
      await initialize(storage);
      await installedColumnFixture(storage);
      for (final selection in [
        {'version': 1, 'mode': 'follow'},
        pair(),
        pair('beta', 'https://foreign.invalid')
      ]) {
        final row =
            Map<String, dynamic>.from((await storage.db.query(table)).single);
        row['backendSelection'] = jsonEncode(selection);
        expect(
            roundtrip(table, row)['backendSelection'], jsonEncode(selection));
        await save(table, storage, row);
        final saved = (await storage.db.query(table)).single;
        expect(jsonDecode(saved['backendSelection'] as String), selection);
        final local = table == 'tb_project'
            ? 'defaultProviderId'
            : table == 'tb_assistant'
                ? 'providerId'
                : 'modelProviderId';
        expect(saved[local], 'local-a');
      }
      final path = storage.db.path;
      await storage.db.close();
      final reopened = await databaseFactoryFfi.openDatabase(path);
      connections.add(reopened);
      expect(
          jsonDecode((await reopened.query(table)).single['backendSelection']
              as String),
          pair('beta', 'https://foreign.invalid'));
    });
    test(
        'storage $table keeps malformed/future raw value on unrelated clone/save and protects it from legacy NULL',
        () async {
      final storage = await open(old: true);
      await seed(storage);
      await initialize(storage);
      await installedColumnFixture(storage);
      for (final raw in [
        '{broken',
        ' {"version":9,"mode":"pair","token":"synthetic-private"} ',
        'null'
      ]) {
        await storage.db
            .update(table, {'backendSelection': raw}, where: 'id = 1');
        final row =
            Map<String, dynamic>.from((await storage.db.query(table)).single);
        expect(roundtrip(table, row)['backendSelection'], raw);
        await save(table, storage, row);
        expect((await storage.db.query(table)).single['backendSelection'], raw);
        final unrelatedLegacy = Map<String, dynamic>.from(row)
          ..['backendSelection'] = null;
        await save(table, storage, unrelatedLegacy);
        expect((await storage.db.query(table)).single['backendSelection'], raw);
      }
    });
  }
  test(
      'storage all five illegal BLOB references preserve bytes/type through unrelated model save',
      () async {
    final storage = await open(old: true);
    await seed(storage);
    await initialize(storage);
    await installedColumnFixture(storage);
    final raw = Uint8List.fromList([0, 255, 123, 2]);
    for (final table in tables) {
      await storage.db
          .update(table, {'backendSelection': raw}, where: 'id = 1');
      final row =
          Map<String, dynamic>.from((await storage.db.query(table)).single);
      expect(roundtrip(table, row)['backendSelection'], raw);
      await save(table, storage, row);
      expect((await storage.db.query(table)).single['backendSelection'], raw);
      expect(
          (await storage.db
                  .rawQuery('select typeof(backendSelection) as t from $table'))
              .single['t'],
          'blob');
    }
  });
  test(
      'storage global settings actual save/load/clone preserves pair and foreign scope without changing backendModel/local fields',
      () async {
    final settings = AISettings.fromJson(AISettings.defaults().toJson()
      ..['backendModel'] = 'legacy-backend'
      ..['backendSelection'] = pair('beta', 'https://foreign.invalid'));
    final local = settings.activeProviderId;
    await AISettingsDao.saveFor('account-a', settings);
    AISettingsDao.resetSecureStateForTest();
    AISettingsDao.configureSecretStore(secrets);
    final loaded = await AISettingsDao.loadForAsync('account-a');
    expect(loaded.toJson()['backendSelection'],
        pair('beta', 'https://foreign.invalid'));
    expect(loaded.clone().toJson()['backendSelection'],
        pair('beta', 'https://foreign.invalid'));
    expect(loaded.backendModel, 'legacy-backend');
    expect(loaded.activeProviderId, local);
    // 这里只存储；未把新 pair 偷接到旧 model-only transport/effectiveModel。
    loaded.mode = AIMode.backend;
    expect(loaded.effectiveModel, 'legacy-backend');
  });
  test(
      'storage global settings unrelated save never clears malformed/future JSON into legacy',
      () async {
    for (final raw in [
      '{broken',
      {'version': 9, 'mode': 'pair', 'token': 'synthetic-private'}
    ]) {
      final settings = AISettings.fromJson(
          AISettings.defaults().toJson()..['backendSelection'] = raw);
      expect(settings.clone().toJson()['backendSelection'], raw);
      settings.streamEnabled = false;
      await AISettingsDao.saveFor('account-a', settings);
      final loaded = await AISettingsDao.loadForAsync('account-a');
      expect(loaded.toJson()['backendSelection'], raw);
    }
  });
  test(
      'storage missing legacy settings selection stays absent; clone/new column do not choose provider',
      () {
    final original = AISettings.defaults().toJson();
    expect(original.containsKey('backendSelection'), isFalse);
    expect(AISettings.fromJson(original).clone().toJson(), original);
  });
  test(
      'storage schema failure is propagated and no unrelated table silently created',
      () async {
    final storage = await open();
    expect(
        SchemaGuard.ensureColumns(storage.db,
            table: 'absent', columns: const {'backendSelection': 'text'}),
        throwsStateError);
    expect(
        await storage.db
            .rawQuery("select name from sqlite_master where name='absent'"),
        isEmpty);
  });
}

class _NoNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('network forbidden in R2b storage fixture');
  }
}

class _SecretStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
