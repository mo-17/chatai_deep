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

class _Send {
  final String channel, identifier, purpose;
  final result = Completer<void>();
  _Send(this.channel, this.identifier, this.purpose);
}

class _PendingDao extends AuthDao {
  final sends = <_Send>[];
  _PendingDao()
      : super(AuthApiClient(
            baseUrl: 'https://auth.synthetic.invalid',
            headerProvider: () async => {},
            httpClient: MockClient((r) async =>
                throw StateError('unexpected authentication request'))));

  @override
  Future<void> sendCode(
      {required String channel,
      required String identifier,
      required String purpose}) {
    final send = _Send(channel, identifier, purpose);
    sends.add(send);
    return send.result.future;
  }
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Finder _input() => find.byType(VerificationCodeInput);
Finder _sendButton() =>
    find.descendant(of: _input(), matching: find.byType(TextButton));
Finder _digits() =>
    find.descendant(of: _input(), matching: find.byType(TextField));

Future<void> _send(WidgetTester tester) async {
  await tester.ensureVisible(_sendButton());
  await tester.pumpAndSettle();
  await tester.tap(_sendButton());
  await _pump(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PendingDao dao;
  late MemoryTokenStorage storage;
  late MockClient client;
  late String oldHost;
  late bool oldHttps;
  var bridgeRequests = 0;
  final oldFatal = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'auth.synthetic.invalid';
    BackendConfig.useHttps = true;
    client = MockClient((r) async {
      expectSync(r.method, 'POST');
      expectSync(r.url.host, 'auth.synthetic.invalid');
      expectSync(r.url.path, '/uapi/auth/code/send');
      bridgeRequests++;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      await dao.sendCode(
          channel: body['channel'] as String,
          identifier: body['identifier'] as String,
          purpose: body['purpose'] as String);
      return http.Response(jsonEncode({'code': 0, 'data': {}}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
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
    dao = _PendingDao();
    storage = MemoryTokenStorage();
    bridgeRequests = 0;
    LoginDao.resetHooksForTest();
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

  Future<void> mount(WidgetTester tester, String kind,
      {bool fill = true}) async {
    await tester.pumpWidget(MaterialApp(home: page(kind)));
    await tester.pumpAndSettle();
    if (kind == 'login') {
      await tester.tap(find.text('验证码登录'));
      await tester.pumpAndSettle();
    }
    if (fill) {
      await tester.enterText(
          find.byType(TextField).first, 'person@synthetic.invalid');
      await tester.pump();
    }
  }

  Future<void> clean(WidgetTester tester, String kind) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final send in dao.sends) {
      if (!send.result.isCompleted) send.result.complete();
    }
    await _pump(tester);
    expect(storage.readProfileSync(), isNull);
    expect(bridgeRequests, kind == 'forgot' ? dao.sends.length : 0);
    expect(tester.takeException(), isNull);
  }

  testWidgets('legacy void resend callback remains compatible', (tester) async {
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: VerificationCodeInput(onSendCode: () => sends++))));
    expect(find.text('重新发送'), findsOneWidget);
    await _send(tester);
    expect(sends, 1);
    expect(find.text('60s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final kind in ['register', 'forgot', 'login']) {
    testWidgets('$kind first send waits for success; resend remains explicit',
        (tester) async {
      try {
        await mount(tester, kind);
        expect(find.text('发送验证码'), findsOneWidget);
        expect(find.text('重新发送'), findsNothing);
        await _send(tester);
        expect(dao.sends.length, 1);
        expect(find.text('发送中'), findsOneWidget);
        expect(tester.widget<TextButton>(_sendButton()).onPressed, isNull);
        expect(find.text('60s'), findsNothing);
        await tester.tap(_sendButton());
        await _pump(tester);
        expect(dao.sends.length, 1);
        expect(dao.sends.single.purpose,
            kind == 'forgot' ? 'reset_password' : kind);
        dao.sends.single.result.complete();
        await _pump(tester);
        expect(find.text('60s'), findsOneWidget);
        await tester.pump(const Duration(seconds: 60));
        expect(find.text('重新发送'), findsOneWidget);
        expect(dao.sends.length, 1);
        await _send(tester);
        dao.sends.last.result
            .completeError(StateError('synthetic resend denied'));
        await _pump(tester);
        expect(find.text('重新发送'), findsOneWidget);
        expect(find.text('60s'), findsNothing);
        expect(find.textContaining('synthetic resend denied'), findsOneWidget);
      } finally {
        await clean(tester, kind);
      }
    });

    testWidgets(
        '$kind invalid input and failed first send keep first-send state',
        (tester) async {
      try {
        await mount(tester, kind, fill: false);
        await _send(tester);
        expect(dao.sends, isEmpty);
        expect(find.text('60s'), findsNothing);
        expect(find.text('发送验证码'), findsOneWidget);
        await tester.enterText(
            find.byType(TextField).first, 'person@synthetic.invalid');
        await tester.pump();
        await _send(tester);
        dao.sends.last.result
            .completeError(StateError('synthetic first denied'));
        await _pump(tester);
        expect(find.text('发送验证码'), findsOneWidget);
        expect(find.text('60s'), findsNothing);
        expect(find.textContaining('synthetic first denied'), findsOneWidget);
        expect(tester.widget<TextButton>(_sendButton()).onPressed, isNotNull);
        await _send(tester);
        expect(dao.sends.length, 2);
        dao.sends.last.result.complete();
        await _pump(tester);
        expect(find.text('60s'), findsOneWidget);
      } finally {
        await clean(tester, kind);
      }
    });

    testWidgets('$kind changed mailbox clears code and isolates late success',
        (tester) async {
      try {
        await mount(tester, kind);
        await tester.enterText(_digits(), '123456');
        await _send(tester);
        await tester.enterText(
            find.byType(TextField).first, 'other@synthetic.invalid');
        await tester.pump();
        expect(find.text('发送验证码'), findsOneWidget);
        expect(find.text('60s'), findsNothing);
        expect(
            tester
                .widgetList<TextField>(_digits())
                .every((f) => f.controller!.text.isEmpty),
            isTrue);
        dao.sends.first.result.complete();
        await _pump(tester);
        expect(find.text('发送验证码'), findsOneWidget);
        expect(find.text('60s'), findsNothing);
        await _send(tester);
        expect(dao.sends.last.identifier, 'other@synthetic.invalid');
        dao.sends.last.result.complete();
        await _pump(tester);
        expect(find.text('60s'), findsOneWidget);
        // 已成功的倒计时也属于原邮箱，换邮箱必须重新首次发送。
        await tester.enterText(
            find.byType(TextField).first, 'third@synthetic.invalid');
        await tester.pump();
        expect(find.text('发送验证码'), findsOneWidget);
        expect(find.text('60s'), findsNothing);
      } finally {
        await clean(tester, kind);
      }
    });

    testWidgets(
        '$kind same-frame mailbox ABA isolates old failure from new send',
        (tester) async {
      try {
        await mount(tester, kind);
        await _send(tester);
        final controller =
            tester.widget<TextField>(find.byType(TextField).first).controller!;
        controller.text = 'other@synthetic.invalid';
        controller.text = 'person@synthetic.invalid';
        await tester.pump();
        await _send(tester);
        expect(dao.sends.length, 2);
        dao.sends.first.result
            .completeError(StateError('synthetic old failure'));
        await _pump(tester);
        expect(find.textContaining('synthetic old failure'), findsNothing);
        expect(find.text('发送中'), findsOneWidget);
        expect(tester.widget<TextButton>(_sendButton()).onPressed, isNull);
        dao.sends.last.result.complete();
        await _pump(tester);
        expect(find.text('60s'), findsOneWidget);
      } finally {
        await clean(tester, kind);
      }
    });

    testWidgets('$kind channel and dial-code changes isolate prior sends',
        (tester) async {
      try {
        await mount(tester, kind);
        await _send(tester);
        await tester.ensureVisible(find.text('手机号'));
        await tester.tap(find.text('手机号'));
        await tester.pump();
        dao.sends.first.result.complete();
        await _pump(tester);
        expect(find.text('发送验证码'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, '1234567890');
        await tester.pump();
        await _send(tester);
        expect(dao.sends.last.channel, 'sms');
        final picker =
            tester.widget<CountryCodePicker>(find.byType(CountryCodePicker));
        final country = supportedCountries
            .firstWhere((c) => c.dialCode != picker.selected.dialCode);
        picker.onChanged(country);
        await tester.pump();
        expect(find.text('发送验证码'), findsOneWidget);
        dao.sends.last.result
            .completeError(StateError('synthetic old country'));
        await _pump(tester);
        expect(find.textContaining('synthetic old country'), findsNothing);
        await _send(tester);
        expect(dao.sends.last.identifier, '${country.dialCode} 1234567890');
        dao.sends.last.result.complete();
        await _pump(tester);
        expect(find.text('60s'), findsOneWidget);
      } finally {
        await clean(tester, kind);
      }
    });
  }
}
