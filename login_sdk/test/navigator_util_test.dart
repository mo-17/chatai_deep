import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/pages/login_page.dart';
import 'package:login_sdk/util/navigator_util.dart';

void main() {
  tearDown(() => LoginConfig.instance().homePage = null);

  testWidgets('goToLogin 清空旧账号的整个导航栈', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => Builder(builder: (nestedContext) {
                  return Scaffold(
                    body: FilledButton(
                      onPressed: () {
                        NavigatorUtil.updateContext(nestedContext);
                        NavigatorUtil.goToLogin();
                      },
                      child: const Text('401'),
                    ),
                  );
                }),
              ),
            ),
            child: const Text('打开旧账号二级页'),
          ),
        );
      }),
    ));

    await tester.tap(find.text('打开旧账号二级页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('401'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('goToHome 清空登录页下方残留的旧账号路由', (tester) async {
    LoginConfig.instance().homePage = const Scaffold(body: Text('新账号首页'));
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => Builder(builder: (loginContext) {
                  return Scaffold(
                    body: FilledButton(
                      onPressed: () => NavigatorUtil.goToHome(loginContext),
                      child: const Text('登录成功'),
                    ),
                  );
                }),
              ),
            ),
            child: const Text('旧账号首页'),
          ),
        );
      }),
    ));

    await tester.tap(find.text('旧账号首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录成功'));
    await tester.pumpAndSettle();

    expect(find.text('新账号首页'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });
}
