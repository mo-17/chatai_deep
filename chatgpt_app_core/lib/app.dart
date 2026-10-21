import 'dart:async';
import 'platform/desktop_quick_assistant.dart';
import 'package:chatgpt_app_core/chat/ui/conversation_generation_routes.dart';

import 'package:chatgpt_app_core/diagnostics/diagnostics_consent_store.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_sink.dart';
import 'package:chatgpt_app_core/diagnostics/flutter_diagnostics_bridge.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/story_template_background_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/hi_api_cache.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/pages/bottom_navigator.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/hi_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/sync/cloud_sync_client.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/dao/public_config_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/pages/login_page.dart';
import 'package:login_sdk/platform/app_io.dart' show initializeBrowserFileSystem;
import 'package:provider/provider.dart';

Future<void> runChatGptApp({
  Future<void> Function()? platformInitializer,
  SecureKeyValueStore? secureStore,
  DiagnosticsSink diagnosticsSink = const NoopDiagnosticsSink(),
  DiagnosticsConsentStore diagnosticsConsentStore =
      const DiagnosticsConsentStore(),
  DiagnosticsFlagReader? diagnosticsBuildConfigured,
  DiagnosticsFlagReader? diagnosticsRemoteDisabled,
  void Function()? afterRunApp,
}) {
  final initialized = Completer<void>();
  FlutterDiagnosticsBridge? diagnosticsBridge;
  // 必须把 ensureInitialized 与 runApp 放进同一个 Zone，否则平台通道回调
  // （含文本输入）跨 Zone 投递会出错——桌面端表现为输入框打不进字（Zone mismatch）。
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final gatedDiagnosticsSink = ConsentGatedDiagnosticsSink(
        delegate: diagnosticsSink,
        consentStore: diagnosticsConsentStore,
        buildConfigured: diagnosticsBuildConfigured,
        remoteDisabled: diagnosticsRemoteDisabled,
      );
      diagnosticsBridge = FlutterDiagnosticsBridge(sink: gatedDiagnosticsSink)
        ..installFlutterHandler()
        ..installPlatformHandler();

      try {
        await platformInitializer?.call();
        runApp(MyApp(secureStore: secureStore));
        afterRunApp?.call();
        initialized.complete();
      } catch (error, stackTrace) {
        if (!initialized.isCompleted) {
          initialized.completeError(error, stackTrace);
        }
        rethrow;
      }
    },
    (Object error, StackTrace stack) {
      diagnosticsBridge?.recordZoneError(error, stack);
      if (kDebugMode) {
        debugPrint('uncaught error: ${error.runtimeType}');
      }
      if (!initialized.isCompleted) {
        initialized.completeError(error, stack);
      }
    },
  );
  return initialized.future;
}

class MyApp extends StatefulWidget {
  final SecureKeyValueStore? secureStore;

