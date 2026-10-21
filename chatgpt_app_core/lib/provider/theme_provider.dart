import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

class ThemeProvider extends ChangeNotifier {
  static const keyThemeColor = 'theme_color';
  static const keyVisualStyle = 'app_visual_style_v1';
  static const keyShowMessageAvatars = 'chat_show_avatars_v1';
  static const keyUserBubbleColor = 'chat_user_bubble_color_v1';
  static const keyAiBubbleColor = 'chat_ai_bubble_color_v1';
  static const keyUserBubbleStyle = 'chat_user_bubble_style_v1';
  static const keyAiBubbleStyle = 'chat_ai_bubble_style_v1';
  static const keyUserAvatarFrame = 'chat_user_avatar_frame_v1';
  static const keyAiAvatarFrame = 'chat_ai_avatar_frame_v1';
  static const keyFollowConversationDecoration = 'chat_follow_decoration_v1';
  static const keyConversationDecoration = 'chat_conversation_decoration_v1';

  late ChatBubbleStyle _userBubbleStyle;
  late ChatBubbleStyle _aiBubbleStyle;
  late ChatAvatarFrameStyle _userAvatarFrame;
  late ChatAvatarFrameStyle _aiAvatarFrame;
  late bool _followConversationDecoration;
  ChatIllustratedTheme? _conversationDecoration;

