import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/login_page.dart';
import 'package:login_sdk/pages/register_page.dart';

void main() {
  late _MemoryTokenStorage storage;
  late Future<http.Response> Function(http.Request) activeHandler;

  setUpAll(() async {
    await http.runWithClient(
      () async => AuthDaoBridge.client,
      () => MockClient((request) => activeHandler(request)),
    );
  });

  setUp(() {
    LoginDao.resetHooksForTest();
    storage = _MemoryTokenStorage();
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => <String, String>{},
      syncHeaders: () => const <String, String>{},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: storage,
      onLogoutNavigate: () {},
    ));
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  testWidgets(
    'AuthKit 密码登录响应在登出后到达时不能重新写回登录态',
    (tester) async {
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      var loginHookFired = 0;
      LoginDao.addLoginHook(() => loginHookFired++);

      activeHandler = (http.Request request) {
        expect(request.url.path, '/uapi/auth/login/password');
        requestStarted.complete();
        return responseGate.future;
      };

      await tester.pumpWidget(MaterialApp(
        home: LoginPage(onLoginSuccess: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField).at(0), 'late@example.com');
      await tester.enterText(find.byType(TextField).at(1), 'password-123');

      final agreement = find.textContaining(
        '已阅读并同意',
        findRichText: true,
      );
      await tester.ensureVisible(agreement);
      await tester.tap(agreement);
      await tester.pump();

      final submit = find.widgetWithText(ElevatedButton, '登录');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await _pumpUntil(tester, () => requestStarted.isCompleted);

      await tester.runAsync(
        () => LoginDao.logOut().timeout(const Duration(seconds: 2)),
      );
      responseGate.complete(http.Response(
        jsonEncode({
          'code': 0,
          'data': 'late-auth-kit-token',
          'extra': {
            'id': 41,
            'userName': 'late-user',
            'email': 'late@example.com',
            'emailVerified': true,
            'phone': null,
            'phoneVerified': false,
            'avatar': 'https://example.com/avatar.png',
            'role': 'user',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.getAccountHash(), isNull);
      expect(loginHookFired, 0);
    },
  );

  testWidgets(
    '认证资料写入后页面销毁会取消句柄并回滚阻塞中的 ready hook',
    (tester) async {
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      final readyStarted = Completer<void>();
      final releaseReady = Completer<void>();
      var loginHookFired = 0;
      var pageSuccessCount = 0;
      LoginDao.addLoginReadyHook(() async {
        readyStarted.complete();
        await releaseReady.future;
      });
      LoginDao.addLoginHook(() => loginHookFired++);

      activeHandler = (http.Request request) {
        expect(request.url.path, '/uapi/auth/login/password');
        requestStarted.complete();
        return responseGate.future;
      };

      await tester.pumpWidget(MaterialApp(
        home: LoginPage(onLoginSuccess: () => pageSuccessCount++),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
        find.byType(TextField).at(0),
        'dispose@example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'password-123');

      final agreement = find.textContaining(
        '已阅读并同意',
        findRichText: true,
      );
      await tester.ensureVisible(agreement);
      await tester.tap(agreement);
      await tester.pump();

      final submit = find.widgetWithText(ElevatedButton, '登录');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await _pumpUntil(
        tester,
        () => requestStarted.isCompleted,
        reason: '登录请求未在有限泵帧内开始',
      );

      responseGate.complete(http.Response(
        jsonEncode({
          'code': 0,
          'data': 'disposed-auth-kit-token',
          'extra': {
            'id': 44,
            'userName': 'disposed-user',
            'email': 'dispose@example.com',
            'emailVerified': true,
            'phone': null,
            'phoneVerified': false,
            'avatar': 'https://example.com/disposed.png',
            'role': 'user',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ));
      await _pumpNetworkUntil(
        tester,
        () => readyStarted.isCompleted,
        reason: 'ready hook 未在有限异步轮询内开始',
      );

      final loginElement = tester.element(find.byType(LoginPage));
      final registerLink = find.text('注册新账号');
      await tester.ensureVisible(registerLink);
      await tester.tap(registerLink);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final registerWasShown = find.byType(RegisterPage).evaluate().isNotEmpty;
      final forgotPasswordWasShown =
          find.byType(ForgotPasswordPage).evaluate().isNotEmpty;
      final loginRouteStayedCurrent =
          ModalRoute.of(loginElement)?.isCurrent ?? false;

      await tester.pumpWidget(
        const MaterialApp(home: SizedBox.shrink()),
      );
      releaseReady.complete();
      await _pumpNetworkUntil(
        tester,
        () => storage.clearCalls > 0,
        reason: '页面销毁后认证写入未回滚',
      );

      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.getAccountHash(), isNull);
      expect(loginHookFired, 0);
      expect(pageSuccessCount, 0);
      expect(registerWasShown, isFalse);
      expect(forgotPasswordWasShown, isFalse);
      expect(loginRouteStayedCurrent, isTrue);
    },
  );

  testWidgets('空闲时注册辅助链接仍可正常进入注册页', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LoginPage(onLoginSuccess: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    final registerLink = find.text('注册新账号');
    await tester.ensureVisible(registerLink);
    await tester.tap(registerLink);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(RegisterPage), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(home: SizedBox.shrink()),
    );
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = '条件未在有限泵帧内满足',
}) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _pumpNetworkUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 20 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    _profile = null;
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode.toString(),
      ...extras,
    };
  }
}
