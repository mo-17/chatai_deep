import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

class ThemeProvider extends ChangeNotifier {
  static const keyThemeColor = 'theme_color';

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
  MaterialColor? _themeColor;

  get themeColor => _themeColor;

  ///获取主题模型
  MaterialColor init() {
    String? theme = HiCache.getInstance().get(keyThemeColor);
    return getThemeColor(theme);
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
    HiCache.getInstance().setString(keyThemeColor, colorName);
    _themeColor = getThemeColor(colorName);
    notifyListeners();
  }

  ///获取主题
  ThemeData getTheme() {
    _themeColor ??= init();
    return ThemeData(primarySwatch: _themeColor);
  }
}
