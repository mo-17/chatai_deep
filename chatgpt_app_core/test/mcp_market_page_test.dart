import 'package:chatgpt_app_core/pages/mcp_market_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('高权限 MCP 条目只展示入口说明，不直接返回直连配置', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: McpMarketPage()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('GitHub'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('复制入口'), findsOneWidget);
    expect(find.textContaining('token 权限最小化'), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(TextButton, '知道了'));
    await tester.pumpAndSettle();
    expect(find.text('复制入口'), findsNothing);
  });
}
