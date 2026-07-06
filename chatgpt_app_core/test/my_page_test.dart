import 'package:chatgpt_app_core/pages/my_page.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  testWidgets('个人中心菜单在小屏下可滚动，不发生底部溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: const MaterialApp(home: MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 服务设置'), findsOneWidget);
    expect(find.text('设置主题'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('设置主题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
