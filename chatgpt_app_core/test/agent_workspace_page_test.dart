import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/creative_file_transfer_gateway.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/pages/agent_workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('成果预览与导出使用当前版本UTF8字节，取消不报告成功', (tester) async {
    late Database db;
    late AgentWorkspaceService workspace;
    late AgentWorkspaceTools tools;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      final manager = HiDBManager.test(db);
      workspace = await AgentWorkspaceService.create(manager, cid: 11);
      tools = await AgentWorkspaceTools.create(manager,
          cid: 11, workspace: workspace);
      await workspace.writeFile(
          name: 'report.csv', content: 'name,text\nfile,旧内容');
      await workspace.writeFile(
          name: 'report.csv', content: 'name,text\nfile,新内容');
    });
    addTearDown(db.close);
    Uint8List? saved;
    var attempts = 0;
    final transfer = CreativeFileTransferGateway(saveFile: (
        {dialogTitle,
        fileName,
        initialDirectory,
        allowedExtensions,
        required bytes}) async {
      saved = bytes;
      attempts++;
      return attempts == 1 ? null : '/test/report.csv';
    });
    await tester.pumpWidget(MaterialApp(
        home: AgentWorkspacePage(
            workspace: workspace, tools: tools, transfer: transfer)));
    await _settle(tester);
    await tester.tap(find.text('成果'));
    await _settle(tester);
    expect(find.text('report.csv'), findsOneWidget);
    await tester.tap(find.text('report.csv'));
    await _settle(tester);
    expect(find.text('name,text\nfile,新内容'), findsOneWidget);
    await tester.tap(find.byTooltip('导出文件'));
    await _settle(tester);
    expect(utf8.decode(saved!), 'name,text\nfile,新内容');
    expect(find.text('文件已导出'), findsNothing);
    await tester.tap(find.byTooltip('导出文件'));
    await _settle(tester);
    expect(find.text('文件已导出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('运行中工作区可查看，禁用成果编辑与验收条件修改', (tester) async {
    late Database db;
    late AgentWorkspaceService workspace;
    late AgentWorkspaceTools tools;
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      final manager = HiDBManager.test(db);
      workspace = await AgentWorkspaceService.create(manager, cid: 12);
      tools = await AgentWorkspaceTools.create(manager,
          cid: 12, workspace: workspace);
    });
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
        home: AgentWorkspacePage(
            workspace: workspace, tools: tools, readOnly: true)));
    await _settle(tester);
    expect(find.byTooltip('新建成果'), findsNothing);
    expect(find.byTooltip('导入文件'), findsNothing);
    await tester.tap(find.text('条件'));
    await _settle(tester);
    final button = tester.widget<FilledButton>(find.ancestor(
        of: find.text('修改验收条件'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton)));
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}
