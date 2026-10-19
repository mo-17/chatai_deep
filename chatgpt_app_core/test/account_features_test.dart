import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:chatgpt_app_core/account/account_api.dart';
import 'package:chatgpt_app_core/pages/account_usage_page.dart';
import 'package:chatgpt_app_core/pages/feedback_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  setUp(() {
    storage = _Storage();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'example.com',
        useHttps: true,
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: storage,
        onLogoutNavigate: () {}));
  });
  tearDown(LoginSdkConfig.reset);
  test(
      'request preserves query and rejects response after token/account switch',
      () async {
    final api = AccountApi(client: MockClient((request) async {
      expect(request.url.path, '/uapi/feedback');
      expect(request.url.queryParameters['page'], '2');
      storage.profile = {
        'boardingPass': 'token-b',
        'userName': 'b',
        'accountHash': 'b'
      };
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'private': 'a'}
          }),
          200);
    }));
    await expectLater(api.request('/uapi/feedback?page=2'), throwsStateError);
  });
  test('old page cannot submit content into a newly logged-in account',
      () async {
    var requests = 0;
    final api = AccountApi(client: MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    }));
    storage.profile = {
      'boardingPass': 'token-b',
      'userName': 'b',
      'accountHash': 'b'
    };
    await expectLater(
        api.request('/uapi/feedback', body: {'content': 'old account'}),
        throwsStateError);
    expect(requests, 0);
  });
  testWidgets('shows remaining 10k Token quota and clear reset rule',
      (tester) async {
    final api = AccountApi(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'trialEnabled': false,
                'limitsEnabled': true,
                'dailyTokens': 10000,
                'remainingTokens': 9000,
                'usedRequests': 1,
                'maxConcurrent': 1,
                'countingRule': '每日 UTC 0 点重置',
                'models': []
              }
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    expect((await api.request('/uapi/account/usage'))['remainingTokens'], 9000);
    await tester.pumpWidget(MaterialApp(home: AccountUsagePage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('今日剩余 9000 / 10000 Token'), findsOneWidget);
    expect(find.text('每日 UTC 0 点重置'), findsOneWidget);
    expect(find.text('开始官方试用'), findsNothing);
  });
  testWidgets(
      'feedback diagnostics default off and only permitted metadata is posted',
      (tester) async {
    Map? submitted;
    final api = AccountApi(client: MockClient((request) async {
      if (request.method == 'POST') submitted = jsonDecode(request.body) as Map;
      return http.Response(
          jsonEncode({
            'code': 0,
            'data':
                request.method == 'POST' ? {'id': 1} : {'list': [], 'total': 0}
          }),
          200);
    }));
    await tester.pumpWidget(MaterialApp(home: FeedbackPage(api: api)));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false);
    await tester.enterText(find.byType(TextField), '无法重新连接后端服务');
    await tester.tap(find.text('提交反馈'));
    await tester.pumpAndSettle();
    expect(submitted?['diagnostics'], isEmpty);
    expect(submitted?['content'], '无法重新连接后端服务');
    expect(submitted?.keys.toSet(),
        {'requestId', 'content', 'category', 'diagnostics'});
    expect(find.text('已提交，可在此查看处理进展和回复'), findsOneWidget);
  });
  for (final versionAvailable in [false, true]) {
    testWidgets('反馈诊断尊重同意且版本可用=$versionAvailable 不阻断提交', (tester) async {
      const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (_) async {
        throw PlatformException(code: 'unavailable');
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      if (versionAvailable) {
        PackageInfo.setMockInitialValues(
            appName: '艾普',
            packageName: 'com.hzb.flutter_ai',
            version: '1.2.3',
            buildNumber: '123',
            buildSignature: '');
      }
      Map? submitted;
      final api = AccountApi(client: MockClient((request) async {
        if (request.method == 'POST') {
          submitted = jsonDecode(request.body) as Map;
        }
        return http.Response(
            jsonEncode({
              'code': 0,
              'data': request.method == 'POST'
                  ? {'id': 1}
                  : {'list': [], 'total': 0}
            }),
            200);
      }));
      await tester.pumpWidget(MaterialApp(home: FeedbackPage(api: api)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.enterText(find.byType(TextField), '鸿蒙平台测试反馈内容');
      await tester.tap(find.text('提交反馈'));
      await tester.pumpAndSettle();
      expect(submitted, isNotNull);
      final diagnostics = submitted!['diagnostics'] as Map;
      expect(
          diagnostics.keys.toSet(),
          versionAvailable
              ? {'platform', 'locale', 'appVersion'}
              : {'platform', 'locale'});
      if (versionAvailable) expect(diagnostics['appVersion'], '1.2.3+123');
      expect(find.text('已提交，可在此查看处理进展和回复'), findsOneWidget);
    });
  }

  testWidgets(
      'unverified email cannot start trial and examples never send requests',
      (tester) async {
    var requests = 0;
    final api = AccountApi(client: MockClient((_) async {
      requests++;
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'trialEnabled': true,
              'trialEligible': false,
              'trialModel': 'synthetic-flash',
              'limitsEnabled': true,
              'dailyTokens': 10000,
              'remainingTokens': 10000,
              'remainingRequests': 100,
              'usedRequests': 0,
              'maxConcurrent': 1,
              'countingRule': 'UTC',
              'models': [],
            }
          }),
          200);
    }));
    await tester.pumpWidget(MaterialApp(home: AccountUsagePage(api: api)));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, '开始官方试用');
    await tester.ensureVisible(button);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(find.textContaining('请先使用邮箱验证码登录'), findsOneWidget);
    await tester.ensureVisible(find.text('写作润色'));
    await tester.tap(find.text('写作润色'));
    await tester.pumpAndSettle();
    expect(requests, 1);
  });
  testWidgets(
      'verified user with exhausted request quota sees reset time and disabled action',
      (tester) async {
    final api = AccountApi(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'trialEnabled': true,
                'trialEligible': true,
                'limitsEnabled': true,
                'dailyTokens': 10000,
                'remainingTokens': 1000,
                'remainingRequests': 0,
                'usedRequests': 100,
                'maxConcurrent': 1,
                'models': [],
              }
            }),
            200)));
    await tester.pumpWidget(MaterialApp(home: AccountUsagePage(api: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('北京时间 08:00'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, '开始官方试用');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });
}

class _Storage implements TokenStorage {
  Map<String, dynamic>? profile = {
    'boardingPass': 'token-a',
    'userName': 'a',
    'accountHash': 'a'
  };
  @override
  Future<void> clear() async {
    profile = null;
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => profile;
  @override
  Map<String, dynamic>? readProfileSync() => profile;
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => profile?['boardingPass'];
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    profile = {'boardingPass': token, 'userName': userName, ...extras};
  }
}
