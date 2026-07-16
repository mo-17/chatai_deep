import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/app.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/bottom_navigator.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:login_sdk/config/secure_key_value_store.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('离线冷启动、游客导航与本地数据重启恢复', (tester) async {
    // 独立前缀避免测试读取或覆盖设备上已有的历史登录态/偏好。
    SharedPreferences.setPrefix('chatai_deep_offline_smoke.');
    final cache = await HiCache.preInit();
    await cache.prefs!.clear();
    await cache.prefs!.setString(
      'auth_public_config',
      jsonEncode({
        'huaweiGetAuthCodeEnabled': false,
        'huaweiQuickLoginEnabled': false,
        'huaweiPrimaryFlow': 'getAuthCode',
        'appleSignInEnabled': false,
        'supportedCountryCodes': const <String>[],
        '_ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    final secureStore = _MemorySecureKeyValueStore();
    final networkProbe = _NoNetworkHttpOverrides();
    HttpOverrides.global = networkProbe;
    int? createdAssistantId;
    addTearDown(() async {
      try {
        if (createdAssistantId != null) {
          final storage = await HiDBManager.instance(dbName: 'guest');
          await storage.db.delete(
            'tb_assistant',
            where: 'id = ?',
            whereArgs: [createdAssistantId],
          );
        }
      } finally {
        await HiDBManager.closeAll();
        HttpOverrides.global = null;
      }
    });

    await tester.pumpWidget(MyApp(secureStore: secureStore));
    await _pumpUntilFound(
      tester,
      find.text('游客模式，暂不登录 →'),
      reason: '离线冷启动应进入登录页',
    );

    await tester.tap(find.text('游客模式，暂不登录 →'));
    await _pumpUntilFound(
      tester,
      find.byType(BottomNavigator),
      reason: '游客登录应完全在本地完成',
    );
    expect(LoginDao.isGuest(), isTrue);
    expect(HiDBManager.getAccountHash(), 'guest');
    expect(find.text('聊天'), findsWidgets);

    final bottomNavigation = tester.widget<AppBottomNavigationBar>(
      find.byType(AppBottomNavigationBar),
    );
    bottomNavigation.onSelected(3);
    await _pumpUntilFound(
      tester,
      find.text('AI 服务设置'),
      reason: '底部导航应能离线进入我的页面',
    );

    final marker = 'offline-smoke-${DateTime.now().microsecondsSinceEpoch}';
    final storage = await HiDBManager.instance(dbName: 'guest');
    final assistantDao = await AssistantDao.create(storage);
    createdAssistantId = await assistantDao.saveAssistant(
      AssistantModel(name: marker, prompt: 'local-only'),
    );
    expect(createdAssistantId, isNotNull);

    // 模拟进程 UI 重建：安全登录态和 SQLite 都必须从持久化层恢复。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await HiDBManager.closeAll();
    await tester.pumpWidget(MyApp(secureStore: secureStore));
    await _pumpUntilFound(
      tester,
      find.byType(BottomNavigator),
      reason: '离线重启后应直接恢复游客主界面',
    );

    final reopened = await HiDBManager.instance(dbName: 'guest');
    final restored = await (await AssistantDao.create(reopened))
        .getAssistant(createdAssistantId!);
    expect(restored?.name, marker);

    // 给启动后的机会性任务一个调度窗口；任何 URL 都表示离线契约退化。
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      networkProbe.attemptedUris,
      isEmpty,
      reason: '离线 smoke 不应访问认证、模型目录、对话或云同步网络',
    );
  });
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 120; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure(reason);
}

final class _MemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

final class _NoNetworkHttpOverrides extends HttpOverrides {
  final List<Uri> attemptedUris = <Uri>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)
      ..connectionTimeout = const Duration(milliseconds: 250);
    client.findProxy = (uri) {
      attemptedUris.add(uri);
      return 'PROXY 127.0.0.1:9';
    };
    return client;
  }
}
