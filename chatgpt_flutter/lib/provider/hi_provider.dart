import 'package:chatgpt_flutter/provider/ai_settings_provider.dart';
import 'package:chatgpt_flutter/provider/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

List<SingleChildWidget> mainProviders = [
  ChangeNotifierProvider(create: (_) => ThemeProvider()),
  ChangeNotifierProvider(create: (_) => AISettingsProvider()..load()),
];