  const MyApp({super.key, this.secureStore});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late Future<void> _initFuture;

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
                if (error is SecureStorageUnavailableException) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _recoverAndRetry(
                      () => LoginSdkConfig.instance.storage.clear(),
                    ),
                    child: Text(error.corrupt ? '清除损坏登录态并重新登录' : '强制退出并重新登录'),
                  ),
                ],
                if (error is AISecretsUnavailableException) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _recoverAndRetry(() async {
                      if (error.corrupt) {
                        await AISettingsDao.resetCredentialsFor(
                          error.accountHash,
                        );
                      } else {
                        await AISettingsDao.clearFor(error.accountHash);
                      }
                    }),
                    child: Text(error.corrupt ? '修复并清空 AI 凭据' : '强制重置全部 AI 设置'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '会话数据不受影响。损坏时会优先保留可读取的 provider、模型、'
                      '搜索参数和 MCP 地址；若普通配置也损坏，才会重置全部 AI 设置。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  void _recoverAndRetry(Future<void> Function() recovery) {
    setState(() {
      _initFuture = () async {
        await recovery();
        await doInit();
      }();
    });
  }

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
              navigatorKey: _navigatorKey,
              navigatorObservers: [ConversationGenerationRoutes.instance],
              home: widget,
              theme: themeProvider.getTheme(),
              // 经典主题沿用旧 Material 配置，二次元主题使用 Material 3；
              // 两套 TextStyle 无法被 Flutter 安全插值，因此根主题直接切换，
              // 页面内的选中态和内容仍各自保留 180–220ms 动效。
              themeAnimationDuration: Duration.zero,
              debugShowCheckedModeBanner: false,
              title: '艾普',
            );
          }),
        );
      },
    );
  }

  Future<void> doInit() async {
    await initializeBrowserFileSystem();
    final tokenStorage = widget.secureStore == null
        ? null
        : MigratingTokenStorage(secureStore: widget.secureStore!);
    await LoginConfig.instance().init(
      homePage: const BottomNavigator(),
      tokenStorage: tokenStorage,
    );
    AISettingsDao.configureSecretStore(widget.secureStore);
    final initialAccount = LoginDao.getAccountHash();
    if (initialAccount != null) {
      await AISettingsDao.loadForAsync(initialAccount);
    }
    HiAPICache.init(HiCache.getInstance());
    await DesktopQuickAssistant.instance.initialize(_navigatorKey);
    ModelCatalog.loadFromCache();
    unawaited(ModelCatalog.refreshFromBackend());

    // 预加载公开配置（Apple/华为按钮显隐等），不阻塞启动
    unawaited(PublicConfigLoader.load());

    // 已登录状态预加载 AI 设置，避免 BottomNavigator 首帧读到默认值
    if (LoginDao.getBoardingPass() != null) {
      unawaited(_resumeStoryTemplateTranslations());
    }

    final taskExecutor = AgentTaskExecutor.ensureInitialized();
    if (!LoginDao.hooksRegistered) {
      LoginDao.hooksRegistered = true;
      LoginDao.addLoginReadyHook(() async {
        final accountHash = LoginDao.getAccountHash();
        if (accountHash != null) {
          await AISettingsDao.loadForAsync(accountHash);
        }
      });
      LoginDao.addLogoutHook(() {
        final accountHash = LoginDao.getAccountHash();
        if (accountHash != null) {
          unawaited(StoryTemplateBackgroundScheduler.cancel(accountHash));
        }
      });
      LoginDao.addLogoutReadyHook(() async {
        // 独立任务先取消并保存断点，再关闭账号库；不能等页面销毁才收尾。
        await taskExecutor.cancelAll('已退出账户，任务已暂停');
        await StoryTemplateTranslationCoordinator.instance.detachForLifecycle();
        await HiDBManager.closeAll();
      });
      LoginDao.addLogoutHook(() {
        // 游客「去登录」不清其本地 AI 配置：游客设置存在独立的 guest key 下，
        // 保留它，下次回到游客模式时 key 还在（钩子先于 storage.clear() 执行，
        // 此刻仍可判断 isGuest）。
        if (LoginDao.isGuest()) return;
        final reset =
            AISettingsProvider.instance?.settings.resetOnLogout ?? true;
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
      LoginDao.addLoginHook(() {
        unawaited(_resumeStoryTemplateTranslations());
      });
      LoginDao.addLoginHook(() {
        CloudSyncCoordinator.syncOnLogin();
      });
    }
  }

  Future<void> _resumeStoryTemplateTranslations() async {
    try {
      final accountHash = HiDBManager.getAccountHash();
      final storage = await HiDBManager.instance(dbName: accountHash);
      final coordinator = StoryTemplateTranslationCoordinator.instance;
      await coordinator.initialize(storage, accountHash: accountHash);
      final settings = AISettingsDao.load();
      final environment = TranslationEligibilityEnvironment.current();
      const evaluator = TranslationModelEligibilityEvaluator();
      TranslationEligibilityResult checkEligibility(
        TranslationRequestProfile profile,
      ) =>
          evaluator.evaluateProfile(
            settings: settings,
            profile: profile,
            environment: environment,
          );
      await coordinator.resumeRecoverable(
        checkEligibility: checkEligibility,
        resolveLegacyRequestProfile: () =>
            TranslationModelResolver.legacyFallbackOrNull(
          settings,
          TranslationModelPreferenceStore().read(accountHash),
        ),
        resolveExecutor: (profile) => TranslationStreamExecutor(
          service: ChatService.from(
            TranslationModelResolver.apply(settings, profile),
          ),
          profile: profile,
        ),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          'resume story template translations failed: ${error.runtimeType}',
        );
      }
    }
  }
}
