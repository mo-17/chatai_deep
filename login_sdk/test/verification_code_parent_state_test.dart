import 'dart:async';
import 'dart:convert';
import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart' hide LoginResult;
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/login_page.dart';
import 'package:login_sdk/pages/register_page.dart';
import 'support/memory_token_storage.dart';

class _FakeDao extends AuthDao {
  final registerCodes = <String>[];
  final loginCodes = <String>[];
  int sends = 0;
  Future<void>? sendResult;
  _FakeDao()
      : super(AuthApiClient(
            baseUrl: 'https://auth.synthetic.invalid',
            headerProvider: () async => {},
            httpClient: MockClient((r) async =>
                throw StateError('unexpected synthetic DAO request'))));
  @override
  Future<void> sendCode(
      {required String channel,
      required String identifier,
      required String purpose}) {
    sends++;
    return sendResult ?? Future.value();
  }

  @override
  Future<LoginResult> register(
      {required String channel,
      required String identifier,
      required String code,
      String? password}) async {
    registerCodes.add(code);
    throw StateError('synthetic register rejected');
  }

  @override
  Future<LoginResult> loginByCode(
      {required String channel,
      required String identifier,
      required String code}) async {
    loginCodes.add(code);
    throw StateError('synthetic login rejected');
  }
}

class _Navigation extends NavigatorObserver {
  int pushes = 0, pops = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

http.Response _ok() => http.Response(jsonEncode({'code': 0, 'data': {}}), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<GlobalKey<NavigatorState>> _mount(
    WidgetTester tester, Widget page, _Navigation observer) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      navigatorObservers: [observer],
      home: const Scaffold(body: Text('synthetic root'))));
  unawaited(
      key.currentState!.push(MaterialPageRoute<void>(builder: (_) => page)));
  await tester.pumpAndSettle();
  if (page is LoginPage) {
    await tester.tap(find.text('验证码登录'));
    await tester.pumpAndSettle();
  }
  await tester.enterText(
      find.byType(TextField).first, 'person@synthetic.invalid');
  return key;
}

Finder _codes() => find.descendant(
    of: find.byType(VerificationCodeInput), matching: find.byType(TextField));
Future<void> _fillCode(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.enterText(_codes().at(i), '${i + 1}');
  }
  await tester.pump();
}