  late bool _showMessageAvatars;
  Color? _userBubbleColor;
  Color? _aiBubbleColor;

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
    final cache = HiCache.getInstance();
    _userBubbleStyle =
        ChatBubbleStyle.fromStorage(cache.get<String>(keyUserBubbleStyle));
    _aiBubbleStyle =
        ChatBubbleStyle.fromStorage(cache.get<String>(keyAiBubbleStyle));
    _userAvatarFrame =
        ChatAvatarFrameStyle.fromStorage(cache.get<String>(keyUserAvatarFrame));
    _aiAvatarFrame =
        ChatAvatarFrameStyle.fromStorage(cache.get<String>(keyAiAvatarFrame));
    _followConversationDecoration =
        cache.get<bool>(keyFollowConversationDecoration) ?? true;
    _conversationDecoration = ChatBubbleStyle.fromStorage(
                cache.get<String>(keyConversationDecoration))
            .illustration ??
        _userBubbleStyle.illustration ??
        _aiBubbleStyle.illustration;
    _showMessageAvatars = cache.get<bool>(keyShowMessageAvatars) ?? true;
    _userBubbleColor = _loadBubbleColor(keyUserBubbleColor);
    _aiBubbleColor = _loadBubbleColor(keyAiBubbleColor);
    _themeColorName = _loadThemeName();
    _themeColor = getThemeColor(_themeColorName);
    _visualStyle = AppVisualStyle.fromStorage(
      HiCache.getInstance().get<String>(keyVisualStyle),
    );
  }

  bool get showMessageAvatars => _showMessageAvatars;
  Color? get userBubbleColor => _userBubbleColor;
  Color? get aiBubbleColor => _aiBubbleColor;
  bool get followConversationDecoration => _followConversationDecoration;
  ChatIllustratedTheme? get conversationDecoration =>
      _followConversationDecoration ? _conversationDecoration : null;

  void setFollowConversationDecoration(bool value) {
    if (_followConversationDecoration == value) return;
    _followConversationDecoration = value;
    HiCache.getInstance().setBool(keyFollowConversationDecoration, value);
    notifyListeners();
  }

  void _rememberConversationDecoration(ChatIllustratedTheme theme) {
    _conversationDecoration = theme;
    HiCache.getInstance().setString(keyConversationDecoration, theme.name);
  }

  ChatBubbleStyle bubbleStyle({required bool isUser}) =>
      isUser ? _userBubbleStyle : _aiBubbleStyle;

  ChatAvatarFrameStyle avatarFrame({required bool isUser}) =>
      isUser ? _userAvatarFrame : _aiAvatarFrame;

  void setBubbleStyle({required bool isUser, required ChatBubbleStyle style}) {
    if (bubbleStyle(isUser: isUser) == style) return;
    if (isUser) {
      _userBubbleStyle = style;
    } else {
      _aiBubbleStyle = style;
    }
    HiCache.getInstance()
        .setString(isUser ? keyUserBubbleStyle : keyAiBubbleStyle, style.name);
    if (style.illustration case final illustrated?) {
      _rememberConversationDecoration(illustrated);
    }
    notifyListeners();
  }

  void setAvatarFrame(
      {required bool isUser, required ChatAvatarFrameStyle style}) {
    if (avatarFrame(isUser: isUser) == style) return;
    if (isUser) {
      _userAvatarFrame = style;
    } else {
      _aiAvatarFrame = style;
    }
    HiCache.getInstance()
        .setString(isUser ? keyUserAvatarFrame : keyAiAvatarFrame, style.name);
    notifyListeners();
  }

  /// 一次应用当前消息侧的整套装扮与预设配色，不覆盖另一侧设置。
  void applyDecorationSet(
      {required bool isUser, required ChatIllustratedTheme theme}) {
    final bubble = ChatBubbleStyle.fromStorage(theme.name);
    final frame = ChatAvatarFrameStyle.fromStorage(theme.name);
    if (isUser) {
      _userBubbleStyle = bubble;
      _userAvatarFrame = frame;
      _userBubbleColor = null;
    } else {
      _aiBubbleStyle = bubble;
      _aiAvatarFrame = frame;
      _aiBubbleColor = null;
    }
    final cache = HiCache.getInstance();
    cache.setString(
        isUser ? keyUserBubbleStyle : keyAiBubbleStyle, bubble.name);
    cache.setString(isUser ? keyUserAvatarFrame : keyAiAvatarFrame, frame.name);
    cache.remove(isUser ? keyUserBubbleColor : keyAiBubbleColor);
    _rememberConversationDecoration(theme);
    notifyListeners();
  }

  /// 只恢复装扮与气泡配色，保留界面主题、强调色和头像开关。
  void resetChatDecoration() {
    _userBubbleStyle = _aiBubbleStyle = ChatBubbleStyle.classic;
    _userAvatarFrame = _aiAvatarFrame = ChatAvatarFrameStyle.none;
    _userBubbleColor = _aiBubbleColor = null;
    _conversationDecoration = null;
    _followConversationDecoration = true;
    for (final key in [
      keyUserBubbleStyle,
      keyAiBubbleStyle,
      keyUserAvatarFrame,
      keyAiAvatarFrame,
      keyUserBubbleColor,
      keyAiBubbleColor,
      keyConversationDecoration,
      keyFollowConversationDecoration,
    ]) {
      HiCache.getInstance().remove(key);
    }
    notifyListeners();
  }

  static Color? _loadBubbleColor(String key) {
    final value = HiCache.getInstance().get<int>(key);
    if (value == null || value < 0 || value > 0xFFFFFFFF) return null;
    return Color(value).withValues(alpha: 1);
  }

  void setShowMessageAvatars(bool value) {
    if (_showMessageAvatars == value) return;
    _showMessageAvatars = value;
    HiCache.getInstance().setBool(keyShowMessageAvatars, value);
    notifyListeners();
  }

  /// 两侧独立保存；null 表示恢复随主题变化的默认配色。
  void setBubbleColor({required bool isUser, required Color? color}) {
    final opaque = color?.withValues(alpha: 1);
    if ((isUser ? _userBubbleColor : _aiBubbleColor) == opaque) return;
    if (isUser) {
      _userBubbleColor = opaque;
    } else {
      _aiBubbleColor = opaque;
    }
    final key = isUser ? keyUserBubbleColor : keyAiBubbleColor;
    if (opaque == null) {
      HiCache.getInstance().remove(key);
    } else {
      HiCache.getInstance().setInt(key, opaque.toARGB32());
    }
    notifyListeners();
  }

  Color bubbleColor(ThemeData theme,
      {required bool isUser, ChatBubbleStyle? style}) {
    final custom = isUser ? _userBubbleColor : _aiBubbleColor;
    if (custom != null) return custom;
    final selectedStyle = style ?? bubbleStyle(isUser: isUser);
    if (selectedStyle != ChatBubbleStyle.classic) {
      return selectedStyle.defaultColor(theme, isUser: isUser);
    }
    final scheme = theme.colorScheme;
    if (theme.extension<AppVisualTheme>()?.isAnime ?? false) {
      return isUser ? scheme.secondaryContainer : scheme.primaryContainer;
    }
    if (theme.brightness == Brightness.dark) {
      return isUser ? scheme.surfaceContainerHighest : scheme.primaryContainer;
    }
    return isUser ? Colors.white : const Color(0xFFE9E8FC);
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
