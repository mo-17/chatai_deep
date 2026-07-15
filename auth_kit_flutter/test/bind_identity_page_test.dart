import 'dart:async';
import 'dart:convert';

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    '绑定响应在页面销毁后到达时不回调成功且不触发 setState',
    (tester) async {
      final bindRequestStarted = Completer<void>();
      final bindResponse = Completer<http.Response>();
      var successCount = 0;

      final client = MockClient((request) {
        switch (request.url.path) {
          case '/uapi/auth/code/send':
            return Future.value(http.Response(
              jsonEncode({'code': 0, 'data': null}),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            ));
          case '/uapi/auth/apple/bind-and-login':
            bindRequestStarted.complete();
            return bindResponse.future;
          default:
            throw StateError('unexpected auth request: ${request.url.path}');
        }
      });
      addTearDown(client.close);
      final authDao = AuthDao(AuthApiClient(
        baseUrl: 'http://localhost:3000',
        headerProvider: () async => <String, String>{},
        httpClient: client,
      ));

      await tester.pumpWidget(MaterialApp(
        home: BindIdentityPage(
          authDao: authDao,
          bindTicket: 'bind-ticket',
          provider: 'apple',
          preferredChannel: 'email',
          onSuccess: (_) => successCount++,
        ),
      ));

      await tester.enterText(find.byType(TextField).first, 'alice@example.com');
      final sendCode = find.widgetWithText(ElevatedButton, '发送验证码');
      await tester.ensureVisible(sendCode);
      await tester.tap(sendCode);
      await tester.pumpAndSettle();

      final codeFields = find.descendant(
        of: find.byType(VerificationCodeInput),
        matching: find.byType(TextField),
      );
      expect(codeFields, findsNWidgets(6));
      for (var index = 0; index < 6; index++) {
        await tester.enterText(codeFields.at(index), '${index + 1}');
      }
      await tester.pump();
      await bindRequestStarted.future;

      await tester.pumpWidget(const SizedBox.shrink());
      bindResponse.complete(http.Response(
        jsonEncode({
          'code': 0,
          'data': 'bound-token',
          'extra': {
            'id': 7,
            'userName': 'alice',
            'email': 'alice@example.com',
            'phone': null,
            'role': 'user',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ));
      await tester.pump();

      expect(successCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '绑定请求进行中重复完成验证码只提交一次',
    (tester) async {
      final bindRequestStarted = Completer<void>();
      final bindResponse = Completer<http.Response>();
      var bindRequestCount = 0;
      var successCount = 0;

      final client = MockClient((request) {
        switch (request.url.path) {
          case '/uapi/auth/code/send':
            return Future.value(http.Response(
              jsonEncode({'code': 0, 'data': null}),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            ));
          case '/uapi/auth/apple/bind-and-login':
            bindRequestCount++;
            if (!bindRequestStarted.isCompleted) {
              bindRequestStarted.complete();
            }
            return bindResponse.future;
          default:
            throw StateError('unexpected auth request: ${request.url.path}');
        }
      });
      addTearDown(client.close);
      final authDao = AuthDao(AuthApiClient(
        baseUrl: 'http://localhost:3000',
        headerProvider: () async => <String, String>{},
        httpClient: client,
      ));

      await tester.pumpWidget(MaterialApp(
        home: BindIdentityPage(
          authDao: authDao,
          bindTicket: 'bind-ticket',
          provider: 'apple',
          preferredChannel: 'email',
          onSuccess: (_) => successCount++,
        ),
      ));

      await tester.enterText(find.byType(TextField).first, 'alice@example.com');
      final sendCode = find.widgetWithText(ElevatedButton, '发送验证码');
      await tester.ensureVisible(sendCode);
      await tester.tap(sendCode);
      await tester.pumpAndSettle();

      final codeFields = find.descendant(
        of: find.byType(VerificationCodeInput),
        matching: find.byType(TextField),
      );
      expect(codeFields, findsNWidgets(6));
      for (var index = 0; index < 6; index++) {
        await tester.enterText(codeFields.at(index), '${index + 1}');
      }
      await tester.pump();
      await bindRequestStarted.future;

      await tester.enterText(codeFields.last, '9');
      await tester.pump();
      bindResponse.complete(http.Response(
        jsonEncode({
          'code': 0,
          'data': 'bound-token',
          'extra': {
            'id': 7,
            'userName': 'alice',
            'email': 'alice@example.com',
            'phone': null,
            'role': 'user',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ));
      await tester.pumpAndSettle();

      expect(bindRequestCount, 1);
      expect(successCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
