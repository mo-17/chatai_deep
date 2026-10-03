import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/dao/ai_provider_api.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_provider_detail_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/widget/ai_provider/api_key_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    AISettingsDao.configureSecretStore(_MemorySecureStore());
  });

  tearDown(AISettingsDao.resetSecureStateForTest);

  Future<AISettingsProvider> pumpPage(
    WidgetTester tester,
    MockClient client, {
    AiProvider? provider,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.close);

    final item = provider ?? _deepSeekProvider();
    final settings = AISettings.defaults()
      ..providers = [item]
      ..activeProviderId = item.id;
    // 建立真实的保存基线，避免把测试 fixture 的 Key 当作页面编辑。
    await HiCache.getInstance().setString(
      AISettingsDao.keyFor('guest'),
      jsonEncode(settings.toJson()),
    );
    await AISettingsDao.prepareAccount('guest');
    final store = AISettingsProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: store,
        child: MaterialApp(
          home: AiProviderDetailPage(
            providerId: item.id,
            api: AiProviderApi(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> tapLabel(WidgetTester tester, String label) async {
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    } else {
      await tester.ensureVisible(finder.last);
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder.last);
    await tester.pump();
  }

  Finder keyField() => find.descendant(
        of: find.byType(ApiKeyField),
        matching: find.byType(TextField),
      );

  Future<void> revealKey(WidgetTester tester) async {
    if (keyField().evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        keyField(),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
    } else {
      await tester.ensureVisible(keyField());
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('获取模型仅添加勾选的新模型，保留当前模型和自定义配置', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _modelsResponse([
        'deepseek-v4-pro',
        'remote-new-a',
        'remote-new-b',
      ]);
    });
    final store = await pumpPage(tester, client);
    final before = store.settings.activeProvider.toJson();

    await tapLabel(tester, '获取模型');
    await tester.pumpAndSettle();

    expect(find.text('获取到的模型'), findsOneWidget);
    expect(find.textContaining('已添加'), findsOneWidget);
    expect(find.text('添加 2 个模型'), findsOneWidget);
    expect(store.settings.activeProvider.toJson(), before);

    await tester
        .tap(find.widgetWithText(CheckboxListTile, 'remote-new-b').first);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '添加 1 个模型'));
    await tester.pumpAndSettle();

    final current = store.settings.activeProvider;
    expect(current.selectedModelId, 'custom-kept');
    expect(
        current.models.map((model) => model.id),
        containsAll([
          'deepseek-v4-pro',
          'custom-kept',
          'remote-new-a',
        ]));
    expect(current.models.map((model) => model.id),
        isNot(contains('remote-new-b')));
    final original =
        current.models.firstWhere((m) => m.id == 'deepseek-v4-pro');
    expect(original.name, '我的 Pro 名称');
    // 模型清单变化沿用既有健康状态失效规则，不能把发现模型当作测试成功。
    expect(original.lastTestStatus, 'unknown');
    expect(original.lastTestAt, isNull);
    final added = current.models.firstWhere((m) => m.id == 'remote-new-a');
    expect(added.lastTestStatus, 'unknown');
    expect(added.lastTestAt, isNull);
    expect(requests.map((request) => request.url.path), ['/models']);
    expect(requests.single.method, 'GET');
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭获取到的模型面板不会添加模型或切换当前模型', (tester) async {
    final client = MockClient((_) async => _modelsResponse(['remote-cancel']));
    final store = await pumpPage(tester, client);
    final before = store.settings.activeProvider.toJson();

    await tapLabel(tester, '获取模型');
    await tester.pumpAndSettle();
    expect(find.text('remote-cancel'), findsWidgets);
    Navigator.of(tester.element(find.text('获取到的模型'))).pop();
    await tester.pumpAndSettle();

    expect(store.settings.activeProvider.toJson(), before);
    expect(find.text('获取到的模型'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询余额按币种展示精确金额，并在 320px 下保持正常布局', (tester) async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/user/balance');
      return _balanceResponse();
    });
    await pumpPage(tester, client, size: const Size(320, 568));

    await tapLabel(tester, '查询余额');
    await tester.pumpAndSettle();

    expect(find.text('可调用'), findsOneWidget);
    expect(find.text('CNY · 总余额 99.123456'), findsOneWidget);
    expect(find.text('USD · 总余额 1.000001'), findsOneWidget);
    expect(find.text('赠金 19.123456 · 充值余额 80.000000'), findsOneWidget);
    expect(find.text('赠金 0.000001 · 充值余额 1.000000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义中转地址保留获取模型，隐藏官方 DeepSeek 余额查询', (tester) async {
    final client = MockClient((_) async => _modelsResponse(['gateway-model']));
    await pumpPage(
      tester,
      client,
      provider: _deepSeekProvider()
        ..apiHost = 'https://example.invalid/proxy/v1',
    );

    expect(find.text('获取模型'), findsOneWidget);
    expect(find.text('查询余额'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修改 Key 清除旧余额，丢弃尚未完成的余额请求，并可重新查询', (tester) async {
    final secondResponse = Completer<http.Response>();
    final keys = <String?>[];
    final client = MockClient((request) async {
      keys.add(request.headers['Authorization']);
      if (keys.length == 2) return secondResponse.future;
      if (keys.length == 3) {
        return _balanceResponse(total: '7.654321', available: false);
      }
      return _balanceResponse();
    });
    await pumpPage(tester, client);

    await tapLabel(tester, '查询余额');
    await tester.pumpAndSettle();
    expect(find.text('CNY · 总余额 99.123456'), findsOneWidget);

    await tapLabel(tester, '查询余额');
    await tester.pump(const Duration(milliseconds: 50));
    expect(keys.length, 2);
    await revealKey(tester);
    await tester.enterText(keyField(), 'synthetic-updated-key');
    await tester.pump();
    expect(find.textContaining('99.123456'), findsNothing);

    secondResponse.complete(_balanceResponse(total: '123.987654'));
    await tester.pumpAndSettle();
    expect(find.textContaining('123.987654'), findsNothing);
    expect(find.textContaining('99.123456'), findsNothing);

    await tapLabel(tester, '查询余额');
    await tester.pumpAndSettle();
    expect(find.text('CNY · 总余额 7.654321'), findsOneWidget);
    expect(find.text('不可调用：账户余额不足'), findsOneWidget);
    expect(keys.last, 'Bearer synthetic-updated-key');
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型请求期间修改 Key 时不会打开旧配置的模型面板', (tester) async {
    final response = Completer<http.Response>();
    var started = false;
    final client = MockClient((_) async {
      started = true;
      return response.future;
    });
    final store = await pumpPage(tester, client);
    final ids = store.settings.activeProvider.models.map((m) => m.id).toList();

    await tapLabel(tester, '获取模型');
    await tester.pump(const Duration(milliseconds: 50));
    expect(started, isTrue);
    await revealKey(tester);
    await tester.enterText(keyField(), 'synthetic-new-model-key');
    response.complete(_modelsResponse(['stale-model']));
    await tester.pumpAndSettle();

    expect(find.text('获取到的模型'), findsNothing);
    expect(find.text('stale-model'), findsNothing);
    expect(store.settings.activeProvider.models.map((m) => m.id), ids);
    expect(tester.takeException(), isNull);
  });

  testWidgets('余额请求失败不显示服务端敏感正文，随后可以重试', (tester) async {
    var requests = 0;
    final client = MockClient((_) async {
      if (++requests == 1) {
        return http.Response('synthetic-server-secret-DO-NOT-DISPLAY', 401);
      }
      return _balanceResponse(total: '8.111111');
    });
    await pumpPage(tester, client);

    await tapLabel(tester, '查询余额');
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic-server-secret'), findsNothing);
    expect(find.text('可调用'), findsNothing);

    await tapLabel(tester, '查询余额');
    await tester.pumpAndSettle();
    expect(find.text('CNY · 总余额 8.111111'), findsOneWidget);
    expect(requests, 2);
    expect(tester.takeException(), isNull);
  });
}

AiProvider _deepSeekProvider() => AiProvider(
      id: 'deepseek',
      type: 'openai',
      name: 'DeepSeek',
      apiKey: 'synthetic-provider-key',
      apiHost: 'https://api.deepseek.com/v1',
      selectedModelId: 'custom-kept',
      enabled: true,
      isSystem: true,
      models: [
        AiModel(
          id: 'deepseek-v4-pro',
          name: '我的 Pro 名称',
          lastTestAt: 1234,
          lastTestStatus: 'success',
        ),
        AiModel(id: 'custom-kept', name: '手动添加的模型'),
      ],
    );

http.Response _modelsResponse(List<String> ids) => http.Response(
      jsonEncode({
        'object': 'list',
        'data': ids.map((id) => {'id': id, 'object': 'model'}).toList(),
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _balanceResponse({
  String total = '99.123456',
  bool available = true,
}) =>
    http.Response(
      jsonEncode({
        'is_available': available,
        'balance_infos': [
          {
            'currency': 'CNY',
            'total_balance': total,
            'granted_balance': '19.123456',
            'topped_up_balance': '80.000000',
          },
          {
            'currency': 'USD',
            'total_balance': '1.000001',
            'granted_balance': '0.000001',
            'topped_up_balance': '1.000000',
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
