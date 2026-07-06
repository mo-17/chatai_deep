import 'package:chatgpt_app_core/model/tool_audit_record.dart';
import 'package:chatgpt_app_core/pages/tool_audit_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('工具审计页展示调用记录并可展开详情', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ToolAuditPage(
        loader: () async => const [
          ToolAuditRecord(
            toolName: 'mcp__srv__echo',
            sourceType: 'mcp',
            sourceId: 'srv',
            sourceName: 'Srv',
            trusted: false,
            readOnly: false,
            approved: true,
            success: true,
            argCount: 1,
            argsPreview: '{"text":"hi"}',
            resultPreview: 'pong:hi',
            createdAt: 20,
          ),
          ToolAuditRecord(
            toolName: 'mcp__srv__write',
            sourceType: 'mcp',
            sourceId: 'srv',
            sourceName: 'Srv',
            trusted: false,
            readOnly: false,
            approved: false,
            success: false,
            argCount: 1,
            argsPreview: '{"text":"no"}',
            resultPreview: '用户拒绝了该 MCP 工具调用，未执行',
            createdAt: 10,
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('工具审计'), findsOneWidget);
    expect(find.text('mcp__srv__echo'), findsOneWidget);
    expect(find.text('Srv · 成功'), findsOneWidget);
    expect(find.text('mcp__srv__write'), findsOneWidget);
    expect(find.text('Srv · 已拒绝'), findsOneWidget);

    await tester.tap(find.text('mcp__srv__echo'));
    await tester.pumpAndSettle();

    expect(find.text('来源：mcp/srv'), findsOneWidget);
    expect(find.textContaining('非信任源'), findsOneWidget);
    expect(find.textContaining('已确认'), findsOneWidget);
    expect(find.textContaining('"text":"hi"'), findsOneWidget);
    expect(find.text('结果：pong:hi'), findsOneWidget);
  });

  testWidgets('工具审计页空状态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ToolAuditPage(loader: () async => const []),
    ));
    await tester.pumpAndSettle();

    expect(find.text('还没有工具调用记录'), findsOneWidget);
  });

  testWidgets('工具审计页错误状态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ToolAuditPage(loader: () async => throw StateError('boom')),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('工具审计加载失败'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
  });
}
