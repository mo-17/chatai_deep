import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// L3b（追加写工具 + 确认）验收：收藏/建会话/置顶在确认后写入、拒绝后不写、
/// 无 confirm（无 UI）一律拒绝。走真实 DAO（注入 ffi 内存库 + 确认桩）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late HiDBManager storage;
  ToolActionContext ctxWith(Future<bool> Function(String, String)? confirm) =>
      ToolActionContext(openStorage: () async => storage, confirm: confirm);
  // 总是放行 / 总是拒绝的确认桩。
  Future<bool> approve(String a, String b) async => true;
  Future<bool> deny(String a, String b) async => false;

  setUp(() async {
    storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    await ConversationListDao.create(storage);
    await FavoriteDao.create(storage);
  });

  tearDown(() async => storage.db.close());

  group('save_favorite', () {
    test('确认后写入收藏', () async {
      final out = await BuiltinTools.saveFavorite(ctxWith(approve))
          .execute({'content': '记一下这段'});
      expect(out.content, contains('已收藏'));
      final favs = await (await FavoriteDao.create(storage)).getFavoriteList();
      expect(favs.single.content, '记一下这段');
    });

    test('拒绝则不写、回灌拒绝文本', () async {
      final out = await BuiltinTools.saveFavorite(ctxWith(deny))
          .execute({'content': '别存'});
      expect(out.content, contains('拒绝'));
      final favs = await (await FavoriteDao.create(storage)).getFavoriteList();
      expect(favs, isEmpty);
    });

    test('无 confirm（无 UI）一律拒绝', () async {
      final out = await BuiltinTools.saveFavorite(ctxWith(null))
          .execute({'content': 'x'});
      expect(out.content, contains('拒绝'));
      final favs = await (await FavoriteDao.create(storage)).getFavoriteList();
      expect(favs, isEmpty);
    });
  });

  group('create_conversation', () {
    test('确认后新建带标题会话', () async {
      final out = await BuiltinTools.createConversation(ctxWith(approve))
          .execute({'title': '新话题'});
      expect(out.content, contains('已新建会话'));
      final convs = await (await ConversationListDao.create(storage))
          .getConversationList();
      expect(convs.single.title, '新话题');
    });

    test('拒绝则不建', () async {
      await BuiltinTools.createConversation(ctxWith(deny))
          .execute({'title': '不要'});
      final convs = await (await ConversationListDao.create(storage))
          .getConversationList();
      expect(convs, isEmpty);
    });
  });

  group('stick_conversation', () {
    setUp(() async {
      final dao = await ConversationListDao.create(storage);
      await dao.saveConversation(ConversationModel(cid: 500, icon: '')
        ..title = '待置顶'
        ..stickTime = 0
        ..updateAt = 1);
    });

    test('确认后置顶（stickTime>0）', () async {
      final out = await BuiltinTools.stickConversation(ctxWith(approve))
          .execute({'cid': 500, 'stick': true});
      expect(out.content, contains('已置顶'));
      final rows = await storage.db
          .query('tb_conversation_list', where: 'cid = ?', whereArgs: [500]);
      expect((rows.single['stickTime'] as int) > 0, isTrue);
    });

    test('不存在的 cid 给出提示', () async {
      final out = await BuiltinTools.stickConversation(ctxWith(approve))
          .execute({'cid': 999});
      expect(out.content, contains('没有找到'));
    });
  });

  group('catalog / fromAssistant', () {
    test('写工具在 catalog 标记 sideEffect', () {
      for (final id in ['save_favorite', 'create_conversation', 'stick_conversation']) {
        final d = ToolRegistry.catalog.firstWhere((d) => d.id == id);
        expect(d.sideEffect, isTrue, reason: id);
      }
    });

    test('fromAssistant 装配写工具（需 actions）', () {
      final r = ToolRegistry.fromAssistant(
        AISettings.defaults(),
        const ['save_favorite', 'create_conversation', 'stick_conversation'],
        actions: ctxWith(approve),
      );
      expect(r.byName('save_favorite'), isNotNull);
      expect(r.byName('create_conversation'), isNotNull);
      expect(r.byName('stick_conversation'), isNotNull);
    });
  });
}
