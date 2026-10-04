import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<(HiDBManager, AgentWorkspaceService, AgentWorkspaceTools)> setup(
      {Future<bool> Function(String, String)? confirm}) async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final manager = HiDBManager.test(db);
    final workspace = await AgentWorkspaceService.create(manager, cid: 7);
    final tools = await AgentWorkspaceTools.create(manager,
        cid: 7, workspace: workspace, confirm: confirm);
    return (manager, workspace, tools);
  }

  test(
      'search is not full read; disjoint and overlapping returned ranges merge',
      () async {
    final (_, workspace, tools) = await setup();
    final file = await workspace.importText(
        name: 'novel.txt', content: '${'甲' * 18000}END');
    await tools.beginTurn(101, [file.id]);
    Future<String> execute(String name, Map<String, dynamic> args) async =>
        (await tools.tools
                .singleWhere((tool) => tool.name == name)
                .execute(args))
            .content;
    await execute('file_search', {'file_id': file.id, 'query': 'END'});
    expect((await tools.verify()).isPassed, isFalse);
    final first = jsonDecode(await execute('read_file', {'file_id': file.id}));
    expect(first['nextOffset'], 12000);
    final incomplete = await tools.verify();
    expect(incomplete.checks.single.detail, contains('[12000, 18003)'));
    await execute('read_file', {'file_id': file.id, 'offset': 11000});
    expect((await tools.verify()).isPassed, isTrue);
    expect(tools.lastReport!.hasChecks, isTrue);
  });

  test('same turn resumes persisted evidence but a new turn starts unread',
      () async {
    final (manager, workspace, tools) = await setup();
    final file = await workspace.importText(name: 'read.txt', content: '全文内容');
    await tools.beginTurn(101, [file.id]);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': file.id});
    expect((await tools.verify()).isPassed, isTrue);
    final reopened =
        await AgentWorkspaceTools.create(manager, cid: 7, workspace: workspace);
    await reopened.beginTurn(101, const [], resume: true);
    expect(reopened.lastReport!.isPassed, isTrue);
    expect((await reopened.verify()).isPassed, isTrue);
    await reopened.beginTurn(202, [file.id]);
    expect((await reopened.verify()).isPassed, isFalse);
    expect((await reopened.loadLatestReport(userCreatedAt: 101))!.isPassed,
        isTrue);
  });

  test(
      'list files paginates 100 files without loss and bounds section metadata',
      () async {
    final (_, workspace, tools) = await setup();
    for (var index = 0; index < 100; index++) {
      await workspace.importText(
          name: 'input-$index.md',
          content: index == 0
              ? List.generate(25, (n) => '# $n${'甲' * 100}\n文字').join('\n')
              : '原文 $index');
    }
    final list = tools.tools.singleWhere((tool) => tool.name == 'list_files');
    final seen = <int>{};
    var offset = 0;
    while (true) {
      final page = jsonDecode((await list.execute({'offset': offset})).content)
          as Map<String, dynamic>;
      expect(page['totalFiles'], 100);
      final files = page['files'] as List;
      expect(files.length, lessThanOrEqualTo(50));
      for (final file in files) {
        expect(seen.add(file['id'] as int), isTrue);
        expect((file['sections'] as List).length, lessThanOrEqualTo(10));
        for (final section in file['sections'] as List) {
          expect((section['title'] as String).length, lessThanOrEqualTo(80));
        }
      }
      final next = page['nextOffset'] as int?;
      if (next == null) break;
      expect(next, greaterThan(offset));
      offset = next;
    }
    expect(seen, (await workspace.listFiles()).map((file) => file.id).toSet());
    final beyond = jsonDecode((await list.execute({'offset': 1000})).content);
    expect(beyond['files'], isEmpty);
    expect(beyond['nextOffset'], isNull);
    await expectLater(list.execute({'limit': 51}), throwsFormatException);
    await expectLater(list.execute({'offset': -1}), throwsFormatException);
  });

  test('reading old input adds it to this turn; search alone does not',
      () async {
    final (manager, workspace, tools) = await setup();
    final input =
        await workspace.importText(name: 'old.txt', content: '甲' * 20);
    await tools.beginTurn(101, const []);
    await tools.tools
        .singleWhere((tool) => tool.name == 'file_search')
        .execute({'file_id': input.id, 'query': '甲'});
    expect((await tools.verify()).hasChecks, isFalse);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': input.id, 'max_chars': 10});
    final partial = await tools.verify();
    expect(partial.isPassed, isFalse);
    expect(partial.checks.single.detail, contains('[10, 20)'));
    final reopened =
        await AgentWorkspaceTools.create(manager, cid: 7, workspace: workspace);
    await reopened.beginTurn(101, const [], resume: true);
    expect((await reopened.verify()).isPassed, isFalse);
    await reopened.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': input.id, 'offset': 10});
    expect((await reopened.verify()).isPassed, isTrue);
  });

  test('empty PDF text cannot pass; mixed pages report only text coverage',
      () async {
    final (_, workspace, tools) = await setup();
    final empty = await workspace
        .importText(name: 'scan.pdf', content: '', pageTexts: ['']);
    expect(empty.characterCount, 0);
    await tools.beginTurn(101, [empty.id]);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': empty.id});
    final report = await tools.verify();
    expect(report.isPassed, isFalse);
    expect(report.checks.single.detail, contains('需要 OCR'));
    final blankPages = await workspace
        .importText(name: 'blank.pdf', content: '', pageTexts: ['', '']);
    await tools.beginTurn(202, [blankPages.id]);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': blankPages.id});
    expect((await tools.verify()).isPassed, isFalse);
    final mixed = await workspace
        .importText(name: 'mixed.pdf', content: '', pageTexts: ['文字层', '']);
    await tools.beginTurn(303, [mixed.id]);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': mixed.id});
    final mixedReport = await tools.verify();
    expect(mixedReport.isPassed, isTrue);
    expect(mixedReport.checks.single.label, contains('PDF 文字覆盖'));
    expect(mixedReport.checks.single.detail, contains('扫描图像未验收'));
  });

  test('write requires confirmation and rejects paths/input targets', () async {
    final (_, workspace, tools) = await setup();
    final input =
        await workspace.importText(name: 'input.txt', content: '原始资料');
    await tools.beginTurn(101, const []);
    final write = tools.tools.singleWhere((tool) => tool.name == 'write_file');
    expect(
        (await write.execute({'name': 'result.txt', 'content': '结果'})).content,
        contains('未批准'));
    expect(await workspace.listFiles(), hasLength(1));
    await expectLater(write.execute({'name': '../result.txt', 'content': 'x'}),
        throwsFormatException);
    await expectLater(
        write.execute(
            {'file_id': input.id, 'name': 'input.txt', 'content': '覆盖'}),
        throwsFormatException);
    expect((await workspace.getRevision(input.id)).content, '原始资料');
  });

  test('written outputs are verified even without named user requirements',
      () async {
    var approvals = 0;
    final (_, workspace, tools) = await setup(confirm: (title, detail) async {
      approvals++;
      expect(title, contains('result.csv'));
      expect(detail, contains('同名输出保存新版本'));
      return true;
    });
    await tools.beginTurn(101, const []);
    final write = tools.tools.singleWhere((tool) => tool.name == 'write_file');
    await write.execute(
        {'name': 'result.csv', 'content': 'a,b\n"value,with comma",2\n'});
    expect((await tools.verify()).isPassed, isTrue);
    final output = (await workspace.listFiles()).single;
    await write.execute({
      'file_id': output.id,
      'name': 'result.csv',
      'content': 'a,b\nwrong\n'
    });
    final failed = await tools.verify();
    expect(failed.isPassed, isFalse);
    expect(failed.checks.any((check) => check.detail.contains('列数')), isTrue);
    expect(approvals, 2);
  });

  test(
      'user criteria cannot be weakened by tool arguments; pure chat is isolated',
      () async {
    final (_, workspace, tools) = await setup(confirm: (_, __) async => true);
    await tools.saveCriteria(const TaskAcceptanceCriteria(
        expectedOutputNames: ['result.md'],
        minChars: 10,
        maxChars: 30,
        requiredTerms: ['结论'],
        requireFullRead: true));
    await tools.beginTurn(101, const []);
    await tools.tools
        .singleWhere((tool) => tool.name == 'write_file')
        .execute({'name': 'result.md', 'content': '短'});
    final verify =
        tools.tools.singleWhere((tool) => tool.name == 'verify_task');
    final denied = jsonDecode((await verify.execute({
      'criteria': {'minChars': 0}
    }))
        .content);
    expect(denied['isPassed'], isFalse);
    expect(
        tools.tools.any((tool) => tool.name == 'set_task_criteria'), isFalse);
    expect((await tools.correctionForFinal('我已完成')), contains('不能修改用户验收条件'));
    await tools.beginTurn(202, const []);
    final pureChat = await tools.verify();
    expect(pureChat.hasChecks, isFalse);
    expect(pureChat.isPassed, isTrue);
    expect((await tools.loadCriteria()).minChars, 10);
    expect((await workspace.listFiles()).single.name, 'result.md');
  });

  test('output constraints without a filename still require a real output',
      () async {
    final (_, _, tools) = await setup();
    await tools
        .saveCriteria(const TaskAcceptanceCriteria(requiredTerms: ['结论']));
    await tools.beginTurn(101, const []);
    final report = await tools.verify();
    expect(report.hasChecks, isTrue);
    expect(report.isPassed, isFalse);
    expect(report.checks.single.label, '要求输出文件');
  });

  test(
      'first request sees user criteria and resume retains original turn snapshot',
      () async {
    final (manager, workspace, tools) = await setup();
    await tools.saveCriteria(const TaskAcceptanceCriteria(
        expectedOutputNames: ['report.csv'],
        minChars: 300,
        maxChars: 5000,
        format: 'csv'));
    final firstPrompt = await tools.acceptancePrompt();
    expect(firstPrompt, contains('report.csv'));
    expect(firstPrompt, contains('300'));
    await tools.beginTurn(101, const []);
    await tools.saveCriteria(
        const TaskAcceptanceCriteria(expectedOutputNames: ['next.md']));
    expect(await tools.acceptancePrompt(resume: true), contains('report.csv'));
    expect(
        await tools.acceptancePrompt(resume: true), isNot(contains('next.md')));
    final reopened =
        await AgentWorkspaceTools.create(manager, cid: 7, workspace: workspace);
    expect(
        await reopened.acceptancePrompt(resume: true), contains('report.csv'));
    expect(await reopened.acceptancePrompt(), contains('next.md'));
    await reopened.beginTurn(202, const []);
    expect(await reopened.acceptancePrompt(), isEmpty);
  });

  test(
      'old output cannot pretend to be this turn delivery; confirmed idempotent write can',
      () async {
    final (_, workspace, tools) = await setup(confirm: (_, __) async => true);
    final old = await workspace.writeFile(name: 'old.md', content: '旧成果');
    await tools.saveCriteria(
        const TaskAcceptanceCriteria(expectedOutputNames: ['old.md']));
    await tools.beginTurn(101, const []);
    final before = await tools.verify();
    expect(before.isPassed, isFalse);
    expect(before.checks.first.detail, contains('旧输出不代表本轮交付'));
    await tools.tools
        .singleWhere((tool) => tool.name == 'write_file')
        .execute({'file_id': old.id, 'name': 'old.md', 'content': '旧成果'});
    expect((await tools.verify()).isPassed, isTrue);
    expect((await workspace.getFile(old.id))!.revision, old.revision);
  });

  test(
      'manual edit and restored content invalidate current report, preserving audit',
      () async {
    final (_, workspace, tools) = await setup(confirm: (_, __) async => true);
    await tools.beginTurn(101, const []);
    final write = tools.tools.singleWhere((tool) => tool.name == 'write_file');
    await write.execute({'name': 'result.md', 'content': '原成果'});
    final file = (await workspace.listFiles()).single;
    final originalReport = await tools.verify();
    expect(originalReport.isPassed, isTrue);
    final updated = await workspace.writeFile(
        fileId: file.id, name: file.name, content: '手动修改');
    final refreshed = (await tools.refreshLatestReport())!;
    expect(refreshed.isPassed, isFalse);
    expect(tools.lastReport, same(refreshed));
    expect(refreshed.createdAt, originalReport.createdAt);
    expect(refreshed.checks.last.label, '成果已变化，需要重新验收');
    expect(refreshed.checks.last.revision, updated.revision);
    expect(refreshed.checks.first.revision, file.revision);
    expect(refreshed.checks.first.passed, isTrue);
    final stored = (await tools.store.loadLatestReport(7))!;
    expect(stored['isPassed'], isTrue);
    expect(stored['checks'], hasLength(originalReport.checks.length));
    expect((await tools.refreshLatestReport())!.checks,
        hasLength(originalReport.checks.length + 1));

    final restored = await workspace.writeFile(
        fileId: file.id, name: file.name, content: '原成果');
    expect(restored.revision, greaterThan(updated.revision));
    expect(
        (await tools.loadLatestReport(userCreatedAt: 101))!.isPassed, isFalse);
    // verify 不得把手动修改版本冒充本轮确认写入；明确确认同一内容才可重新验收。
    expect((await tools.verify()).isPassed, isFalse);
    await write
        .execute({'file_id': file.id, 'name': file.name, 'content': '原成果'});
    expect((await tools.verify()).isPassed, isTrue);
    expect((await tools.refreshLatestReport())!.isPassed, isTrue);
  });

  test(
      'missing file invalidates loaded report without rewriting historical pass',
      () async {
    final (manager, workspace, tools) = await setup();
    final input = await workspace.importText(name: 'source.txt', content: '原文');
    await tools.beginTurn(101, [input.id]);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': input.id});
    expect((await tools.verify()).isPassed, isTrue);
    await manager.db.delete(AgentWorkspaceDao.filesTable,
        where: 'id = ?', whereArgs: [input.id]);
    final reopened =
        await AgentWorkspaceTools.create(manager, cid: 7, workspace: workspace);
    await reopened.beginTurn(101, const [], resume: true);
    expect(reopened.lastReport!.isPassed, isFalse);
    expect(reopened.lastReport!.checks.last.detail, contains('当前文件已不存在'));
    expect(reopened.lastReport!.checks.first.revision, input.revision);
    expect((await reopened.store.loadLatestReport(7))!['isPassed'], isTrue);
  });

  test('old revision read coverage cannot verify changed input', () async {
    final (_, workspace, tools) = await setup();
    final file = await workspace.writeFile(name: 'input.txt', content: '原文');
    await tools.beginTurn(101, [file.id]);
    await tools.tools
        .singleWhere((tool) => tool.name == 'read_file')
        .execute({'file_id': file.id});
    expect((await tools.verify()).isPassed, isTrue);
    final changed = await workspace.writeFile(
        fileId: file.id, name: 'input.txt', content: '修改后的原文');
    expect(changed.id, file.id);
    expect(changed.revision, greaterThan(file.revision));
    expect((await tools.verify()).isPassed, isFalse);
  });

  test('foreign conversation file ids cannot be read or approved for write',
      () async {
    final (manager, _, tools) = await setup(confirm: (_, __) async => true);
    final other = await AgentWorkspaceService.create(manager, cid: 8);
    final file = await other.writeFile(name: 'foreign.txt', content: '秘密');
    await tools.beginTurn(101, const []);
    await expectLater(
        tools.tools
            .singleWhere((tool) => tool.name == 'read_file')
            .execute({'file_id': file.id}),
        throwsFormatException);
    await expectLater(
        tools.tools.singleWhere((tool) => tool.name == 'write_file').execute(
            {'file_id': file.id, 'name': 'foreign.txt', 'content': '改变'}),
        throwsFormatException);
    expect((await other.getRevision(file.id)).content, '秘密');
  });

  test(
      'CSV parser accepts quoted commas/newlines/escaped quotes and rejects malformed rows',
      () {
    for (final content in [
      'a,b\n"c,d",e\n',
      'a,b\r\n"c\nline","d""e"\r\n',
      '\ufeffa,b\n1,2'
    ]) {
      expect(AgentTaskVerifier.csvSyntaxError(content), isNull);
    }
    for (final content in [
      'a,b\n1\n',
      'a,b\n"unclosed,2',
      'a,b\n"c"junk,d',
      'a,b\nq"x,2'
    ]) {
      expect(AgentTaskVerifier.csvSyntaxError(content), isNotNull);
    }
    expect(
        () =>
            const TaskAcceptanceCriteria(minChars: 20, maxChars: 10).validate(),
        throwsFormatException);
  });
}
