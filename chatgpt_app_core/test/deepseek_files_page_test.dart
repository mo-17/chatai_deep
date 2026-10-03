import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/deepseek_file_preview_store.dart';
import 'package:chatgpt_app_core/dao/ai_provider_api.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/deepseek_files_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    AISettingsDao.configureSecretStore(_MemorySecureStore());
  });

  tearDown(() {
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
  });

  Future<AISettingsProvider> pumpPage(
    WidgetTester tester,
    MockClient client, {
    AiProvider? provider,
    Size size = const Size(390, 844),
    bool settle = true,
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
          home: DeepSeekFilesPage(
            providerId: item.id,
            api: AiProviderApi(client: client),
            previewStore: _EmptyPreviewStore(),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return store;
  }

  Future<void> tapLoadMore(WidgetTester tester) async {
    final button = find.text('加载更多');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> openDelete(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('delete_file_$id')));
    await tester.pumpAndSettle();
    expect(find.text('删除云端文件'), findsOneWidget);
  }

  Future<void> confirmDelete(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('删除'),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('打开页面加载 user_data 文件，分页去重并沿用服务端 cursor', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (requests.length == 1) {
        return _listResponse([
          _file('file-api-a', filename: 'first.png'),
          _file('file-api-b', filename: 'second.png'),
        ], hasMore: true);
      }
      return _listResponse([
        _file('file-api-b', filename: 'second.png'),
        _file('file-api-c', filename: 'third.png'),
      ]);
    });
    await pumpPage(tester, client);

    expect(find.text('first.png'), findsOneWidget);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/files');
    expect(requests.single.url.queryParameters, {
      'limit': '25',
      'order': 'desc',
      'purpose': 'user_data',
    });
    await tapLoadMore(tester);

    expect(requests.last.url.queryParameters['after'], 'file-api-b');
    expect(find.byKey(const ValueKey('cloud_file_file-api-b')), findsOneWidget);
    expect(find.text('third.png'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页或刷新失败保留已加载文件及 cursor，重试不会跳过下一页', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      switch (requests.length) {
        case 1:
          return _listResponse([_file('file-api-a')], hasMore: true);
        case 2:
        case 4:
          return http.Response('synthetic-list-body-secret', 503);
        case 3:
          return _listResponse([_file('file-api-b')], hasMore: true);
        default:
          return _listResponse([_file('file-api-c')]);
      }
    });
    await pumpPage(tester, client);

    await tapLoadMore(tester);
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsOneWidget);
    expect(find.textContaining('synthetic-list-body-secret'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests[1].url.queryParameters['after'], 'file-api-a');
    expect(requests[2].url.queryParameters['after'], 'file-api-a');

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud_file_file-api-b')), findsOneWidget);
    await tapLoadMore(tester);
    expect(requests.last.url.queryParameters['after'], 'file-api-b');
    expect(find.byKey(const ValueKey('cloud_file_file-api-c')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情重新获取服务端 metadata，并展示永久有效和实际有效期', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/files') {
        return _listResponse([
          _file('file-api-a', filename: 'list-old.png'),
          _file('file-api-b', filename: 'expiring.png'),
        ]);
      }
      if (request.url.path.endsWith('file-api-a')) {
        return _jsonResponse(_file(
          'file-api-a',
          filename: 'server-current.png',
          bytes: 4096,
        ));
      }
      return _jsonResponse(_file('file-api-b', expiresAt: 1800000000));
    });
    await pumpPage(tester, client);

    await tester.tap(find.byKey(const ValueKey('cloud_file_file-api-a')));
    await tester.pumpAndSettle();
    expect(find.text('文件详情'), findsOneWidget);
    expect(find.textContaining('server-current.png'), findsOneWidget);
    expect(find.textContaining('4096 字节'), findsOneWidget);
    expect(find.textContaining('file-api-a'), findsWidgets);
    expect(find.textContaining('永久有效'), findsOneWidget);
    Navigator.of(tester.element(find.text('文件详情'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cloud_file_file-api-b')));
    await tester.pumpAndSettle();
    expect(find.textContaining('永久有效'), findsNothing);
    expect(find.textContaining('2027'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消删除确认不发 DELETE 请求', (tester) async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      return _listResponse([_file('file-api-a', filename: 'keep.png')]);
    });
    await pumpPage(tester, client);
    await openDelete(tester, 'file-api-a');
    expect(find.textContaining('keep.png'), findsWidgets);
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('取消'),
    ));
    await tester.pumpAndSettle();

    expect(methods, ['GET']);
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认并获得成功 DELETE 回执后移除文件并刷新列表', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'DELETE') return _deletedResponse('file-api-a');
      return _listResponse(requests.length == 1 ? [_file('file-api-a')] : []);
    });
    await pumpPage(tester, client);
    await openDelete(tester, 'file-api-a');
    expect(requests.map((r) => r.method), ['GET']);
    await confirmDelete(tester);

    expect(requests.map((r) => r.method), ['GET', 'DELETE', 'GET']);
    expect(requests[1].url.path, '/files/file-api-a');
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除失败保留文件且不泄露响应正文，重新确认后可以重试', (tester) async {
    var deletes = 0;
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        if (++deletes == 1) {
          return http.Response('synthetic-delete-body-secret', 500);
        }
        return _deletedResponse('file-api-a');
      }
      return _listResponse(deletes < 2 ? [_file('file-api-a')] : []);
    });
    await pumpPage(tester, client);
    await openDelete(tester, 'file-api-a');
    await confirmDelete(tester);

    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsOneWidget);
    expect(find.textContaining('synthetic-delete-body-secret'), findsNothing);
    await openDelete(tester, 'file-api-a');
    await confirmDelete(tester);
    expect(deletes, 2);
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除分页尾项后刷新失败不会继续使用已删 cursor，刷新重试恢复分页', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'DELETE') return _deletedResponse('file-api-b');
      switch (requests.length) {
        case 1:
          return _listResponse([
            _file('file-api-a'),
            _file('file-api-b'),
          ], hasMore: true);
        case 3:
          return http.Response('synthetic-refresh-body-secret', 503);
        case 4:
          return _listResponse([
            _file('file-api-a'),
            _file('file-api-c'),
          ], hasMore: true);
        default:
          return _listResponse([_file('file-api-d')]);
      }
    });
    await pumpPage(tester, client);
    await openDelete(tester, 'file-api-b');
    await confirmDelete(tester);

    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud_file_file-api-b')), findsNothing);
    expect(find.text('加载更多'), findsNothing);
    expect(find.textContaining('synthetic-refresh-body-secret'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['after'], isNull);
    await tapLoadMore(tester);
    expect(requests.last.url.queryParameters['after'], 'file-api-c');
    expect(find.byKey(const ValueKey('cloud_file_file-api-d')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('初始请求期间修改 Key 丢弃旧配置文件结果', (tester) async {
    final pending = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.headers['Authorization'] == 'Bearer synthetic-provider-key') {
        return pending.future;
      }
      return _listResponse([]);
    });
    final store = await pumpPage(tester, client, settle: false);
    await store.updateProvider(
      store.settings.activeProvider.copy()..apiKey = 'synthetic-updated-key',
    );
    pending.complete(_listResponse([
      _file('file-api-old', filename: 'old-key-private-file.png'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('old-key-private-file.png'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('初始请求期间切换账号丢弃旧账号文件结果', (tester) async {
    final pending = Completer<http.Response>();
    final client = MockClient((_) async => pending.future);
    await pumpPage(tester, client, settle: false);
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'synthetic-account-token',
      userName: 'other',
      extras: const {'accountHash': 'other-account'},
    );
    pending.complete(_listResponse([
      _file('file-api-old', filename: 'old-account-private-file.png'),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('old-account-private-file.png'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除确认期间修改 Key 阻止针对旧文件发 DELETE', (tester) async {
    var deletes = 0;
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        deletes++;
        return _deletedResponse('file-api-a');
      }
      return _listResponse([_file('file-api-a')]);
    });
    final store = await pumpPage(tester, client);
    await openDelete(tester, 'file-api-a');
    await store.updateProvider(
      store.settings.activeProvider.copy()..apiKey = 'synthetic-updated-key',
    );
    await tester.pumpAndSettle();

    expect(deletes, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('账号或服务配置已变化，请返回重新打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除确认期间切换账号阻止针对旧文件发 DELETE', (tester) async {
    var deletes = 0;
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        deletes++;
        return _deletedResponse('file-api-a');
      }
      return _listResponse([_file('file-api-a')]);
    });
    await pumpPage(tester, client);
    await openDelete(tester, 'file-api-a');
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'synthetic-account-token',
      userName: 'other',
      extras: const {'accountHash': 'other-account'},
    );
    await confirmDelete(tester);

    expect(deletes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空列表可刷新，初始错误不泄露正文且可重试', (tester) async {
    var requests = 0;
    final client = MockClient((_) async {
      if (++requests == 1) return http.Response('synthetic-list-secret', 401);
      return _listResponse([]);
    });
    await pumpPage(tester, client);
    expect(find.textContaining('synthetic-list-secret'), findsNothing);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(find.text('暂无云端文件'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('加载更多'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未填 Key 或非官方地址不发云端文件请求', (tester) async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return _listResponse([]);
    });
    await pumpPage(tester, client, provider: _deepSeekProvider()..apiKey = '');
    expect(requests, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await pumpPage(tester, client,
        provider: _deepSeekProvider()..apiHost = 'https://gateway.invalid/v1');
    expect(requests, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px 长文件名、详情和删除确认保持可操作且无布局溢出', (tester) async {
    final file = _file('file-api-very-long-stable-identifier',
        filename: '测试用非常长的云端图片文件名-abcdefghijklmnopqrstuvwxyz.png');
    final client = MockClient((request) async => request.url.path == '/files'
        ? _listResponse([file])
        : _jsonResponse(file));
    await pumpPage(tester, client, size: const Size(320, 568));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(
      const ValueKey('cloud_file_file-api-very-long-stable-identifier'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('文件详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('文件详情'))).pop();
    await tester.pumpAndSettle();
    await openDelete(tester, 'file-api-very-long-stable-identifier');
    expect(tester.takeException(), isNull);
  });
}

AiProvider _deepSeekProvider() => AiProvider(
      id: 'deepseek',
      type: 'openai',
      name: 'DeepSeek',
      apiKey: 'synthetic-provider-key',
      apiHost: 'https://api.deepseek.com/v1',
      selectedModelId: 'deepseek-flash',
      enabled: true,
      isSystem: true,
      models: [AiModel(id: 'deepseek-flash')],
    );

Map<String, dynamic> _file(
  String id, {
  String? filename,
  int bytes = 2048,
  int? expiresAt,
}) =>
    {
      'id': id,
      'object': 'file',
      'bytes': bytes,
      'created_at': 1760000000,
      'expires_at': expiresAt,
      'filename': filename ?? '$id.png',
      'purpose': 'user_data',
    };

http.Response _listResponse(List<Map<String, dynamic>> files,
        {bool hasMore = false}) =>
    _jsonResponse({
      'object': 'list',
      'data': files,
      'first_id': files.isEmpty ? null : files.first['id'],
      'last_id': files.isEmpty ? null : files.last['id'],
      'has_more': hasMore,
    });

http.Response _deletedResponse(String id) => _jsonResponse({
      'id': id,
      'object': 'file',
      'deleted': true,
    });

http.Response _jsonResponse(Map<String, dynamic> json) => http.Response(
      jsonEncode(json),
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

/// 原有 API/页面测试隔离本地预览 I/O；图片行为另有预览页面和缓存测试。
class _EmptyPreviewStore extends DeepSeekFilePreviewStore {
  @override
  Future<Uint8List?> read({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) async =>
      null;

  @override
  Future<void> remove({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) async {}
}
