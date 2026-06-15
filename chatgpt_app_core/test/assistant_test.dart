import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 阶段七（助手系统）验收测试：
/// 1) AssistantModel JSON 往返；2) AssistantDao CRUD（真实 DAO + 内存库）；
/// 3) tb_conversation_list 旧表升级（assistantId 列 ALTER）；
/// 4) system prompt 注入；5) 模型覆盖与能力位联动。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('AssistantModel', () {
    test('toJson/fromJson 往返保持字段（useTools 以 0/1 存储）', () {
      final original = AssistantModel(
        id: 7,
        name: '翻译官',
        emoji: '🌐',
        prompt: '你是专业翻译',
        model: 'gpt-4o',
        useTools: false,
        createdAt: 100,
        updatedAt: 200,
      );
      final json = original.toJson();
      expect(json['useTools'], 0);
      final restored = AssistantModel.fromJson(json);
      expect(restored.id, 7);
      expect(restored.name, '翻译官');
      expect(restored.emoji, '🌐');
      expect(restored.prompt, '你是专业翻译');
      expect(restored.model, 'gpt-4o');
      expect(restored.useTools, isFalse);
      expect(restored.createdAt, 100);
      expect(restored.updatedAt, 200);
    });

    test('fromJson 缺省字段兜底（useTools 默认开）', () {
      final a = AssistantModel.fromJson({'name': 'x'});
      expect(a.useTools, isTrue);
      expect(a.emoji, '🤖');
      expect(a.model, '');
      expect(a.prompt, '');
    });
  });

  group('AssistantModel.applyTo（模型覆盖）', () {
    test('本地模式：覆盖当前服务商的 model，effectiveModel 随之变化', () {
      final s = AISettings.defaults(); // local + deepseek-chat
      final a = AssistantModel(name: 'a', model: 'deepseek-reasoner');
      final next = a.applyTo(s);
      expect(next.effectiveModel, 'deepseek-reasoner');
      // 原设置不被改动（clone 语义）
      expect(s.effectiveModel, 'deepseek-chat');
    });

    test('后端模式：覆盖 backendModel', () {
      final s = AISettings.defaults()..mode = AIMode.backend;
      final a = AssistantModel(name: 'a', model: 'gpt-4o');
      expect(a.applyTo(s).effectiveModel, 'gpt-4o');
      expect(s.backendModel, 'deepseek-chat');
    });

    test('无覆盖（空串/空白）时原样返回同一实例', () {
      final s = AISettings.defaults();
      expect(identical(AssistantModel(name: 'a').applyTo(s), s), isTrue);
      expect(
          identical(AssistantModel(name: 'a', model: '  ').applyTo(s), s),
          isTrue);
    });

    test('能力位联动：覆盖为 gpt-4o 后 capabilitiesFor 算出 vision', () {
      final s = AISettings.defaults()..activeProviderId = 'openai';
      s.setActiveModel('gpt-3.5-turbo');
      final base = ChatService.capabilitiesFor(s);
      expect(base.image, isFalse);
      final a = AssistantModel(name: 'a', model: 'gpt-4o');
      final overridden = ChatService.capabilitiesFor(a.applyTo(s));
      expect(overridden.image, isTrue);
      expect(overridden.tool, isTrue);
    });
  });

  group('CompletionDao.injectSystemPrompt', () {
    final history = [
      {'role': 'user', 'content': 'hi'},
      {'role': 'assistant', 'content': 'hello'},
    ];

    test('非空提示词插在头部，且前置当前日期', () {
      final out = CompletionDao.injectSystemPrompt(history, '你是猫娘');
      expect(out.length, 3);
      expect(out.first['role'], 'system');
      expect(out.first['content'],
          '${CompletionDao.dateSystemPrompt()}\n\n你是猫娘');
      expect(out[1]['role'], 'user');
    });

    test('空/null/全空白时仍注入当前日期 system', () {
      for (final p in [null, '', '  \n']) {
        final out = CompletionDao.injectSystemPrompt(history, p);
        expect(out.length, 3);
        expect(out.first, {'role': 'system', 'content': CompletionDao.dateSystemPrompt()});
        expect(out[1]['role'], 'user');
      }
    });

    test('提示词首尾空白被 trim', () {
      final out = CompletionDao.injectSystemPrompt(history, '  你是猫娘 \n');
      expect(out.first['content'],
          '${CompletionDao.dateSystemPrompt()}\n\n你是猫娘');
    });
  });

  group('AssistantDao（真实 DAO + 内存库）', () {
    late Database db;
    late AssistantDao dao;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      dao = await AssistantDao.create(HiDBManager.test(db));
    });

    tearDown(() async {
      await db.close();
    });

    test('新建 -> 查询 -> 更新 -> 删除 全链路', () async {
      final a = AssistantModel(name: '审查员', prompt: '你是代码审查员');
      final id = await dao.saveAssistant(a);
      expect(id, isNotNull);
      expect(a.id, id);
      expect(a.createdAt, greaterThan(0));

      final loaded = await dao.getAssistant(id!);
      expect(loaded, isNotNull);
      expect(loaded!.name, '审查员');
      expect(loaded.useTools, isTrue);

      loaded.name = '资深审查员';
      loaded.useTools = false;
      await dao.saveAssistant(loaded);
      final reloaded = await dao.getAssistant(id);
      expect(reloaded!.name, '资深审查员');
      expect(reloaded.useTools, isFalse);

      await dao.deleteAssistant(id);
      expect(await dao.getAssistant(id), isNull);
      expect(await dao.getAssistants(), isEmpty);
    });

    test('列表按 updatedAt 倒序', () async {
      final a = AssistantModel(name: 'A');
      await dao.saveAssistant(a);
      await Future.delayed(const Duration(milliseconds: 2));
      await dao.saveAssistant(AssistantModel(name: 'B'));
      await Future.delayed(const Duration(milliseconds: 2));
      // 再次保存 A，A 应排到最前
      await dao.saveAssistant(a);
      final list = await dao.getAssistants();
      expect(list.map((e) => e.name).toList(), ['A', 'B']);
    });
  });

  group('tb_conversation_list 升级（assistantId 列）', () {
    late Database db;

    tearDown(() async {
      await db.close();
    });

    test('旧表（无 assistantId 列）经 create 后可读写 assistantId', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      // 模拟旧版 schema（阶段七之前，无 assistantId 列）
      await db.execute(
          'create table tb_conversation_list (id integer primary key autoincrement'
          ', cid integer, title text, icon text, updateAt integer'
          ', messageCount integer, lastMessage text, stickTime integer)');
      final dao = await ConversationListDao.create(HiDBManager.test(db));

      final model = ConversationModel(cid: 42, icon: '', assistantId: 9)
        ..title = 'with assistant'
        ..stickTime = 0;
      await dao.saveConversation(model);

      final list = await dao.getConversationList();
      expect(list.single.assistantId, 9);
    });

    test('新库直接建表（含 assistantId），重复 create 幂等', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final manager = HiDBManager.test(db);
      await ConversationListDao.create(manager);
      // 二次 create：ALTER 抛「列已存在」被吞掉，不影响使用
      final dao = await ConversationListDao.create(manager);

      final model = ConversationModel(cid: 1, icon: '')
        ..title = 'no assistant'
        ..stickTime = 0;
      await dao.saveConversation(model);
      final list = await dao.getConversationList();
      expect(list.single.assistantId, isNull);
    });
  });
}