Future<void> _press(WidgetTester tester, String label) async {
  final button = find.widgetWithText(ElevatedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await _pump(tester);
}

Future<void> _agree(WidgetTester tester) async {
  final agreement = find.textContaining('已阅读并同意', findRichText: true);
  await tester.ensureVisible(agreement);
  await tester.tap(agreement);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryTokenStorage storage;
  late _FakeDao dao;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  final responseGates = <Completer<http.Response>>[];
  late MockClient client;
  late String oldHost;
  late bool oldHttps;
  final oldFatal = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'auth.synthetic.invalid';
    BackendConfig.useHttps = true;
    client = MockClient((r) {
      expectSync(r.url.host, 'auth.synthetic.invalid');
      expectSync(r.method, 'POST');
      expectSync(['/uapi/auth/code/send', '/uapi/auth/reset-password'],
          contains(r.url.path));
      requests.add(r);
      return handler(r);
    });
    await http.runWithClient(() async => AuthDaoBridge.client, () => client);
  });
  tearDownAll(() {
    WidgetController.hitTestWarningShouldBeFatal = oldFatal;
    client.close();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
  });
  setUp(() {
    LoginDao.resetHooksForTest();
    storage = MemoryTokenStorage();
    dao = _FakeDao();
    requests.clear();
    responseGates.clear();
    handler = (r) async => _ok();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'auth.synthetic.invalid',
        useHttps: true,
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: storage,
        onLogoutNavigate: () {}));
  });
  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  Widget page(String kind) => switch (kind) {
        'register' => RegisterPage(
            showAgreement: false,
            authDependencies: LoginAuthDependencies(authDao: dao)),
        'login' =>
          LoginPage(authDependencies: LoginAuthDependencies(authDao: dao)),
        _ => const ForgotPasswordPage(),
      };
  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final g in responseGates) {
      if (!g.isCompleted) g.complete(_ok());
    }
    await _pump(tester);
  }

  for (final kind in ['register', 'forgot', 'login']) {
    testWidgets(
        '$kind delete after six digits blocks old code; refill permits only an explicit complete action',
        (tester) async {
      try {
        await _mount(tester, page(kind), _Navigation());
        if (kind == 'register') {
          await tester.enterText(
              find.byType(TextField).last, 'SyntheticPassword123');
        }
        if (kind == 'login') await _agree(tester);
        await _fillCode(tester);
        await tester.enterText(_codes().last, '');
        await _press(
            tester,
            kind == 'register'
                ? '创建账号'
                : kind == 'login'
                    ? '登录'
                    : '下一步');
        expect(dao.registerCodes, isEmpty);
        expect(dao.loginCodes, isEmpty);
        expect(requests, isEmpty);
        expect(find.byType(VerificationCodeInput), findsOneWidget);
        await tester.enterText(_codes().last, '6');
        await _press(
            tester,
            kind == 'register'
                ? '创建账号'
                : kind == 'login'
                    ? '登录'
                    : '下一步');
        if (kind == 'register') expect(dao.registerCodes, ['123456']);
        if (kind == 'login') expect(dao.loginCodes, ['123456']);
        if (kind == 'forgot') {
          expect(find.byType(VerificationCodeInput), findsNothing);
          expect(find.widgetWithText(ElevatedButton, '确认重置'), findsOneWidget);
          expect(requests, isEmpty);
        }
        expect(storage.readProfileSync(), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await clean(tester);
      }
    });
    testWidgets(
        '$kind send failure after pop cannot setState, navigate or persist',
        (tester) async {
      final send = Completer<void>();
      final httpSend = Completer<http.Response>();
      responseGates.add(httpSend);
      dao.sendResult = send.future;
      handler = (r) => httpSend.future;
      final observer = _Navigation();
      try {
        final key = await _mount(tester, page(kind), observer);
        final resend = find.text('重新发送');
        await tester.ensureVisible(resend);
        await tester.tap(resend);
        await _pump(tester);
        expect(kind == 'forgot' ? requests.length : dao.sends, 1);
        key.currentState!.pop();
        await tester.pumpAndSettle();
        final pushes = observer.pushes, pops = observer.pops;
        if (kind == 'forgot') {
          httpSend.completeError(StateError('synthetic send failure'));
        } else {
          send.completeError(StateError('synthetic send failure'));
        }
        await _pump(tester);
        expect(tester.takeException(), isNull);
        expect(observer.pushes, pushes);
        expect(observer.pops, pops);
        expect(storage.readProfileSync(), isNull);
      } finally {
        if (!send.isCompleted) send.complete();
        await clean(tester);
      }
    });
    testWidgets(
        '$kind ordinary send success retains countdown and never authenticates',
        (tester) async {
      try {
        await _mount(tester, page(kind), _Navigation());
        final resend = find.text('重新发送');
        await tester.ensureVisible(resend);
        await tester.tap(resend);
        await _pump(tester);
        expect(kind == 'forgot' ? requests.length : dao.sends, 1);
        expect(find.text('60s'), findsOneWidget);
        expect(dao.registerCodes, isEmpty);
        expect(dao.loginCodes, isEmpty);
        expect(storage.readProfileSync(), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await clean(tester);
      }
    });
  }
  for (final failAfterPop in [true, false]) {
    testWidgets(
        'forgot reset ${failAfterPop ? "failure after pop is isolated" : "success retains done-and-return path"}',
        (tester) async {
      final gate = Completer<http.Response>();
      responseGates.add(gate);
      handler = (r) => gate.future;
      final observer = _Navigation();
      try {
        final key = await _mount(tester, page('forgot'), observer);
        await _fillCode(tester);
        await _press(tester, '下一步');
        await tester.enterText(
            find.byType(TextField).first, 'SyntheticPassword123');
        await tester.enterText(
            find.byType(TextField).last, 'SyntheticPassword123');
        await _press(tester, '确认重置');
        expect(requests.length, 1);
        expect(jsonDecode(requests.single.body)['code'], '123456');
        if (failAfterPop) {
          key.currentState!.pop();
          await tester.pumpAndSettle();
          final pushes = observer.pushes, pops = observer.pops;
          gate.completeError(StateError('synthetic reset failure'));
          await _pump(tester);
          expect(observer.pushes, pushes);
          expect(observer.pops, pops);
        } else {
          gate.complete(_ok());
          await _pump(tester);
          expect(find.text('密码已重置'), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();
          expect(find.text('synthetic root'), findsOneWidget);
        }
        expect(storage.readProfileSync(), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await clean(tester);
      }
    });
  }
}
