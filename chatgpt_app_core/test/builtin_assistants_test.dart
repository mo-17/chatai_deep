import 'package:chatgpt_app_core/data/builtin_assistants.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 遗留项 9 验收：内置助手 / 助手市场。
/// 覆盖：内置目录数据完整性、模板 -> AssistantModel 的映射、以及「添加到我的助手」
/// （克隆进 tb_assistant，之后即普通助手）的真实 DAO 全链路。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('内置助手目录数据完整性', () {
    test('非空，且每条字段都齐全', () {
      expect(BuiltinAssistants.all, isNotEmpty);
      for (final a in BuiltinAssistants.all) {
        expect(a.category.trim(), isNotEmpty, reason: '${a.name} 缺分类');
        expect(a.name.trim(), isNotEmpty);
        expect(a.emoji.trim(), isNotEmpty, reason: '${a.name} 缺 emoji');
        expect(a.prompt.trim().length, greaterThan(10),
            reason: '${a.name} 提示词过短');
      }
    });

    test('名称唯一（避免市场里出现重复项）', () {
      final names = BuiltinAssistants.all.map((a) => a.name).toList();
      expect(names.toSet().length, names.length, reason: '存在重名内置助手');
    });

    test('grouped() 覆盖全部且保持收录顺序，不丢条目', () {
      final grouped = BuiltinAssistants.grouped();
      final flattened = grouped.values.expand((e) => e).toList();
      expect(flattened.length, BuiltinAssistants.all.length);
      // 每个分类内的顺序与 all 中一致
      for (final entry in grouped.entries) {
        final fromAll = BuiltinAssistants.all
            .where((a) => a.category == entry.key)
            .toList();
        expect(entry.value, fromAll);
      }
    });
  });

  group('BuiltinAssistant.toAssistant 映射', () {
    test('字段映射正确；模型覆盖留空（跟随全局设置）', () {
      final b = BuiltinAssistants.all.first;
      final m = b.toAssistant();
      expect(m.id, isNull, reason: '未落库 -> id 为 null（saveAssistant 走插入）');
      expect(m.name, b.name);
      expect(m.emoji, b.emoji);
      expect(m.prompt, b.prompt);
      expect(m.useTools, b.useTools);
      expect(m.model, '', reason: '内置助手不绑模型，避免与服务商不兼容');
    });

    test('每次调用返回独立新实例（编辑页改写不污染共享模板）', () {
      final b = BuiltinAssistants.all.first;
      final a1 = b.toAssistant();
      final a2 = b.toAssistant();
      expect(identical(a1, a2), isFalse);
      a1.name = '改了的名字';
      expect(a2.name, b.name, reason: '改 a1 不应影响 a2 或模板');
    });
  });

  group('添加到我的助手（真实 DAO + 内存库）', () {
    late Database db;
    late AssistantDao dao;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      dao = await AssistantDao.create(HiDBManager.test(db));
    });

    tearDown(() async {
      await db.close();
    });

    test('内置模板克隆落库 -> 成为可读写的普通助手', () async {
      final template = BuiltinAssistants.all
          .firstWhere((a) => a.name == '代码审查员')
          .toAssistant();
      final id = await dao.saveAssistant(template);
      expect(id, isNotNull);

      final all = await dao.getAssistants();
      expect(all, hasLength(1));
      final saved = all.single;
      expect(saved.id, id);
      expect(saved.name, '代码审查员');
      expect(saved.prompt.trim(), isNotEmpty);
      expect(saved.createdAt, greaterThan(0));

      // 添加后即普通助手：可改名再存（走更新而非再插入）。
      saved.name = '我的审查员';
      await dao.saveAssistant(saved);
      final after = await dao.getAssistants();
      expect(after, hasLength(1), reason: '更新不应新增行');
      expect(after.single.name, '我的审查员');
    });

    test('同一模板可添加多次（互不影响，各自独立 id）', () async {
      final b = BuiltinAssistants.all.first;
      final id1 = await dao.saveAssistant(b.toAssistant());
      final id2 = await dao.saveAssistant(b.toAssistant());
      expect(id1, isNot(id2));
      expect(await dao.getAssistants(), hasLength(2));
    });
  });
}
