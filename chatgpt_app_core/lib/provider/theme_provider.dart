import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

class ThemeProvider extends ChangeNotifier {
  static const keyThemeColor = 'theme_color';
  static const keyVisualStyle = 'app_visual_style_v1';

  ///主题数组
  static const themes = [
    'blue',
    'red',
    'pink',
    'purple',
    'deepPurple',
    'indigo',
    'cyan',
    'teal',
    'green',
    'lightGreen',
    'lime',
    'yellow',
    'amber',
    'orange',
    'deepOrange',
    'brown',
    'grey'
  ];
  late MaterialColor _themeColor;
  late String _themeColorName;
  late AppVisualStyle _visualStyle;

  ThemeProvider() {
    _themeColorName = _loadThemeName();
    _themeColor = getThemeColor(_themeColorName);
    _visualStyle = AppVisualStyle.fromStorage(
      HiCache.getInstance().get<String>(keyVisualStyle),
    );
  }

  MaterialColor get themeColor => _themeColor;
  String get themeColorName => _themeColorName;
  AppVisualStyle get visualStyle => _visualStyle;
  bool get isAnime => _visualStyle == AppVisualStyle.anime;

  ///从缓存加载主题
  static String _loadThemeName() {
    final theme = HiCache.getInstance().get<String>(keyThemeColor);
    return themes.contains(theme) ? theme! : 'pink';
  }

  ///主题映射关系
  static MaterialColor getThemeColor(String? theme) {
    MaterialColor color;
    switch (theme) {
      case 'blue':
        color = Colors.blue;
        break;
      case 'red':
        color = Colors.red;
        break;
      case 'deepPurple':
        color = Colors.deepPurple;
        break;
      case 'indigo':
        color = Colors.indigo;
        break;
      case 'lightBlue':
        color = Colors.lightBlue;
        break;
      case 'cyan':
        color = Colors.cyan;
        break;
      case 'teal':
        color = Colors.teal;
        break;
      case 'purple':
        color = Colors.purple;
        break;
      case 'green':
        color = Colors.green;
        break;
      case 'lightGreen':
        color = Colors.lightGreen;
        break;
      case 'lime':
        color = Colors.lime;
        break;
      case 'yellow':
        color = Colors.yellow;
        break;
      case 'amber':
        color = Colors.amber;
        break;
      case 'orange':
        color = Colors.orange;
        break;
      case 'deepOrange':
        color = Colors.deepOrange;
        break;
      case 'brown':
        color = Colors.brown;
        break;
      case 'grey':
        color = Colors.grey;
        break;
      case 'pink':
        color = Colors.pink;
        break;
      default:
        color = Colors.pink;
        break;
    }
    return color;
  }

  ///设置主题
  void setTheme({required String colorName}) {
    final safeName = themes.contains(colorName) ? colorName : 'pink';
    HiCache.getInstance().setString(keyThemeColor, safeName);
    _themeColorName = safeName;
    _themeColor = getThemeColor(safeName);
    notifyListeners();
  }

  /// 切换视觉风格。经典强调色单独保存，往返切换不会丢失。
  void setVisualStyle(AppVisualStyle style) {
    if (_visualStyle == style) return;
    HiCache.getInstance().setString(keyVisualStyle, style.storageValue);
    _visualStyle = style;
    notifyListeners();
  }

  ///获取主题（只读，无副作用）
  ThemeData getTheme() {
    return switch (_visualStyle) {
      AppVisualStyle.classic => AppThemeFactory.classic(_themeColor),
      AppVisualStyle.anime => AppThemeFactory.anime(),
    };
  }
}
