import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/skill_script_dao.dart';
import 'package:chatgpt_app_core/model/skill_script.dart';
import 'package:chatgpt_app_core/skill/js_exec_result.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:chatgpt_app_core/skill/skill_script_auditor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 技能脚本子系统验收测试：SkillScriptDao CRUD、带脚本导入 + 审计落库、
/// 审计器解析、run_script 工具门控（缺上下文/未找到/确认/执行）。
/// 不触碰原生 JS 引擎（运行经注入式 runJs 钩子），全部可在 flutter test 跑。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // 每个测试独立临时文件库，避免 ffi ':memory:' 在同进程复用污染。
  Future<HiDBManager> newDb() async {
    final dir = await Directory.systemTemp.createTemp('skill_script_test');
    return HiDBManager.test(
        await databaseFactoryFfi.openDatabase('${dir.path}/t.db'));
  }

  List<int> zipWithScript() {
    const skillMd = '---\nname: story-deslop\n'
        'description: 网文去AI味\n---\n你是去AI味助手。';
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('story-deslop/SKILL.md', utf8.encode(skillMd)))
      ..addFile(ArchiveFile.bytes('story-deslop/references/banned-words.md',
          utf8.encode('# 违禁词\n忽然、顿时')))
      ..addFile(ArchiveFile.bytes('story-deslop/scripts/normalize.js',
          utf8.encode('INPUT.replace(/--/g, "——")')))
      ..addFile(ArchiveFile.bytes('story-deslop/.deslop-whitelist',
          utf8.encode('x')));
    return ZipEncoder().encodeBytes(archive);
  }

  group('SkillScriptDao', () {
    test('增改查删 + 审计更新', () async {
      final storage = await newDb();
      final dao = await SkillScriptDao.create(storage);

      final id = await dao.saveScript(SkillScript(
          assistantId: 7, name: 'a.js', code: 'INPUT'));
      expect(id, isNotNull);

      final got = await dao.getScript(7, 'a.js');
      expect(got, isNotNull);
      expect(got!.code, 'INPUT');
      expect(got.auditLevel, SkillScript.levelPending);

      await dao.updateAudit(id!, SkillScript.levelSafe, '无风险');
      expect((await dao.getScript(7, 'a.js'))!.auditLevel, SkillScript.levelSafe);

      // 另一个助手的脚本互不可见。
      await dao.saveScript(SkillScript(assistantId: 8, name: 'b.js', code: 'x'));
      expect((await dao.getScripts(7)).length, 1);
      expect((await dao.getScripts(8)).length, 1);

      await dao.deleteForAssistant(7);
      expect((await dao.getScripts(7)), isEmpty);
      expect((await dao.getScripts(8)).length, 1);
    });
  });

  group('SkillImportService 带脚本', () {
    test('解析出脚本（排除隐藏文件）', () {
      final pkg = SkillImportService.parseArchive(zipWithScript());
      expect(pkg.scripts.length, 1);
      expect(pkg.scripts.single.name, 'normalize.js');
      expect(pkg.references.length, 1);
    });

    test('导入：审计落库 + 绑定 run_script 与 knowledge_search', () async {
      final storage = await newDb();
      final assistantDao = await AssistantDao.create(storage);
      final kbDao = await KnowledgeDao.create(storage);
      final scriptDao = await SkillScriptDao.create(storage);

      final pkg = SkillImportService.parseArchive(zipWithScript());
      final result = await SkillImportService.import(
        pkg,
        assistantDao: assistantDao,
        knowledgeDao: kbDao,
        scriptDao: scriptDao,
        auditCall: (prompt) async => '{"level":"safe","summary":"纯字符串处理"}',
      );

      expect(result.scriptCount, 1);
      final a = (await assistantDao.getAssistants()).single;
      expect(a.toolIds, containsAll(['knowledge_search', 'run_script']));

      final scripts = await scriptDao.getScripts(a.id!);
      expect(scripts.single.assistantId, a.id);
      expect(scripts.single.auditLevel, SkillScript.levelSafe);
      expect(scripts.single.auditSummary, '纯字符串处理');
    });

    test('无 auditCall：脚本以 pending 入库', () async {
      final storage = await newDb();
      final assistantDao = await AssistantDao.create(storage);
      final kbDao = await KnowledgeDao.create(storage);
      final scriptDao = await SkillScriptDao.create(storage);

      final pkg = SkillImportService.parseArchive(zipWithScript());
      await SkillImportService.import(pkg,
          assistantDao: assistantDao, knowledgeDao: kbDao, scriptDao: scriptDao);
      final a = (await assistantDao.getAssistants()).single;
      expect((await scriptDao.getScripts(a.id!)).single.auditLevel,
          SkillScript.levelPending);
    });

    test('无 scriptDao：脚本被丢弃，不绑定 run_script', () async {
      final storage = await newDb();
      final assistantDao = await AssistantDao.create(storage);
      final kbDao = await KnowledgeDao.create(storage);

      final pkg = SkillImportService.parseArchive(zipWithScript());
      final result = await SkillImportService.import(pkg,
          assistantDao: assistantDao, knowledgeDao: kbDao);
      expect(result.scriptCount, 0);
      final a = (await assistantDao.getAssistants()).single;
      expect(a.toolIds, isNot(contains('run_script')));
    });
  });

  group('SkillScriptAuditor', () {
    test('prompt 含名字与沙箱说明', () {
      final p = SkillScriptAuditor.buildPrompt('x.js', 'INPUT');
      expect(p, contains('x.js'));
      expect(p, contains('沙箱'));
      expect(p, contains('INPUT'));
    });

    test('解析：纯 JSON / 含前后文 / 大写等级 / 非法', () {
      expect(SkillScriptAuditor.parse('{"level":"safe","summary":"ok"}').level,
          SkillScript.levelSafe);
      expect(
          SkillScriptAuditor.parse('结论：{"level":"danger","summary":"x"} 完')
              .level,
          SkillScript.levelDanger);
      expect(SkillScriptAuditor.parse('{"level":"SAFE","summary":""}').level,
          SkillScript.levelSafe);
      expect(SkillScriptAuditor.parse('我不知道').level, SkillScript.levelUnknown);
    });

    test('audit：caller 抛错回落 unknown', () async {
      final v = await SkillScriptAuditor.audit(
          'x.js', 'INPUT', (p) async => throw Exception('网络错'));
      expect(v.level, SkillScript.levelUnknown);
    });
  });

  group('run_script 工具门控', () {
    Future<String> runTool(ToolActionContext ctx,
        {String name = 'n.js', String input = 'hi'}) async {
      final tool = BuiltinTools.runScript(ctx);
      final out = await tool.execute({'name': name, 'input': input});
      return out.content;
    }

    test('确认通过 → 经注入 runJs 执行并返回输出', () async {
      final storage = await newDb();
      final dao = await SkillScriptDao.create(storage);
      await dao.saveScript(
          SkillScript(assistantId: 1, name: 'n.js', code: 'INPUT'));

      final ctx = ToolActionContext(
        openStorage: () async => storage,
        assistantId: 1,
        confirm: (t, d) async => true,
        runJs: (code, input) async => JsExecResult.ok('OUT:$input'),
      );
      expect(await runTool(ctx), 'OUT:hi');
    });

    test('用户拒绝 → 不执行', () async {
      final storage = await newDb();
      final dao = await SkillScriptDao.create(storage);
      await dao.saveScript(
          SkillScript(assistantId: 1, name: 'n.js', code: 'INPUT'));
      var ran = false;
      final ctx = ToolActionContext(
        openStorage: () async => storage,
        assistantId: 1,
        confirm: (t, d) async => false,
        runJs: (code, input) async {
          ran = true;
          return const JsExecResult.ok('x');
        },
      );
      expect(await runTool(ctx), contains('拒绝'));
      expect(ran, isFalse);
    });

    test('runJs 为 null（环境不支持）→ 优雅跳过', () async {
      final storage = await newDb();
      final dao = await SkillScriptDao.create(storage);
      await dao.saveScript(
          SkillScript(assistantId: 1, name: 'n.js', code: 'INPUT'));
      final ctx = ToolActionContext(
        openStorage: () async => storage,
        assistantId: 1,
        confirm: (t, d) async => true,
      );
      expect(await runTool(ctx), contains('不支持执行脚本'));
    });

    test('未绑定助手 / 脚本不存在', () async {
      final storage = await newDb();
      await SkillScriptDao.create(storage);
      final noAid = ToolActionContext(
        openStorage: () async => storage,
        confirm: (t, d) async => true,
        runJs: (c, i) async => const JsExecResult.ok('x'),
      );
      expect(await runTool(noAid), contains('未绑定技能助手'));

      final missing = ToolActionContext(
        openStorage: () async => storage,
        assistantId: 1,
        confirm: (t, d) async => true,
        runJs: (c, i) async => const JsExecResult.ok('x'),
      );
      expect(await runTool(missing, name: 'nope.js'), contains('未找到脚本'));
    });
  });
}
