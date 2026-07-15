import 'dart:async';
import 'dart:convert';

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/pages/login_page.dart';

void main() {
  late _MemoryTokenStorage storage;

  setUp(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
    storage = _MemoryTokenStorage();
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  test('LoginSdkConfig.copyWith 保留宿主认证依赖', () {
    final dependencies = LoginAuthDependencies(
      authDao: _authDao((_) async => _okResponse()),
      appleSignInService: const _FakeAppleService(),
    );
    final config = _config(storage: storage, dependencies: dependencies);

    final copied = config.copyWith(storage: _MemoryTokenStorage());

    expect(identical(copied.authDependencies, dependencies), isTrue);
  });

  testWidgets(
    'widget 注入 Apple 完成绑定后只保存并回调一次',
    (tester) async {
      final paths = <String>[];
      final bodies = <String, Map<String, dynamic>>{};
      final authDao = _authDao((request) async {
        paths.add(request.url.path);
        bodies[request.url.path] =
            jsonDecode(request.body) as Map<String, dynamic>;
        switch (request.url.path) {
          case '/uapi/auth/apple/login':
            return _okResponse(data: const {
              'needBinding': true,
              'bindTicket': 'apple-bind-ticket',
            });
          case '/uapi/auth/code/send':
            return _okResponse();
          case '/uapi/auth/apple/bind-and-login':
            return _okResponse(
              data: 'apple-final-token',
              extra: const {
                'id': 71,
                'userName': 'bound-apple-user',
                'email': 'bound@example.com',
                'emailVerified': true,
                'phone': null,
                'phoneVerified': false,
                'avatar': 'https://example.com/apple.png',
                'role': 'user',
              },
            );
          default:
            throw StateError('unexpected request: ${request.url.path}');
        }
      });
      final widgetDependencies = LoginAuthDependencies(
        authDao: authDao,
        appleSignInService: const _FakeAppleService(),
      );
      final installedDependencies = LoginAuthDependencies(
        authDao: _authDao(
          (_) async => throw StateError('installed dao must not be used'),
        ),
        appleSignInService: const _ThrowingAppleService(),
      );
      LoginSdkConfig.install(_config(
        storage: storage,
        dependencies: installedDependencies,
      ));
      var loginHookCalls = 0;
      var successCalls = 0;
      LoginDao.addLoginHook(() => loginHookCalls++);

      await _pumpLoginPage(
        tester,
        dependencies: widgetDependencies,
        onLoginSuccess: () => successCalls++,
      );
      await _openAppleBinding(tester);
      await _submitBinding(tester, identifier: 'bound@example.com');
      await _pumpNetworkUntil(
        tester,
        () =>
            find.byType(BindIdentityPage).evaluate().isEmpty &&
            storage.readTokenSync() == 'apple-final-token',
        reason: 'Apple 绑定完成后未在有限轮询内返回登录页并保存 token',
      );

      expect(paths.where((path) => path == '/uapi/auth/apple/login'),
          hasLength(1));
      expect(
          paths.where((path) => path == '/uapi/auth/code/send'), hasLength(1));
      expect(paths.where((path) => path == '/uapi/auth/apple/bind-and-login'),
          hasLength(1));
      expect(bodies['/uapi/auth/apple/login'], {
        'identityToken': 'apple-identity-token',
        'authorizationCode': 'apple-authorization-code',
        'fullName': {'givenName': 'Ada', 'familyName': 'Lovelace'},
      });
      expect(bodies['/uapi/auth/apple/bind-and-login'], {
        'bindTicket': 'apple-bind-ticket',
        'channel': 'email',
        'identifier': 'bound@example.com',
        'code': '123456',
      });
      expect(find.byType(BindIdentityPage), findsNothing);
      expect(storage.writeCalls, 1);
      expect(storage.readProfileSync()?['userName'], 'bound-apple-user');
      expect(loginHookCalls, 1);
      expect(successCalls, 1);
    },
  );

  testWidgets('绑定页返回取消时不保存也不回调', (tester) async {
    var providerLoginCalls = 0;
    final authDao = _authDao((request) async {
      if (request.url.path != '/uapi/auth/apple/login') {
        throw StateError('unexpected request: ${request.url.path}');
      }
      providerLoginCalls++;
      return _okResponse(data: const {
        'needBinding': true,
        'bindTicket': 'cancel-bind-ticket',
      });
    });
    LoginSdkConfig.install(_config(storage: storage));
    var loginHookCalls = 0;
    var successCalls = 0;
    LoginDao.addLoginHook(() => loginHookCalls++);

    await _pumpLoginPage(
      tester,
      dependencies: LoginAuthDependencies(
        authDao: authDao,
        appleSignInService: const _FakeAppleService(),
      ),
      onLoginSuccess: () => successCalls++,
    );
    await _openAppleBinding(tester);
    await tester.pageBack();
    await _pumpUntil(
      tester,
      () => find.byType(BindIdentityPage).evaluate().isEmpty,
      reason: '绑定页取消后未在有限泵帧内关闭',
    );

    expect(providerLoginCalls, 1);
    expect(storage.writeCalls, 0);
    expect(LoginDao.getBoardingPass(), isNull);
    expect(loginHookCalls, 0);
    expect(successCalls, 0);
  });

  testWidgets('绑定响应返回前出现更新认证时旧结果不会保存或回调', (tester) async {
    final bindStarted = Completer<void>();
    final bindResponse = Completer<http.Response>();
    var providerLoginCalls = 0;
    var bindCalls = 0;
    final authDao = _authDao((request) {
      switch (request.url.path) {
        case '/uapi/auth/apple/login':
          providerLoginCalls++;
          return Future.value(_okResponse(data: const {
            'needBinding': true,
            'bindTicket': 'stale-bind-ticket',
          }));
        case '/uapi/auth/code/send':
          return Future.value(_okResponse());
        case '/uapi/auth/apple/bind-and-login':
          bindCalls++;
          bindStarted.complete();
          return bindResponse.future;
        default:
          throw StateError('unexpected request: ${request.url.path}');
      }
    });
    LoginSdkConfig.install(_config(storage: storage));
    var loginHookCalls = 0;
    var successCalls = 0;
    LoginDao.addLoginHook(() => loginHookCalls++);

    await _pumpLoginPage(
      tester,
      dependencies: LoginAuthDependencies(
        authDao: authDao,
        appleSignInService: const _FakeAppleService(),
      ),
      onLoginSuccess: () => successCalls++,
    );
    await _openAppleBinding(tester);
    await _submitBinding(tester, identifier: 'stale@example.com');
    await _pumpNetworkUntil(
      tester,
      () => bindStarted.isCompleted,
      reason: '绑定请求未在有限轮询内开始',
    );

    final newerAttempt = LoginDao.beginAuthAttempt();
    bindResponse.complete(_okResponse(
      data: 'stale-final-token',
      extra: const {
        'id': 72,
        'userName': 'stale-user',
        'email': 'stale@example.com',
        'emailVerified': true,
        'phone': null,
        'phoneVerified': false,
        'avatar': null,
        'role': 'user',
      },
    ));
    await _pumpNetworkUntil(
      tester,
      () => find.byType(BindIdentityPage).evaluate().isEmpty,
      reason: '过期绑定响应未在有限轮询内关闭绑定页',
    );

    expect(providerLoginCalls, 1);
    expect(bindCalls, 1);
    expect(storage.writeCalls, 0);
    expect(LoginDao.getBoardingPass(), isNull);
    expect(loginHookCalls, 0);
    expect(successCalls, 0);
    LoginDao.cancelAuthAttempt(newerAttempt);
  });

  testWidgets('未传 widget override 时使用 LoginSdkConfig 注入并保存直接 token',
      (tester) async {
    var providerLoginCalls = 0;
    final dependencies = LoginAuthDependencies(
      authDao: _authDao((request) async {
        expect(request.url.path, '/uapi/auth/apple/login');
        providerLoginCalls++;
        return _okResponse(
          data: 'direct-apple-token',
          extra: const {
            'id': 73,
            'userName': 'direct-apple-user',
            'email': 'direct@example.com',
            'emailVerified': true,
            'phone': null,
            'phoneVerified': false,
            'avatar': null,
            'role': 'user',
          },
        );
      }),
      appleSignInService: const _FakeAppleService(),
    );
    LoginSdkConfig.install(
      _config(storage: storage, dependencies: dependencies),
    );
    var successCalls = 0;

    await _pumpLoginPage(
      tester,
      onLoginSuccess: () => successCalls++,
    );
    final apple = find.text('Apple');
    await tester.ensureVisible(apple);
    await tester.tap(apple);
    await _pumpNetworkUntil(
      tester,
      () => storage.readTokenSync() == 'direct-apple-token',
      reason: '配置注入的 Apple 直接 token 未在有限轮询内保存',
    );

    expect(providerLoginCalls, 1);
    expect(storage.writeCalls, 1);
    expect(storage.readProfileSync()?['userName'], 'direct-apple-user');
    expect(successCalls, 1);
  });
}

LoginSdkConfig _config({
  required TokenStorage storage,
  LoginAuthDependencies? dependencies,
}) {
  return LoginSdkConfig(
    baseUrl: 'https://unused.example.test',
    useHttps: true,
    headerProvider: () async => <String, String>{},
    syncHeaders: () => const <String, String>{},
    routes: LoginRoutes.imooc,
    responseAdapter: ImoocResponseAdapter(),
    storage: storage,
    onLogoutNavigate: () {},
    authDependencies: dependencies,
  );
}

AuthDao _authDao(
  Future<http.Response> Function(http.Request request) handler,
) {
  return AuthDao(AuthApiClient(
    baseUrl: 'https://auth.example.test',
    headerProvider: () async => <String, String>{},
    httpClient: MockClient(handler),
  ));
}

http.Response _okResponse({
  Object? data,
  Map<String, dynamic> extra = const {},
}) {
  return http.Response(
    jsonEncode({'code': 0, 'data': data, 'extra': extra}),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _pumpLoginPage(
  WidgetTester tester, {
  LoginAuthDependencies? dependencies,
  required VoidCallback onLoginSuccess,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: LoginPage(
      authDependencies: dependencies,
      onLoginSuccess: onLoginSuccess,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openAppleBinding(WidgetTester tester) async {
  final apple = find.text('Apple');
  expect(apple, findsOneWidget);
  await tester.ensureVisible(apple);
  await tester.tap(apple);
  await _pumpNetworkUntil(
    tester,
    () => find.byType(BindIdentityPage).evaluate().isNotEmpty,
    reason: 'Apple 登录未在有限轮询内打开绑定页',
  );
}

Future<void> _submitBinding(
  WidgetTester tester, {
  required String identifier,
}) async {
  final bindPage = find.byType(BindIdentityPage);
  final identifierField = find.descendant(
    of: bindPage,
    matching: find.byType(TextField),
  );
  expect(identifierField, findsOneWidget);
  await tester.enterText(identifierField, identifier);

  final sendButton = find.descendant(
    of: bindPage,
    matching: find.byType(ElevatedButton),
  );
  expect(sendButton, findsOneWidget);
  await tester.tap(sendButton);
  await _pumpNetworkUntil(
    tester,
    () => find.byType(VerificationCodeInput).evaluate().isNotEmpty,
    reason: '绑定验证码输入框未在有限轮询内出现',
  );

  final codeFields = find.descendant(
    of: find.byType(VerificationCodeInput),
    matching: find.byType(TextField),
  );
  expect(codeFields, findsNWidgets(6));
  for (var index = 0; index < 6; index++) {
    await tester.enterText(codeFields.at(index), '${index + 1}');
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var index = 0; index < 100 && !condition(); index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _pumpNetworkUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var index = 0; index < 40 && !condition(); index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;
  int writeCalls = 0;

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
    writeCalls++;
    _profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode.toString(),
      ...extras,
    };
  }
}

final class _FakeAppleService implements IAppleSignInService {
  const _FakeAppleService();

  @override
  bool get isAvailable => true;

  @override
  Future<AppleSignInResult> signIn() async => const AppleSignInResult(
        identityToken: 'apple-identity-token',
        authorizationCode: 'apple-authorization-code',
        givenName: 'Ada',
        familyName: 'Lovelace',
        email: 'ada@example.com',
      );
}

final class _ThrowingAppleService implements IAppleSignInService {
  const _ThrowingAppleService();

  @override
  bool get isAvailable => true;

  @override
  Future<AppleSignInResult> signIn() {
    throw StateError('installed Apple service must not be used');
  }
}
