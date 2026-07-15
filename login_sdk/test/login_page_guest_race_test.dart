import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/pages/login_page.dart';

void main() {
  late _MemoryTokenStorage storage;

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
    '切换游客模式后迟到的 AuthKit 登录响应不能覆盖游客态',
    (tester) async {
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      var loginHookFired = 0;
      var pageSuccessCount = 0;
      LoginDao.addLoginHook(() => loginHookFired++);

      Future<http.Response> handler(http.Request request) {
        expect(request.url.path, '/uapi/auth/login/password');
        requestStarted.complete();
        return responseGate.future;
      }

      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          home: LoginPage(onLoginSuccess: () => pageSuccessCount++),
        ));
        await tester.enterText(
            find.byType(TextField).at(0), 'late@example.com');
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
          () => LoginDao.loginAsGuest().timeout(const Duration(seconds: 2)),
        );
        responseGate.complete(http.Response(
          jsonEncode({
            'code': 0,
            'data': 'late-auth-kit-token',
            'extra': {
              'id': 43,
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
      }, () => MockClient(handler));

      expect(LoginDao.getBoardingPass(), LoginDao.kGuestToken);
      expect(LoginDao.getAccountHash(), 'guest');
      expect(LoginDao.isGuest(), isTrue);
      expect(loginHookFired, 1);
      expect(pageSuccessCount, 0);
    },
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var i = 0; i < 20 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: '登录请求未在有限泵帧内开始');
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  @override
  Future<void> clear() async => _profile = null;

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
