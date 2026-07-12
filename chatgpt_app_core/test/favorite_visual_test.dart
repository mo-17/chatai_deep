import 'dart:ui' show SemanticsAction;

import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/pages/meessage_detail_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/favorite_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final model = FavoriteModel(
    ownerName: '艾普',
    createdAt: DateTime(2026, 7, 12).millisecondsSinceEpoch,
    content: '一段值得收藏的回复',
  );

  testWidgets('收藏卡在二次元模式使用语义色和可点击语义', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: Scaffold(
          body: FavoriteWidget(
            model: model,
            onLongPress: (_, __) {},
            onTap: (_, __) {},
          ),
        ),
      ),
    );

    final owner = tester.widget<Text>(find.text('艾普'));
    final context = tester.element(find.text('艾普'));
    expect(owner.style?.color, Theme.of(context).colorScheme.onSurfaceVariant);
    final semanticsNode = tester.getSemantics(
      find.bySemanticsLabel('收藏内容：一段值得收藏的回复'),
    );
    expect(
      semanticsNode.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(
      semanticsNode.getSemanticsData().hasAction(SemanticsAction.longPress),
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('收藏详情仅在二次元模式增加内容卡面', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> pump(ThemeData theme) => tester.pumpWidget(
          MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            home: MessageDetailPage(model: model),
          ),
        );

    await pump(AppThemeFactory.classic(Colors.blue));
    expect(find.byKey(const ValueKey('favorite_detail_surface')), findsNothing);

    await pump(AppThemeFactory.anime());
    expect(
      find.byKey(const ValueKey('favorite_detail_surface')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.8),
          ),
          child: MessageDetailPage(model: model),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
