import 'dart:async';

import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/hi_api_cache.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/pages/bottom_navigator.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/hi_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/dao/public_config_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/pages/login_page.dart';
import 'package:provider/provider.dart';

Future<void> runChatGptApp() async {
  // 必须把 ensureInitialized 与 runApp 放进同一个 Zone，否则平台通道回调
  // （含文本输入）跨 Zone 投递会出错——桌面端表现为输入框打不进字（Zone mismatch）。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      // 全局错误上报 hook（后续接入 Sentry / 自建上报时替换此处）
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        // ignore: avoid_print
        debugPrint('FlutterError: ${details.exceptionAsString()}');
        // TODO: 接入错误上报服务
      };

      runApp(const MyApp());
    },
    (Object error, StackTrace stack) {
      // ignore: avoid_print
      debugPrint('uncaught error: $error\n$stack');
      // TODO: 接入错误上报服务
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = doInit();
  }

  Widget get _loadingPage => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );

  Widget _errorPage(Object error) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text('启动失败，请重启 App', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                Text(error.toString(),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _initFuture = doInit();
                    });
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
        if (snapshot.hasError) {
          return _errorPage(snapshot.error!);
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return _loadingPage;
        }
        final widget = LoginDao.getBoardingPass() == null
            ? const LoginPage()
            : const BottomNavigator();
        return MultiProvider(
          providers: mainProviders,
          child: Consumer<ThemeProvider>(builder: (BuildContext context,
              ThemeProvider themeProvider, Widget? child) {
            return MaterialApp(
              home: widget,
              theme: themeProvider.getTheme(),
              title: 'ChatGPT',
            );
          }),
        );
      },
    );
  }

  Future<void> doInit() async {
    await LoginConfig.instance().init(homePage: const BottomNavigator());
    await HiCache.preInit();
    HiAPICache.init(HiCache.getInstance());
    ModelCatalog.loadFromCache();
    unawaited(ModelCatalog.refreshFromBackend());

    // 预加载公开配置（Apple/华为按钮显隐等），不阻塞启动
    unawaited(PublicConfigLoader.load());

    // 已登录状态预加载 AI 设置，避免 BottomNavigator 首帧读到默认值
    if (LoginDao.getBoardingPass() != null) {
      AISettingsDao.load();
    }

    if (!LoginDao.hooksRegistered) {
      LoginDao.hooksRegistered = true;
      LoginDao.addLogoutHook(() {
        HiDBManager.closeAll();
      });
      LoginDao.addLogoutHook(() {
        // 游客「去登录」不清其本地 AI 配置：游客设置存在独立的 guest key 下，
        // 保留它，下次回到游客模式时 key 还在（钩子先于 storage.clear() 执行，
        // 此刻仍可判断 isGuest）。
        if (LoginDao.isGuest()) return;
        final reset = AISettingsProvider.instance?.settings.resetOnLogout ?? true;
        if (reset) {
          AISettingsProvider.resetToDefaults();
        }
      });
      LoginDao.addLogoutHook(() {
        HiAPICache.getInstance().clearAll();
      });
      // 登录成功后重新加载 AI 设置（accountHash 已变更）
      LoginDao.addLoginHook(() {
        AISettingsProvider.reloadInstance();
      });
    }
  }
}
