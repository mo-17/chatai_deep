import 'package:chatgpt_app_core/pages/assistant_market_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('助手市场可按名称搜索模板', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AssistantMarketPage()));

    await tester.enterText(
      find.byKey(const ValueKey('assistant_market_search')),
      '代码审查',
    );
    await tester.pumpAndSettle();

    expect(find.text('代码审查员'), findsOneWidget);
    expect(find.text('周报生成器'), findsNothing);
    expect(find.byKey(const ValueKey('assistant_market_empty')), findsNothing);
  });

  testWidgets('助手市场可按分类搜索并保留分类分组', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AssistantMarketPage()));

    await tester.enterText(
      find.byKey(const ValueKey('assistant_market_search')),
      '翻译',
    );
    await tester.pumpAndSettle();

    expect(find.text('翻译'), findsWidgets);
    expect(find.text('中英互译'), findsOneWidget);
    expect(find.text('营销文案写手'), findsNothing);
  });

  testWidgets('助手市场搜索无命中时展示空态', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AssistantMarketPage()));

    await tester.enterText(
      find.byKey(const ValueKey('assistant_market_search')),
      '___no_such_template___',
    );
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('assistant_market_empty')), findsOneWidget);
    expect(find.text('未找到匹配的助手'), findsOneWidget);
    expect(find.text('代码审查员'), findsNothing);
  });
}
