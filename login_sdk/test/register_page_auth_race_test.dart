import 'dart:async';
import 'dart:convert';

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/pages/register_page.dart';

void main() {
  late _MemoryTokenStorage storage;

  setUp(() {
    LoginDao.resetHooksForTest();
    storage = _MemoryTokenStorage();
    LoginConfig.instance().homePage = const Scaffold(body: Text('home'));
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
    LoginConfig.instance().homePage = null;
  });

  testWidgets(
    'AuthKit 注册响应在登出后到达时不能重新写回登录态',
    (tester) async {
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      var loginHookFired = 0;
      LoginDao.addLoginHook(() => loginHookFired++);

      Future<http.Response> handler(http.Request request) {
        expect(request.url.path, '/uapi/auth/register');
        requestStarted.complete();
        return responseGate.future;
      }

      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(
          home: RegisterPage(),
        ));

        final allFields = find.byType(TextField);
        expect(allFields, findsNWidgets(3));
        await tester.enterText(allFields.first, 'late@example.com');
        await tester.pump();

        final codeFields = find.descendant(
          of: find.byType(VerificationCodeInput),
          matching: find.byType(TextField),
        );
        expect(codeFields, findsOneWidget);
        await tester.enterText(codeFields, '123456');
        await tester.enterText(allFields.last, 'password-123');

        final agreement = find.textContaining(
          '已阅读并同意',
          findRichText: true,
        );
        await tester.ensureVisible(agreement);
        await tester.tap(agreement);
        await tester.pump();

        final submit = find.widgetWithText(ElevatedButton, '创建账号');
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await _pumpUntil(tester, () => requestStarted.isCompleted);

        await tester.runAsync(
          () => LoginDao.logOut().timeout(const Duration(seconds: 2)),
        );
        responseGate.complete(http.Response(
          jsonEncode({
            'code': 0,
            'data': 'late-register-token',
            'extra': {
              'id': 42,
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

      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.getAccountHash(), isNull);
      expect(loginHookFired, 0);
      expect(find.byType(RegisterPage), findsOneWidget);
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
  expect(condition(), isTrue, reason: '注册请求未在有限泵帧内开始');
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
