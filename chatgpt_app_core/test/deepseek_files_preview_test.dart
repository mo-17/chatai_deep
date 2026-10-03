import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/deepseek_file_preview_store.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
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
  late _MemoryPreviewStore previews;

  setUp(() async {
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
    AISettingsDao.configureSecretStore(_MemorySecureStore());
    previews = _MemoryPreviewStore();
  });

  tearDown(() {
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
  });

  Future<void> savePreview(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      await previews.save(
        accountHash: 'guest',
        chatCompletionsUrl: 'https://api.deepseek.com/v1/chat/completions',
        apiKey: 'synthetic-preview-key',
        fileId: id,
        bytes: await _png(),
      );
    });
  }

  Future<Uint8List?> readPreview(WidgetTester tester, String id) =>
      previews.read(
        accountHash: 'guest',
        chatCompletionsUrl: 'https://api.deepseek.com/chat/completions',
        apiKey: 'synthetic-preview-key',
        fileId: id,
      );

  Future<void> settlePreview(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  Future<AISettingsProvider> pumpPage(
    WidgetTester tester,
    MockClient client, {
    Size size = const Size(390, 844),
    AiProvider? provider,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.close);
    final item = provider ?? _provider();
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
            previewStore: previews,
          ),
        ),
      ),
    );
    await settlePreview(tester);
    return store;
  }

  Future<void> showDetails(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('cloud_file_$id')));
    await settlePreview(tester);
    expect(find.text('文件详情'), findsOneWidget);
  }

  Future<void> showFullscreen(WidgetTester tester, String id) async {
    await showDetails(tester, id);
    await tester.tap(find.byKey(ValueKey('detail_preview_$id')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image_preview_viewer')), findsOneWidget);
  }

  Future<void> deleteFile(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('delete_file_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('删除'),
    ));
    await settlePreview(tester);
  }

  testWidgets('本机已上传图片显示真实缩略图，列表不请求下载地址', (tester) async {
    await savePreview(tester, 'file-api-a');
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      return _listResponse([_file('file-api-a')]);
    });
    await pumpPage(tester, client);

    final image = tester.widget<Image>(
      find.byKey(const ValueKey('cloud_preview_file-api-a')),
    );
    final provider = image.image;
    expect(provider is ResizeImage ? provider.imageProvider : provider,
        isA<MemoryImage>());
    expect(find.text('暂无预览'), findsNothing);
    expect(paths, ['/files']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情显示图片，点击可全屏缩放并关闭返回详情', (tester) async {
    await savePreview(tester, 'file-api-a');
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      return request.url.path == '/files'
          ? _listResponse([_file('file-api-a')])
          : _jsonResponse(_file('file-api-a'));
    });
    await pumpPage(tester, client);
    await showFullscreen(tester, 'file-api-a');

    final viewerFinder = find.byKey(const ValueKey('image_preview_viewer'));
    expect(tester.getSize(viewerFinder).width, greaterThan(40));
    expect(tester.getSize(viewerFinder).height, greaterThan(10));
    final center = tester.getCenter(viewerFinder);
    final first =
        await tester.startGesture(center - const Offset(20, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(20, 0), pointer: 2);
    await tester.pump();
    await first.moveTo(center - const Offset(70, 0));
    await second.moveTo(center + const Offset(70, 0));
    await tester.pump();
    // 首段移动越过手势识别阈值，随后继续拉开验证真实缩放。
    await first.moveTo(center - const Offset(120, 0));
    await second.moveTo(center + const Offset(120, 0));
    await tester.pump();
    final transform = tester.widget<Transform>(find
        .descendant(
          of: viewerFinder,
          matching: find.byType(Transform),
        )
        .first);
    expect(transform.transform.getMaxScaleOnAxis(), greaterThan(1));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭图片预览'));
    await tester.pumpAndSettle();
    expect(viewerFinder, findsNothing);
    expect(find.text('文件详情'), findsOneWidget);
    expect(paths, ['/files', '/files/file-api-a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧云端文件缺少本地原图时解释预览限制，仍可查看元信息', (tester) async {
    final client = MockClient((request) async => request.url.path == '/files'
        ? _listResponse([_file('file-api-remote')])
        : _jsonResponse(_file('file-api-remote')));
    await pumpPage(tester, client);
    expect(find.text('暂无预览'), findsOneWidget);
    await showDetails(tester, 'file-api-remote');

    expect(find.text('此文件没有本地预览。DeepSeek 文件接口未提供图片下载地址。'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail_preview_file-api-remote')),
        findsNothing);
    expect(find.textContaining('file-api-remote'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('损坏的本地预览回退到说明，无图片解码异常', (tester) async {
    await savePreview(tester, 'file-api-a');
    previews.corrupt('file-api-a');
    final client = MockClient((request) async => request.url.path == '/files'
        ? _listResponse([_file('file-api-a')])
        : _jsonResponse(_file('file-api-a')));
    await pumpPage(tester, client);
    expect(find.text('暂无预览'), findsOneWidget);
    await showDetails(tester, 'file-api-a');
    expect(find.textContaining('此文件没有本地预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px 显示缩略图、详情和全屏预览，无布局溢出', (tester) async {
    await savePreview(tester, 'file-api-a');
    final file = _file('file-api-a',
        filename: '非常长的图片文件名-abcdefghijklmnopqrstuvwxyz.png');
    final client = MockClient((request) async => request.url.path == '/files'
        ? _listResponse([file])
        : _jsonResponse(file));
    await pumpPage(tester, client, size: const Size(320, 568));
    expect(
        find.byKey(const ValueKey('cloud_preview_file-api-a')), findsOneWidget);
    await showFullscreen(tester, 'file-api-a');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭图片预览'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Key 改变立即关闭全屏及详情，不显示旧凭据图片', (tester) async {
    await savePreview(tester, 'file-api-a');
    final client = MockClient((request) async => request.url.path == '/files'
        ? _listResponse([_file('file-api-a')])
        : _jsonResponse(_file('file-api-a')));
    final store = await pumpPage(tester, client);
    await showFullscreen(tester, 'file-api-a');
    await store.updateProvider(
      store.settings.activeProvider.copy()..apiKey = 'synthetic-other-key',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('image_preview_viewer')), findsNothing);
    expect(find.text('文件详情'), findsNothing);
    expect(
        find.byKey(const ValueKey('cloud_preview_file-api-a')), findsNothing);
    expect(find.text('账号或服务配置已变化，请返回重新打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账号改变立即关闭全屏及详情，不显示旧账号图片', (tester) async {
    await savePreview(tester, 'file-api-a');
    final client = MockClient((request) async => request.url.path == '/files'
        ? _listResponse([_file('file-api-a')])
        : _jsonResponse(_file('file-api-a')));
    final store = await pumpPage(tester, client);
    await showFullscreen(tester, 'file-api-a');
    await LoginSdkConfig.instance.storage.writeProfile(
      token: 'synthetic-other-token',
      userName: 'other',
      extras: const {'accountHash': 'other-account'},
    );
    await store.reload();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('image_preview_viewer')), findsNothing);
    expect(find.text('文件详情'), findsNothing);
    expect(
        find.byKey(const ValueKey('cloud_preview_file-api-a')), findsNothing);
    expect(find.text('账号或服务配置已变化，请返回重新打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅在删除成功回执后清理对应本地预览', (tester) async {
    await savePreview(tester, 'file-api-a');
    var deleted = false;
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        deleted = true;
        return _jsonResponse(
            {'id': 'file-api-a', 'object': 'file', 'deleted': true});
      }
      return _listResponse(deleted ? [] : [_file('file-api-a')]);
    });
    await pumpPage(tester, client);
    expect(await readPreview(tester, 'file-api-a'), isNotNull);
    await deleteFile(tester, 'file-api-a');

    expect(deleted, isTrue);
    expect(await readPreview(tester, 'file-api-a'), isNull);
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除失败保留本地预览和云端文件卡片', (tester) async {
    await savePreview(tester, 'file-api-a');
    final client = MockClient((request) async => request.method == 'DELETE'
        ? http.Response('synthetic-error', 500)
        : _listResponse([_file('file-api-a')]));
    await pumpPage(tester, client);
    await deleteFile(tester, 'file-api-a');

    expect(await readPreview(tester, 'file-api-a'), isNotNull);
    expect(
        find.byKey(const ValueKey('cloud_preview_file-api-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud_file_file-api-a')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一 file_id 切换 Key 后不能读取旧 Key 的本地预览', (tester) async {
    await savePreview(tester, 'file-api-a');
    final client =
        MockClient((_) async => _listResponse([_file('file-api-a')]));
    await pumpPage(tester, client,
        provider: _provider()..apiKey = 'synthetic-other-key');

    expect(find.text('暂无预览'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('cloud_preview_file-api-a')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, 64, 32), Paint()..color = Colors.red);
  canvas.drawRect(
      const Rect.fromLTWH(32, 0, 32, 32), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = Uint8List.fromList(data!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return bytes;
}

AiProvider _provider() => AiProvider(
      id: 'deepseek',
      type: 'openai',
      name: 'DeepSeek',
      apiKey: 'synthetic-preview-key',
      apiHost: 'https://api.deepseek.com/v1',
      selectedModelId: 'deepseek-flash',
      enabled: true,
      isSystem: true,
      models: [AiModel(id: 'deepseek-flash')],
    );

Map<String, dynamic> _file(String id, {String? filename}) => {
      'id': id,
      'object': 'file',
      'bytes': 2048,
      'created_at': 1760000000,
      'filename': filename ?? '$id.png',
      'purpose': 'user_data',
    };

http.Response _listResponse(List<Map<String, dynamic>> files) => _jsonResponse({
      'object': 'list',
      'data': files,
      'first_id': files.isEmpty ? null : files.first['id'],
      'last_id': files.isEmpty ? null : files.last['id'],
      'has_more': false,
    });

http.Response _jsonResponse(Map<String, dynamic> value) => http.Response(
      jsonEncode(value),
      200,
      headers: {'content-type': 'application/json'},
    );

class _MemorySecureStore implements SecureKeyValueStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// 页面测试只模拟存储边界；使用真实 PNG 验证 Flutter 解码和缩放。
/// 真实磁盘缓存的隔离、预算和损坏校验由存储测试覆盖。
class _MemoryPreviewStore extends DeepSeekFilePreviewStore {
  final _values = <String, Uint8List>{};

  String _key(String accountHash, String url, String apiKey, String fileId) =>
      jsonEncode([
        accountHash,
        DeepSeekFileService.filesEndpointFor(url).toString(),
        apiKey,
        fileId,
      ]);

  void corrupt(String id) {
    for (final key in _values.keys.toList()) {
      if ((jsonDecode(key) as List).last == id) {
        _values[key] = Uint8List.fromList([0, 1, 2, 3]);
      }
    }
  }

  @override
  Future<Uint8List?> read({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) async =>
      _values[_key(accountHash, chatCompletionsUrl, apiKey, fileId)];

  @override
  Future<void> save({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
    required Uint8List bytes,
    bool Function()? shouldSave,
  }) async {
    if (shouldSave != null && !shouldSave()) return;
    _values[_key(accountHash, chatCompletionsUrl, apiKey, fileId)] = bytes;
  }

  @override
  Future<void> remove({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) async {
    _values.remove(_key(accountHash, chatCompletionsUrl, apiKey, fileId));
  }
}
