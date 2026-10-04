import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  Future<(HiDBManager, AgentWorkspaceService)> setup({int cid = 7}) async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final manager = HiDBManager.test(db);
    return (manager, await AgentWorkspaceService.create(manager, cid: cid));
  }

  LocalSourceCitation parse(Map<String, dynamic> result, {int cid = 7}) =>
      LocalSourceCitation.fromToolResult(
          toolName: 'read_file', content: result, expectedCid: cid)!;

  test(
      'actual tool read creates UTF16 range, hash, bounded quote and stable identity',
      () async {
    final (manager, workspace) = await setup();
    final text = '前言\n${'甲' * 239}😀${'乙' * 600}\n末尾';
    final file = await workspace.importText(name: '小说.txt', content: text);
    final tools =
        await AgentWorkspaceTools.create(manager, cid: 7, workspace: workspace);
    await tools.beginTurn(101, [file.id]);
    final read = tools.tools.singleWhere((tool) => tool.name == 'read_file');
    final result = await read
        .execute({'file_id': file.id, 'start_line': 2, 'end_line': 2});
    final outer = jsonDecode(result.content) as Map<String, dynamic>;
    final source = result.localSources.single;
    final actual = outer['content'] as String;
    expect(source.startOffset, 3);
    expect(source.endOffset, 3 + actual.length);
    expect(source.startLine, 2);
    expect(source.endLine, 2);
    expect(source.rangeHash, LocalSourceCitation.hashText(actual));
    expect(source.quote, '甲' * 239); // 不能截断 emoji 的 UTF16 代理对。
    expect(source.matchesText(actual), isTrue);
    expect(source.marker, outer['sourceMarker']);
    expect(parse(outer).identityKey, source.identityKey);
    final repeated = await read
        .execute({'file_id': file.id, 'start_line': 2, 'end_line': 2});
    expect(repeated.localSources.single.sourceId, source.sourceId);
    expect(jsonEncode(source.toJson()), isNot(contains('accountHash')));
    final search = await tools.tools
        .singleWhere((tool) => tool.name == 'file_search')
        .execute({'file_id': file.id, 'query': '末尾'});
    expect(search.localSources, isEmpty);
  });

  test('page and validated section labels originate in actual read selectors',
      () async {
    final (_, workspace) = await setup();
    final pdf = await workspace.importText(
        name: 'pages.pdf', content: '', pageTexts: ['第一页😀', '第二页内容']);
    final secondPage = parse(await workspace.readFile(pdf.id, page: 2));
    expect(secondPage.page, 2);
    expect(secondPage.quote, '第二页内容');
    final md = await workspace.importText(
        name: '章节.md', content: '# 第一章\n故事\n# 第二章\n后文');
    final section = parse(await workspace.readFile(md.id, section: ' 第二章 '));
    expect(section.section, '第二章');
    expect(section.quote, '# 第二章\n后文');
    expect(section.startLine, 3);
  });

  test('empty reads never invent a citation', () async {
    final (_, workspace) = await setup();
    final file = await workspace.importText(name: 'empty.txt', content: '');
    final result = await workspace.readFile(file.id);
    expect(result['content'], '');
    expect(LocalSourceCitation.tryParseReadResult(jsonEncode(result)), isNull);
    expect(result['sourceCitation'], isNull);
  });

  test(
      'only complete outer read_file schema recovers citations from checkpoint content',
      () async {
    final (_, workspace) = await setup();
    final file = await workspace.importText(name: 'read.txt', content: '实际正文');
    final result = await workspace.readFile(file.id);
    final encoded = jsonEncode(result);
    expect(LocalSourceCitation.tryParseReadResult(encoded, expectedCid: 7),
        isNotNull);
    expect(
        LocalSourceCitation.fromToolResult(
            toolName: 'file_search', content: encoded),
        isNull);
    expect(
        LocalSourceCitation.fromToolResult(
            toolName: 'fetch_url', content: encoded),
        isNull);
    expect(LocalSourceCitation.tryParseReadResult('原文包含 $encoded'), isNull);
    expect(
        LocalSourceCitation.tryParseReadResult(
            jsonEncode({'content': encoded})),
        isNull);
    expect(LocalSourceCitation.tryParseReadResult(encoded, expectedCid: 8),
        isNull);
    for (final change in <String, dynamic>{
      'workspaceReadVersion': 2,
      'content': '伪造内容',
      'fileId': file.id + 1,
      'revision': 2,
      'startOffset': 1,
      'endOffset': 99,
      'name': '另一个文件.txt',
      'startLine': 55,
      'page': 1,
      'section': '伪造章节',
      'offsetUnit': 'bytes',
      'endExclusive': false,
    }.entries) {
      expect(
          LocalSourceCitation.fromToolResult(
              toolName: 'read_file',
              content: {...result, change.key: change.value}),
          isNull,
          reason: change.key);
    }
    for (final change in <String, dynamic>{
      'quote': '捏造引用',
      'rangeHash': '0' * 64,
      'available': false,
      'sourceId': '../file',
      'endOffset': -1,
      'fileId': -1,
    }.entries) {
      final source = Map<String, dynamic>.from(result['sourceCitation'] as Map);
      source[change.key] = change.value;
      expect(
          LocalSourceCitation.fromToolResult(
              toolName: 'read_file',
              content: {...result, 'sourceCitation': source}),
          isNull,
          reason: change.key);
    }
  });

  test(
      'old citation blocks decode and malformed local entries cannot erase old text',
      () async {
    const old = CitationBlock(
        id: 'cite',
        messageId: 'm',
        createdAt: 1,
        status: MessageBlockStatus.success,
        webResults: [WebSearchResult(url: 'https://example.com')]);
    final oldJson = old.toJson()..remove('localSources');
    expect((MessageBlock.fromJson(oldJson) as CitationBlock).localSources,
        isEmpty);
    final (_, workspace) = await setup();
    final file = await workspace.importText(name: 'data.txt', content: '原文');
    final source = parse(await workspace.readFile(file.id));
    final encoded = MessageBlock.encodeList([
      const MainTextBlock(
          id: 'main',
          messageId: 'm',
          createdAt: 1,
          status: MessageBlockStatus.success,
          content: '旧对话正文'),
      CitationBlock(
          id: 'cite',
          messageId: 'm',
          createdAt: 2,
          status: MessageBlockStatus.success,
          localSources: [source]),
    ]);
    final decodedJson = jsonDecode(encoded) as List;
    (decodedJson[1] as Map)['localSources'].addAll([
      null,
      'unknown',
      {'sourceId': 'bad'}
    ]);
    final blocks = MessageBlock.decodeList(jsonEncode(decodedJson));
    expect((blocks.first as MainTextBlock).content, '旧对话正文');
    final citation = blocks.last as CitationBlock;
    expect(citation.localSources.single.identityKey, source.identityKey);
    expect(citation.localSources.single.available, isTrue);
    final legacySource = source.toJson()..remove('available');
    expect(LocalSourceCitation.tryFromJson(legacySource)!.available, isTrue);
  });

  test(
      'dispatcher combines live and final sources while retaining aliases and paused snapshot',
      () async {
    final (_, workspace) = await setup();
    final file = await workspace.importText(name: 'live.txt', content: '读取原文');
    final source = parse(await workspace.readFile(file.id));
    final alias = LocalSourceCitation.tryFromJson(
        {...source.toJson(), 'sourceId': 'old_alias'})!;
    final store = ChatBlockStore();
    final dispatcher = StreamDispatcher(store, 'm')..start();
    final event = StreamEvent.citation(const [], localSources: [source]);
    dispatcher.onCitation(event.webResults!, localSources: event.localSources!);
    dispatcher.onTextChunk('结论${alias.marker}');
    dispatcher.onCitation(const [WebSearchResult(url: 'https://example.com')],
        localSources: [source, alias]);
    dispatcher.onCitation(const [WebSearchResult(url: 'https://example.com')],
        localSources: [source]);
    dispatcher.onStopped();
    final blocks = store.blocksFor('m');
    expect(blocks.whereType<CitationBlock>(), hasLength(1));
    final citation = blocks.whereType<CitationBlock>().single;
    expect(citation.localSources.map((s) => s.sourceId),
        [source.sourceId, alias.sourceId]);
    expect(citation.webResults, hasLength(1));
    expect(blocks.whereType<MainTextBlock>().single.status,
        MessageBlockStatus.paused);
    final reloaded = MessageBlock.decodeList(MessageBlock.encodeList(blocks));
    expect(
        reloaded.whereType<CitationBlock>().single.localSources, hasLength(2));
  });

  test(
      'registered aliases are clickable but unknown model markers remain plain',
      () async {
    final (_, workspace) = await setup();
    final file = await workspace.importText(name: 'known.txt', content: '原文');
    final source = parse(await workspace.readFile(file.id));
    final alias = LocalSourceCitation.tryFromJson(
        {...source.toJson(), 'sourceId': 'alias'})!;
    final segments = parseCitationTextSegments(
        content: '${source.marker}[原文:invented]${alias.marker}[1]',
        webResults: const [WebSearchResult(url: 'https://web.com')],
        localSources: [source, alias]);
    expect(segments.map((s) => s.localSource?.sourceId),
        [source.sourceId, null, 'alias', null]);
    expect(segments[1].text, '[原文:invented]');
    expect(segments.last.url, 'https://web.com');
  });

  test(
      'updated output resolves the old version and never falls back to latest when old is missing',
      () async {
    final (manager, workspace) = await setup();
    final file =
        await workspace.writeFile(name: 'output.md', content: '前文\n旧版本原文\n后文');
    final source =
        parse(await workspace.readFile(file.id, startLine: 2, endLine: 2));
    await workspace.writeFile(
        fileId: file.id, name: 'output.md', content: '新版本完全不同');
    final resolved = await workspace.resolveCitation(source);
    expect(resolved.content, '旧版本原文\n');
    expect(resolved.isHistorical, isTrue);
    expect(resolved.currentRevision, 2);
    expect(resolved.before, '前文\n');
    await manager.db.delete(AgentWorkspaceDao.revisionsTable,
        where: 'fileId = ? AND revision = ?', whereArgs: [file.id, 1]);
    await expectLater(workspace.resolveCitation(source), throwsFormatException);
  });

  test('deleted, corrupted and wrong-conversation sources explicitly fail',
      () async {
    final (manager, workspace) = await setup();
    final file = await workspace.importText(name: 'safe.txt', content: '真实原文');
    final source = parse(await workspace.readFile(file.id));
    final other = await AgentWorkspaceService.create(manager, cid: 8);
    await expectLater(other.resolveCitation(source), throwsFormatException);
    final corrupt = LocalSourceCitation.tryFromJson(
        {...source.toJson(), 'rangeHash': '0' * 64})!;
    await expectLater(
        workspace.resolveCitation(corrupt), throwsFormatException);
    await manager.db.update(
        AgentWorkspaceDao.revisionsTable, {'content': '篡改正文'},
        where: 'fileId = ? AND revision = ?', whereArgs: [file.id, 1]);
    await expectLater(workspace.resolveCitation(source), throwsFormatException);
    await manager.db.delete(AgentWorkspaceDao.filesTable,
        where: 'id = ?', whereArgs: [file.id]);
    await expectLater(workspace.resolveCitation(source), throwsFormatException);
  });

  test(
      'import remapping preserves body markers and validates the mapped original version',
      () async {
    final (_, original) = await setup();
    final file = await original.importText(name: 'import.txt', content: '导入原文');
    final source = parse(await original.readFile(file.id));
    final (_, imported) = await setup(cid: 88);
    await imported.importText(name: 'unrelated.txt', content: '另一个文件');
    final target =
        await imported.importText(name: 'import.txt', content: '导入原文');
    final remapped = source.remap(cid: 88, fileId: target.id);
    expect(remapped.sourceId, source.sourceId);
    expect(remapped.marker, source.marker);
    expect(remapped.identityKey, isNot(source.identityKey));
    expect((await imported.resolveCitation(remapped)).content, '导入原文');
    final missing = source.remap(cid: null, fileId: null);
    expect(missing.available, isFalse);
    expect(missing.quote, source.quote);
    await expectLater(original.resolveCitation(missing), throwsFormatException);
    expect(missing.remap(cid: 7, fileId: file.id).available, isFalse);
    final missingVersion =
        source.remap(cid: 88, fileId: target.id, revisionAvailable: false);
    await expectLater(
        imported.resolveCitation(missingVersion), throwsFormatException);
  });
}
