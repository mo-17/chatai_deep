import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

List<SingleChildWidget> mainProviders = [
  ChangeNotifierProvider(create: (_) => ThemeProvider()),
  ChangeNotifierProvider(create: (_) => AISettingsProvider()..load()),
  ChangeNotifierProxyProvider<AISettingsProvider, AIReadinessProvider>(
    create: (_) => AIReadinessProvider(),
    update: (_, settings, readiness) {
      final provider = readiness ?? AIReadinessProvider();
      provider.synchronize(
        settings: settings.settings,
        accountHash: settings.accountHash,
        isGuest: LoginDao.isGuest(),
      );
      return provider;
    },
  ),
];
