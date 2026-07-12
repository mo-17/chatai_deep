import 'package:chatgpt_app_core/pages/assistant_market_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpMarket(
    WidgetTester tester, {
    required ThemeData theme,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 640),
            textScaler: TextScaler.linear(textScale),
          ),
          child: const AssistantMarketPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('二次元助手市场在窄屏大字下使用卡面和头像外框', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMarket(
      tester,
      theme: AppThemeFactory.anime(),
      textScale: 1.8,
    );

    expect(
      find.byKey(const ValueKey('assistant_market_card_营销文案写手')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime_assistant_avatar')),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('经典风格不注入二次元卡面和头像外框', (tester) async {
    await pumpMarket(
      tester,
      theme: AppThemeFactory.classic(Colors.pink),
    );

    expect(
      find.byKey(const ValueKey('assistant_market_card_营销文案写手')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('anime_assistant_avatar')),
      findsNothing,
    );
  });
}
