import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialize FFI for in-memory database testing
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('AISettings round-trip', () {
    test('fromJson/toJson round-trip preserves values', () {
      final original = AISettings.defaults();
      final json = original.toJson();
      final restored = AISettings.fromJson(json);

      expect(restored.mode, original.mode);
      expect(restored.activeProviderId, original.activeProviderId);
      expect(restored.streamEnabled, original.streamEnabled);
      expect(restored.providers.length, original.providers.length);
      expect(restored.activeProvider.id, original.activeProvider.id);
      expect(restored.effectiveModel, original.effectiveModel);
      expect(restored.backendModel, original.backendModel);
    });

    test('fromJson handles missing fields gracefully (seeds presets)', () {
      final settings = AISettings.fromJson({});
      expect(settings.mode, AIMode.local);
      expect(settings.activeProviderId, 'deepseek');
      expect(settings.streamEnabled, isTrue);
      expect(settings.providers, isNotEmpty);
      expect(settings.providers.firstWhere((p) => p.id == 'deepseek').enabled,
          isTrue);
    });

    test('fromJson parses backend mode correctly', () {
      final json = AISettings.defaults().toJson();
      json['mode'] = 'backend';
      json['backendModel'] = 'gpt-4o';
      final settings = AISettings.fromJson(json);
      expect(settings.mode, AIMode.backend);
      expect(settings.effectiveModel, 'gpt-4o');
    });

    test('legacy format migrates openai/deepseek keys into providers', () {
      final legacy = {
        'mode': 'local',
        'localProvider': 'openai',
        'openai': {
          'apiKey': 'sk-legacy',
          'baseUrl': 'https://api.openai.com/v1/chat/completions',
          'model': 'gpt-4o',
        },
        'deepseek': {
          'apiKey': 'dk-legacy',
          'baseUrl': 'https://api.deepseek.com/chat/completions',
          'model': 'deepseek-chat',
        },
      };
      final s = AISettings.fromJson(legacy);
      expect(s.activeProviderId, 'openai');
      final openai = s.providers.firstWhere((p) => p.id == 'openai');
      expect(openai.apiKey, 'sk-legacy');
      expect(openai.selectedModelId, 'gpt-4o');
      expect(openai.enabled, isTrue);
      expect(s.providers.firstWhere((p) => p.id == 'deepseek').apiKey,
          'dk-legacy');
      // 迁移后 activeLocal 仍能派生出可用的直连配置。
      expect(s.activeLocal.apiKey, 'sk-legacy');
      expect(s.activeLocal.model, 'gpt-4o');
      expect(s.activeLocal.baseUrl, contains('/chat/completions'));
    });
  });

  group('迁移后直连 URL 正确性（审查回归）', () {
    test('旧自定义代理 baseUrl 逐字保留，不被强插 /v1', () {
      final s = AISettings.fromJson({
        'mode': 'local',
        'localProvider': 'openai',
        'openai': {
          'apiKey': 'sk-x',
          'baseUrl': 'https://myproxy.com/chat/completions',
          'model': 'gpt-4o',
        },
      });
      expect(s.activeLocal.baseUrl, 'https://myproxy.com/chat/completions');
    });

    test('旧 DeepSeek 默认端点（无 /v1）精确保留', () {
      final s = AISettings.fromJson({
        'mode': 'local',
        'localProvider': 'deepseek',
        'deepseek': {
          'apiKey': 'dk',
          'baseUrl': 'https://api.deepseek.com/chat/completions',
          'model': 'deepseek-chat',
        },
      });
      expect(s.activeLocal.baseUrl, 'https://api.deepseek.com/chat/completions');
    });

    test('apiHost 留空时回落到预设默认地址', () {
      final s = AISettings.defaults()..activeProviderId = 'openai';
      s.activeProvider.apiHost = '';
      expect(
          s.activeLocal.baseUrl, 'https://api.openai.com/v1/chat/completions');
    });
  });

  group('ModelCatalog.applyRemote', () {
    test('remote models are correctly classified by providerCode', () {
      final data = {
        'models': [
          {
            'modelId': 'gpt-4o',
            'description': 'OpenAI flagship',
            'displayName': 'GPT-4o',
            'providerCode': 'openai',
          },
          {
            'modelId': 'deepseek-chat',
            'description': 'DeepSeek V3',
            'displayName': 'DeepSeek Chat',
            'providerCode': 'deepseek',
          },
          {
            'modelId': 'custom-model',
            'description': 'Unknown provider',
            'displayName': 'Custom',
            'providerCode': 'other',
          },
        ],
      };
      ModelCatalog.applyRemote(data);

      expect(ModelCatalog.openai.any((m) => m.id == 'gpt-4o'), isTrue);
      expect(ModelCatalog.deepseek.any((m) => m.id == 'deepseek-chat'), isTrue);
      expect(ModelCatalog.remoteAvailable, isTrue);
    });

    test('empty models list does not overwrite defaults', () {
      final beforeOpenai = ModelCatalog.openai.length;
      ModelCatalog.applyRemote({'models': []});
      expect(ModelCatalog.openai.length, beforeOpenai);
    });
  });

  group('MessageDao (via raw SQL)', () {
    late Database db;
    const testCid = 12345;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
          'create table if not exists tb_messages (id integer primary key autoincrement'
          ', cid integer not null, content text, createdAt integer'
          ', ownerName text, ownerType text, avatar text)');
      await db.execute(
          'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
    });

    tearDown(() async {
      await db.close();
    });

    test('insert and paginate messages per cid', () async {
      // Insert 50 messages for testCid
      for (var i = 0; i < 50; i++) {
        await db.insert('tb_messages', {
          'cid': testCid,
          'content': 'message $i',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'ownerName': 'user',
          'ownerType': i.isEven ? 'sender' : 'receiver',
        });
      }

      // Insert messages for another cid — should be isolated
      await db.insert('tb_messages', {
        'cid': 99999,
        'content': 'other cid',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'ownerName': 'user',
        'ownerType': 'sender',
      });

      // Count by cid
      final count = await db.rawQuery(
          'select COUNT(*) as cnt from tb_messages where cid = ?', [testCid]);
      expect(count.first['cnt'], 50);

      // Paginate: pageSize=15, pageIndex=1
      final page1 = await db.query('tb_messages',
          where: 'cid = ?',
          whereArgs: [testCid],
          orderBy: 'id desc',
          limit: 15,
          offset: 0);
      expect(page1.length, 15);

      // Page 4 should have 5 remaining items
      final page4 = await db.query('tb_messages',
          where: 'cid = ?',
          whereArgs: [testCid],
          orderBy: 'id desc',
          limit: 15,
          offset: 45);
      expect(page4.length, 5);
    });

    test('delete message removes specific row', () async {
      final id = await db.insert('tb_messages', {
        'cid': testCid,
        'content': 'to delete',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'ownerName': 'user',
        'ownerType': 'sender',
      });

      await db.delete('tb_messages', where: 'id = ?', whereArgs: [id]);

      final remaining = await db.query('tb_messages', where: 'cid = ?', whereArgs: [testCid]);
      expect(remaining.length, 0);
    });

    test('delete all messages for a cid (conversation delete)', () async {
      for (var i = 0; i < 5; i++) {
        await db.insert('tb_messages', {
          'cid': testCid,
          'content': 'msg $i',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'ownerName': 'user',
          'ownerType': 'sender',
        });
      }

      await db.delete('tb_messages', where: 'cid = ?', whereArgs: [testCid]);

      final remaining = await db.query('tb_messages', where: 'cid = ?', whereArgs: [testCid]);
      expect(remaining.length, 0);
    });
  });

  group('ConversationListDao (via raw SQL)', () {
    late Database db;
    const tableName = 'tb_conversation_list';

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
          'create table if not exists $tableName (id integer primary key autoincrement'
          ', cid integer, title text, icon text, updateAt integer'
          ', messageCount integer, lastMessage text, stickTime integer)');
      await db.execute(
          'create unique index if not exists ${tableName}_cid_idx on $tableName (cid)');
      await db.execute(
          'create index if not exists ${tableName}_stick_update_idx on $tableName(stickTime, updateAt desc)');
    });

    tearDown(() async {
      await db.close();
    });

    test('insert and paginate conversations, ordered by updateAt desc', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 30; i++) {
        await db.insert(tableName, {
          'cid': 1000 + i,
          'title': 'Conv $i',
          'icon': '',
          'updateAt': now + i,
          'lastMessage': 'last $i',
          'messageCount': i,
          'stickTime': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // Paginate — most recent first
      final page1 = await db.query(tableName,
          where: 'stickTime <= 0',
          orderBy: 'updateAt desc',
          limit: 10,
          offset: 0);
      expect(page1.length, 10);
      expect((page1.first['updateAt'] as int) > (page1.last['updateAt'] as int), isTrue);
    });

    test('sticky conversations appear in stick list', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Insert sticky
      await db.insert(tableName, {
        'cid': 2001,
        'title': 'Sticky',
        'updateAt': now,
        'stickTime': now, // non-zero = sticky
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Insert normal
      await db.insert(tableName, {
        'cid': 2002,
        'title': 'Normal',
        'updateAt': now,
        'stickTime': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final stickList = await db.query(tableName,
          where: 'stickTime > 0', orderBy: 'stickTime desc');
      expect(stickList.length, 1);
      expect(stickList.first['cid'], 2001);

      final normalList = await db.query(tableName,
          where: 'stickTime <= 0', orderBy: 'updateAt desc');
      expect(normalList.length, 1);
      expect(normalList.first['cid'], 2002);
    });

    test('saveConversation uses ConflictAlgorithm.replace (upsert)', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Insert
      await db.insert(tableName, {
        'cid': 3001,
        'title': 'Original Title',
        'updateAt': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      var result = await db.query(tableName, where: 'cid = ?', whereArgs: [3001]);
      expect(result.length, 1);
      expect(result.first['title'], 'Original Title');

      // Upsert with same cid
      await db.insert(tableName, {
        'cid': 3001,
        'title': 'Updated Title',
        'updateAt': now + 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      result = await db.query(tableName, where: 'cid = ?', whereArgs: [3001]);
      expect(result.length, 1);
      expect(result.first['title'], 'Updated Title');
    });
  });
}
