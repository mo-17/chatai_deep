import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_consent_store.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';
import 'package:chatgpt_app_core/pages/my_page.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/update/app_update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  testWidgets('账号 id 缺失时不向用户显示 null 占位文本', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: const MaterialApp(home: MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('imooc id：null'), findsNothing);
  });

  testWidgets('个人中心菜单在小屏下可滚动，不发生底部溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: const MaterialApp(home: MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 服务设置'), findsOneWidget);
    expect(find.text('外观与主题'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('检测更新'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('检测更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人中心可进入外观设置页', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(theme: provider.getTheme(), home: const MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('外观与主题'));
    await tester.pumpAndSettle();

    expect(find.text('界面风格'), findsOneWidget);
    expect(find.text('经典风格'), findsOneWidget);
    expect(find.text('梦幻二次元'), findsOneWidget);
  });

  testWidgets('隐私诊断默认关闭，只有持久化成功后才显示开启', (tester) async {
    final storage = _MemoryDiagnosticsConsentStore();
    final consentStore = DiagnosticsConsentStore(
      storage: storage,
      session: DiagnosticsConsentSessionState(),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: MyPage(diagnosticsConsentStore: consentStore),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tapDiagnostics(tester);

    expect(find.text('匿名错误诊断'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(storage.values[DiagnosticsConsentStore.key], isTrue);
  });

  testWidgets('诊断同意写入失败时保持关闭并提示未保存', (tester) async {
    final storage = _MemoryDiagnosticsConsentStore(writeSucceeds: false);
    final consentStore = DiagnosticsConsentStore(
      storage: storage,
      session: DiagnosticsConsentSessionState(),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: MyPage(diagnosticsConsentStore: consentStore),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tapDiagnostics(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('诊断设置未保存，请稍后重试'), findsOneWidget);
  });

  testWidgets('anime 的 12 个二级页入口统一使用轻量路由转场', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    final observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme().copyWith(
                platform: TargetPlatform.android,
              ),
          navigatorObservers: [observer],
          home: const MyPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    observer.pushed.clear();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final scrollable = find.byType(Scrollable).first;
    const entries = [
      '外观与主题',
      'AI 服务设置',
      'MCP 服务',
      '助手管理',
      '知识库',
      '离线语音模型',
      'AI 能力中心',
      '用量统计',
      '生成图片相册',
      '工具审计',
      '跨设备云同步',
      '备份与恢复',
    ];

    for (final title in entries) {
      await tester.scrollUntilVisible(
        find.text(title),
        180,
        scrollable: scrollable,
      );
      await tester.pump();
      final inkWell = tester.widget<InkWell>(
        find
            .ancestor(of: find.text(title), matching: find.byType(InkWell))
            .first,
      );

      inkWell.onTap!();

      expect(observer.pushed, hasLength(1), reason: title);
      final route = observer.pushed.single;
      expect(route, isA<MaterialPageRoute<void>>(), reason: title);
      final materialRoute = route as MaterialPageRoute<void>;
      expect(
        materialRoute.transitionDuration,
        AppAnimePageTransitionsBuilder.enterDuration,
        reason: title,
      );
      expect(
        materialRoute.reverseTransitionDuration,
        AppAnimePageTransitionsBuilder.exitDuration,
        reason: title,
      );

      navigator.removeRoute(route);
      observer.pushed.clear();
      await tester.pump();
    }
  });

  testWidgets('没有新版本时只提示当前已是最新版本', (tester) async {
    var downloadCalled = false;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: MyPage(
            operatingSystem: 'android',
            distribution: AppDistribution.direct,
            updateChecker: () async => ApkModel(updateAvailable: false),
            downloadHandler: (_, __) async {
              downloadCalled = true;
              return '/tmp/unused.apk';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tapUpdate(tester);

    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(find.text('有新版本啦'), findsNothing);
    expect(downloadCalled, isFalse);
  });

  testWidgets('检测更新入口显示当前安装版本与构建号', (tester) async {
    final updates = AppUpdateController(
      packageInfoLoader: () async => PackageInfo(
        appName: '艾普',
        packageName: 'com.example.chatgpt_flutter',
        version: '1.0.5',
        buildNumber: '15',
      ),
    );
    addTearDown(updates.dispose);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: MaterialApp(home: MyPage(updateController: updates)),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('检测更新'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('当前版本 1.0.5（15）'), findsOneWidget);
  });

  testWidgets('Store 更新只打开商店，不调用 APK 下载', (tester) async {
    var downloadCalled = false;
    String? openedUrl;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: MyPage(
            operatingSystem: 'android',
            distribution: AppDistribution.store,
            updateChecker: () async => ApkModel(
              updateAvailable: true,
              storeUrl: 'https://store.example.com/app',
              description: 'Store release',
            ),
            downloadHandler: (_, __) async {
              downloadCalled = true;
              return '/tmp/unused.apk';
            },
            storeOpener: (url) async {
              openedUrl = url;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tapUpdate(tester);
    expect(find.text('有新版本啦'), findsOneWidget);
    expect(find.text('前往更新'), findsOneWidget);

    await tester.tap(find.text('前往更新'));
    await tester.pumpAndSettle();

    expect(openedUrl, 'https://store.example.com/app');
    expect(downloadCalled, isFalse);
  });

  testWidgets('强制更新弹窗不显示取消操作', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: MyPage(
            operatingSystem: 'android',
            distribution: AppDistribution.direct,
            updateChecker: () async => ApkModel(
              updateAvailable: true,
              forceUpdate: true,
              downloadUrl: 'https://example.com/app.apk',
              description: 'Required release',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tapUpdate(tester);

    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
  });
}

Future<void> _tapUpdate(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('检测更新'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('检测更新'));
  await tester.pumpAndSettle();
}

Future<void> _tapDiagnostics(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('隐私与诊断'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('隐私与诊断'));
  await tester.pumpAndSettle();
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) pushed.add(route);
  }
}

class _MemoryDiagnosticsConsentStore
    implements DiagnosticsConsentKeyValueStore {
  final Map<String, Object?> values = {};
  final bool writeSucceeds;

  _MemoryDiagnosticsConsentStore({this.writeSucceeds = true});

  @override
  Object? read(String key) => values[key];

  @override
  Future<bool> writeBool(String key, bool value) async {
    if (!writeSucceeds) return false;
    values[key] = value;
    return true;
  }
}
