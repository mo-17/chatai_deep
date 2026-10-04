import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/chat/ui/local_source_viewer_page.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

LocalSourceCitation fixtureSource() => LocalSourceCitation.forRead(
    cid: 7,
    fileId: 1,
    revision: 1,
    fileName: '小说.txt',
    startOffset: 3,
    content: '实际引用正文',
    startLine: 2,
    endLine: 2);

ResolvedLocalSource fixtureResolved(LocalSourceCitation source) =>
    ResolvedLocalSource(
        source: source,
        currentRevision: 2,
        before: '前文\n',
        content: '实际引用正文',
        after: '\n后文');

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets(
      'one tap opens stored original revision and highlights actual full read range',
      (tester) async {
    late Database db;
    late AgentWorkspaceService workspace;
    late LocalSourceCitation source;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      workspace =
          await AgentWorkspaceService.create(HiDBManager.test(db), cid: 7);
      final file =
          await workspace.writeFile(name: '小说.md', content: '开头\n实际原文😀\n结尾');
      final read = await workspace.readFile(file.id, startLine: 2, endLine: 2);
      source = LocalSourceCitation.fromToolResult(
          toolName: 'read_file', content: read)!;
      await workspace.writeFile(
          fileId: file.id, name: '小说.md', content: '文件已经更新');
    });
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LocalSourceLink(
                source: source,
                inline: true,
                sourceAccountHash: 'account-A',
                currentAccountHash: () => 'account-A',
                loadSource: workspace.resolveCitation))));
    await tester.tap(find.text('[原文]'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.byType(LocalSourceViewerPage), findsOneWidget);
    expect(find.text('正在查看引用时的 v1，当前文件为 v2。'), findsOneWidget);
    final text = tester.widget<SelectableText>(
        find.byKey(const ValueKey('local-source-highlight')));
    final spans = text.textSpan!.children!.whereType<TextSpan>().toList();
    expect(spans.singleWhere((s) => s.style?.backgroundColor != null).text,
        '实际原文😀\n');
    expect(text.textSpan!.toPlainText(), contains('开头\n实际原文😀\n结尾'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'source cards deduplicate identity while repeated known inline markers stay clickable',
      (tester) async {
    final source = fixtureSource();
    final alias = LocalSourceCitation.tryFromJson(
        {...source.toJson(), 'sourceId': 'restored_alias'})!;
    final store = ChatBlockStore();
    store.seedMessage('m', [
      MainTextBlock(
          id: 'main',
          messageId: 'm',
          createdAt: 1,
          status: MessageBlockStatus.success,
          content: '结论${source.marker} 再次${source.marker} [原文:invented]'),
      CitationBlock(
          id: 'cite',
          messageId: 'm',
          createdAt: 2,
          status: MessageBlockStatus.success,
          localSources: [source, alias]),
    ]);
    store.commitSeed();
    await tester.pumpWidget(MaterialApp(
        theme: AppThemeFactory.anime(),
        home: Scaffold(
            body: ChangeNotifierProvider.value(
                value: store,
                child: const BlockMessageContent(
                    messageKey: 'm', sourceAccountHash: 'account-A')))));
    final links = tester
        .widgetList<LocalSourceLink>(find.byType(LocalSourceLink))
        .toList();
    expect(links.where((link) => link.inline), hasLength(2));
    expect(links.where((link) => !link.inline), hasLength(1));
    final inlineSemantics = find.byWidgetPredicate((widget) =>
        widget is Semantics &&
        widget.properties.link == true &&
        widget.properties.label == '打开原文 ${source.locationLabel}');
    expect(inlineSemantics, findsNWidgets(3));
    for (final inline in find
        .byType(LocalSourceLink)
        .evaluate()
        .where((element) => (element.widget as LocalSourceLink).inline)) {
      expect(
          tester
              .getSize(find
                  .byElementPredicate((element) => identical(element, inline)))
              .height,
          44);
    }
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .where((widget) => widget.textSpan != null)
        .first;
    expect(text.textSpan!.toPlainText(), contains('[原文:invented]'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unknown marker without a source remains ordinary text in old conversation',
      (tester) async {
    final store = ChatBlockStore();
    store.seedMessage('old', [
      const MainTextBlock(
          id: 'old-main',
          messageId: 'old',
          createdAt: 1,
          status: MessageBlockStatus.success,
          content: '旧正文[原文:invented]')
    ]);
    store.commitSeed();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChangeNotifierProvider.value(
                value: store,
                child: const BlockMessageContent(messageKey: 'old')))));
    expect(find.text('旧正文[原文:invented]'), findsOneWidget);
    expect(find.byType(LocalSourceLink), findsNothing);
  });

  testWidgets(
      'unavailable imported citation shows saved quote without reading another same-id file',
      (tester) async {
    final source = fixtureSource().remap(cid: null, fileId: null);
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        home: LocalSourceViewerPage(
            source: source,
            expectedAccountHash: 'A',
            currentAccountHash: () => 'A',
            loadSource: (source) async {
              loads++;
              return fixtureResolved(source);
            })));
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(find.text('原文不可用：备份未包含此文件或对应版本'), findsOneWidget);
    expect(find.text('保存的引用摘录'), findsOneWidget);
    expect(find.text(source.quote), findsOneWidget);
    expect(find.byKey(const ValueKey('local-source-highlight')), findsNothing);
  });

  testWidgets(
      'link captures original account before account switches and refuses database load',
      (tester) async {
    final source = fixtureSource();
    var account = 'A';
    var loads = 0;
    Widget build() => MaterialApp(
        home: Scaffold(
            body: LocalSourceLink(
                key: const ValueKey('stable-link'),
                source: source,
                currentAccountHash: () => account,
                loadSource: (source) async {
                  loads++;
                  return fixtureResolved(source);
                })));
    await tester.pumpWidget(build());
    account = 'B';
    await tester.pumpWidget(build());
    await tester.tap(find.text(source.locationLabel));
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(find.text('原文不可用：账号已切换，请回到原账号查看'), findsOneWidget);
    expect(find.text(source.quote), findsNothing);
    expect(find.text('保存的引用摘录'), findsNothing);
    expect(find.byKey(const ValueKey('local-source-highlight')), findsNothing);
  });

  testWidgets(
      'account switch during async load discards the returned original text',
      (tester) async {
    final source = fixtureSource();
    final result = Completer<ResolvedLocalSource>();
    var account = 'A';
    await tester.pumpWidget(MaterialApp(
        home: LocalSourceViewerPage(
            source: source,
            expectedAccountHash: 'A',
            currentAccountHash: () => account,
            loadSource: (_) => result.future)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    account = 'B';
    result.complete(fixtureResolved(source));
    await tester.pumpAndSettle();
    expect(find.text('原文不可用：账号已切换，请回到原账号查看'), findsOneWidget);
    expect(find.text(source.quote), findsNothing);
    expect(find.text('保存的引用摘录'), findsNothing);
    expect(find.byKey(const ValueKey('local-source-highlight')), findsNothing);
  });

  testWidgets(
      'deleted original revision reports unavailable rather than leaving a spinner or new text',
      (tester) async {
    final source = fixtureSource();
    await tester.pumpWidget(MaterialApp(
        home: LocalSourceViewerPage(
            source: source,
            expectedAccountHash: 'A',
            currentAccountHash: () => 'A',
            loadSource: (_) async {
              throw const FormatException('原文不可用：引用版本已删除');
            })));
    await tester.pumpAndSettle();
    expect(find.text('原文不可用：引用版本已删除'), findsOneWidget);
    expect(find.text(source.quote), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
